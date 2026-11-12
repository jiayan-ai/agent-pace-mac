import AppKit
import WebKit
import PaceCore

/// An app-owned browser session. Claude desktop and its protected storage are
/// deliberately not consulted, including on startup and during migration.
@MainActor
final class ClaudeWebSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    private lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 720), configuration: config)
        view.navigationDelegate = self
        view.uiDelegate = self
        return view
    }()
    private var window: NSWindow?
    private var popup: NSWindow?
    private var completion: ((Result<UsageSnapshot, Error>) -> Void)?
    private var requestID: UUID?
    private var executing = false
    private var usageReader: WKWebView?
    private var quotaFallback: Result<UsageSnapshot, Error>?
    private var retriedQuota = false
    private var scopeConfirmedAttempt: Int?
    private var resetObservation: (inventory: ClaudeLimitResets, attempt: Int)?
    private var quotaOrganization: String?
    private var lastResult: Result<UsageSnapshot, Error>?
    private lazy var syncButton = NSButton(title: L("同步额度"), target: self, action: #selector(syncNow))
    private var onSync: (() -> Void)?
    private let message = NSTextField(wrappingLabelWithString: L("在下方 claude.ai 登录，完成后点击「同步额度」。无需 Mac 钥匙串密码。"))
    private let origin = NSTextField(labelWithString: "https://claude.ai")
    private let organizations = NSPopUpButton()
    private var organizationIDs: [String] = []
    private var selectedOrganization: String {
        get { UserDefaults.standard.string(forKey: "claudeWebOrganization") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "claudeWebOrganization") }
    }

    func showLogin(onSync: @escaping () -> Void) {
        self.onSync = onSync
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 720),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = L("Agent Pace · 连接 Claude")
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 640, height: 500)
            let sync = syncButton
            sync.bezelStyle = .rounded
            organizations.target = self
            organizations.action = #selector(chooseOrganization)
            organizations.isHidden = true
            origin.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            origin.textColor = .secondaryLabelColor
            message.font = .systemFont(ofSize: 12)
            let actions = NSStackView(views: [origin, organizations, sync])
            actions.distribution = .fill
            actions.spacing = 12
            let header = NSStackView(views: [message, actions])
            header.orientation = .vertical
            header.alignment = .leading
            header.spacing = 8
            header.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
            let root = NSView()
            for view in [header, webView] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
            NSLayoutConstraint.activate([
                header.leadingAnchor.constraint(equalTo: root.leadingAnchor), header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                header.topAnchor.constraint(equalTo: root.topAnchor), webView.topAnchor.constraint(equalTo: header.bottomAnchor),
                webView.leadingAnchor.constraint(equalTo: root.leadingAnchor), webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                webView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
            ])
            window.contentView = root
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if webView.url == nil { loadUsagePage() }
        else { onSync() }
    }

    func refreshLanguage() {
        window?.title = L("Agent Pace · 连接 Claude")
        syncButton.title = L("同步额度")
        if let popup, let view = popup.contentView as? WKWebView {
            popup.title = L("Claude 登录 · ") + (view.url?.host ?? "")
        }
        if organizations.numberOfItems > 0 { organizations.item(at: 0)?.title = L("选择组织…") }
        switch lastResult {
        case .success?: message.stringValue = L("已连接，额度已同步。可以关闭此窗口，之后每 5 分钟自动刷新。")
        case .failure(let error)?: message.stringValue = error.localizedDescription
        case nil: message.stringValue = L("在下方 claude.ai 登录，完成后点击「同步额度」。无需 Mac 钥匙串密码。")
        }
    }

    @objc private func syncNow() { onSync?() }
    @objc private func chooseOrganization() {
        let index = organizations.indexOfSelectedItem
        guard organizationIDs.indices.contains(index) else { return }
        selectedOrganization = organizationIDs[index]
        if let callback = completion {
            completion = nil
            requestID = nil
            executing = false
            retriedQuota = false
            quotaFallback = nil
            clearReader()
            fetch(completion: callback)
        } else { onSync?() }
    }

    func fetch(completion: @escaping (Result<UsageSnapshot, Error>) -> Void) {
        guard self.completion == nil else { return }
        self.completion = completion
        let id = UUID()
        requestID = id
        trace("starting read")
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            guard let self, self.requestID == id else { return }
            self.trace("refresh deadline")
            self.finish(self.quotaOrganization == self.selectedOrganization
                ? self.quotaFallback ?? .failure(ClaudeUsageError.network) : .failure(ClaudeUsageError.network))
        }
        if webView.isLoading { return }
        if !ClaudeWebAPI.isClaudeOrigin(webView.url) { loadUsagePage(); return }
        query(id: id, in: webView)
    }

    private func loadUsagePage() {
        webView.load(URLRequest(url: ClaudeWebAPI.usagePage, cachePolicy: .reloadIgnoringLocalCacheData))
    }

    private func clearReader() {
        usageReader?.navigationDelegate = nil
        usageReader?.stopLoading()
        usageReader = nil
    }

    private func query(id: UUID, in source: WKWebView) {
        guard requestID == id, !executing else { return }
        guard ClaudeWebAPI.isClaudeOrigin(source.url) else { finish(.failure(ClaudeUsageError.notSignedIn)); return }
        executing = true
        let requestedOrganization = selectedOrganization
        // Isolate from page scripts and pass the organization as structured data.
        trace("querying quota")
        source.callAsyncJavaScript(ClaudeWebAPI.script, arguments: ["selectedOrganization": requestedOrganization],
                                   in: nil, in: .defaultClient) { [weak self] result in
            guard let self, self.requestID == id else { return }
            if self.selectedOrganization != requestedOrganization {
                self.executing = false
                self.query(id: id, in: source)
                return
            }
            do {
                guard let json = try result.get() as? String, let data = json.data(using: .utf8), data.count < 1_000_000 else {
                    throw ClaudeUsageError.invalidResponse
                }
                let reply = try JSONDecoder().decode(ClaudeWebReply.self, from: data)
                self.trace("quota status \(reply.status)" + (reply.readFailurePhase.map { " (\($0))" } ?? ""))
                if reply.status >= 500 && !self.retriedQuota {
                    self.retriedQuota = true
                    // A newly committed WebKit document can be replaced or its
                    // first request interrupted while the web app initializes.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        guard let self, self.requestID == id else { return }
                        self.executing = false
                        self.query(id: id, in: source)
                    }
                    return
                }
                self.updateOrganizations(reply.organizations ?? [])
                let observedAt = Date()
                let quota = Result { try reply.snapshot(now: observedAt) }
                guard reply.status == 200, reply.organization != nil else {
                    if case .success = quota { self.selectedOrganization = reply.organization ?? "" }
                    self.finish(quota); return
                }
                self.selectedOrganization = reply.organization ?? ""
                self.quotaOrganization = reply.organization
                self.quotaFallback = quota
                self.scopeConfirmedAttempt = nil
                self.resetObservation = nil
                // This settings view never makes a bridge request. Its own
                // workspace-scoped resource requests identify the rendered UI.
                let config = WKWebViewConfiguration()
                config.websiteDataStore = source.configuration.websiteDataStore
                let retainTimings = WKUserScript(source: """
                    if (location.origin === 'https://claude.ai') performance.setResourceTimingBufferSize(2048);
                    """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient)
                config.userContentController.addUserScript(retainTimings)
                let reader = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 720), configuration: config)
                reader.navigationDelegate = self
                self.usageReader = reader
                reader.load(URLRequest(url: ClaudeWebAPI.usagePage, cachePolicy: .reloadIgnoringLocalCacheData))
                self.readSection(in: reader, id: id, reply: reply, observedAt: observedAt, attempt: 0)
            } catch let error as ClaudeUsageError { self.finish(.failure(error)) }
            catch { self.finish(.failure(ClaudeUsageError.network)) }
        }
    }

    private func readSection(in source: WKWebView, id: UUID, reply: ClaudeWebReply, observedAt: Date, attempt: Int) {
        guard requestID == id else { return }
        guard selectedOrganization == reply.organization else {
            executing = false
            quotaFallback = nil
            clearReader()
            query(id: id, in: webView)
            return
        }
        source.callAsyncJavaScript(ClaudeWebAPI.resetSectionScript, arguments: [
            "selectedOrganization": selectedOrganization, "soleOrganization": reply.soleOrganization == true
        ],
                                   in: nil, in: .defaultClient) { [weak self] result in
            guard let self, self.requestID == id else { return }
            if self.selectedOrganization != reply.organization {
                self.readSection(in: source, id: id, reply: reply, observedAt: observedAt, attempt: attempt)
                return
            }
            let evidence = (try? result.get()) as? [String: Any]
            if let section = evidence?["section"] as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: section),
               let record = try? JSONDecoder().decode(ClaudeWebReply.ResetSection.self, from: data),
               let snapshot = try? reply.snapshot(now: observedAt, observedSection: record),
               let inventory = snapshot.response.claudeLimitResets {
                // The count badge can appear before React populates the cards.
                // A stable badge is still valuable if the page has no details.
                if self.resetObservation?.inventory != inventory {
                    self.resetObservation = (inventory, attempt)
                }
                let settle = inventory.offers.isEmpty ? 3 : 1
                if inventory.availableCount == 0 || attempt - (self.resetObservation?.attempt ?? attempt) >= settle {
                    self.trace("verified reset inventory")
                    self.finish(.success(snapshot)); return
                }
            } else {
                self.resetObservation = nil
            }
            let status = evidence?["readerStatus"] as? [String: Any]
            if self.scopeConfirmedAttempt == nil, status?["matched"] as? Bool == true { self.scopeConfirmedAttempt = attempt }
            let last = max(40, (self.scopeConfirmedAttempt ?? 0) + 16, (self.resetObservation?.attempt ?? 0) + 3)
            if attempt.isMultiple(of: 10) || attempt == last {
                let route = (status?["route"] as? String) ?? "unavailable"
                if let status {
                    self.trace(["usage", "reset", "metering", "workspace"].map { "\($0):\(status[$0] as? String ?? "-")" }.joined(separator: " "))
                    self.trace(["dialog", "usageTitle", "resetTitle", "resetVisible", "offerButton", "scopedRoot", "sectionTitle", "lineFound"].map { "\($0):\(status[$0] as? Bool == true)" }.joined(separator: " "))
                }
                self.trace("reading settings (\(route); single \(status?["single"] as? Bool == true); matched \(status?["matched"] as? Bool == true); section \(status?["heading"] as? Bool == true))")
            }
            if attempt >= last {
                self.finish(self.quotaFallback ?? .failure(ClaudeUsageError.unavailable)); return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.readSection(in: source, id: id, reply: reply, observedAt: observedAt, attempt: attempt + 1)
            }
        }
    }

    private func trace(_ line: String) {
        if CommandLine.arguments.contains("--check-claude") { fputs("Claude: " + line + "\n", stderr) }
    }

    private func updateOrganizations(_ values: [ClaudeOrganization]) {
        guard !values.isEmpty else { return }
        organizationIDs = values.map(\.uuid)
        organizations.removeAllItems()
        organizations.addItem(withTitle: L("选择组织…"))
        // Placeholder is intentionally not a valid organization choice.
        organizationIDs.insert("", at: 0)
        organizations.addItems(withTitles: values.map(\.name))
        organizations.selectItem(at: organizationIDs.firstIndex(of: selectedOrganization) ?? 0)
        organizations.isHidden = values.count == 1 && (selectedOrganization.isEmpty || values[0].uuid == selectedOrganization)
    }

    private func finish(_ result: Result<UsageSnapshot, Error>) {
        lastResult = result
        let callback = completion
        completion = nil
        requestID = nil
        executing = false
        quotaFallback = nil
        quotaOrganization = nil
        scopeConfirmedAttempt = nil
        resetObservation = nil
        retriedQuota = false
        clearReader()
        switch result {
        case .success:
            message.stringValue = L("已连接，额度已同步。可以关闭此窗口，之后每 5 分钟自动刷新。")
            if popup != nil { popup?.close(); popup = nil; window?.makeKeyAndOrderFront(nil) }
        case .failure(let error): message.stringValue = error.localizedDescription
        }
        callback?(result)
    }

    func disconnect(completion: @escaping () -> Void) {
        finish(.failure(ClaudeUsageError.notSignedIn))
        onSync = nil
        webView.stopLoading()
        popup?.close(); popup = nil
        window?.close()
        selectedOrganization = ""
        webView.loadHTMLString("", baseURL: nil)
        // This store belongs to Agent Pace; other apps' sessions are untouched.
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
            completion()
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let id = requestID, ClaudeWebAPI.isClaudeOrigin(webView.url),
              webView === self.webView else { return }
        trace("settings navigation committed")
        query(id: id, in: webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === usageReader { return }
        guard webView === self.webView else {
            // OAuth popups share our data store. When they return to Claude,
            // try the read-only quota request; do not close them until it succeeds.
            popup?.title = L("Claude 登录 · ") + (webView.url?.host ?? "")
            if ClaudeWebAPI.isClaudeOrigin(webView.url) { onSync?() }
            return
        }
        origin.stringValue = webView.url.map { "\($0.scheme ?? "https")://\($0.host ?? "")" } ?? ""
        if let id = requestID {
            if usageReader == nil { query(id: id, in: webView) }
        }
        else if window?.isVisible == true, ClaudeWebAPI.isClaudeOrigin(webView.url) { onSync?() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        if webView === usageReader { return }
        if webView === self.webView, requestID != nil { finish(.failure(ClaudeUsageError.network)) }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { self.webView(webView, didFail: navigation, withError: error) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if webView === usageReader, action.targetFrame?.isMainFrame == true, !ClaudeWebAPI.isClaudeOrigin(url) {
            decisionHandler(.cancel)
            return
        }
        // Visible login may navigate to the user's HTTPS identity provider.
        // No custom URL schemes, insecure HTTP, or desktop-app authentication hooks.
        // srcdoc is used by normal embedded verification frames (Cloudflare's
        // documented WebView requirements). Keep the engine's default UA/CSP.
        let allowed = url.scheme == "https" || ["about:blank", "about:srcdoc"].contains(url.absoluteString)
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard window?.isVisible == true, action.request.url?.scheme == "https" else { return nil }
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        let child = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 700), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        child.title = L("Claude 登录 · ") + (action.request.url?.host ?? "")
        child.isReleasedWhenClosed = false
        child.contentView = view
        child.center()
        popup?.close()
        popup = child
        child.makeKeyAndOrderFront(nil)
        return view
    }

    func webViewDidClose(_ webView: WKWebView) {
        if webView !== self.webView { popup?.close(); popup = nil; loadUsagePage() }
    }
}
