import AppKit
import WebKit
import PaceCore

private func sessionText(_ chinese: String, _ english: String) -> String {
    Localization.isChinese ? chinese : english
}

enum PerplexitySessionError: LocalizedError {
    case signInRequired, unreadable, network, busy

    var errorDescription: String? {
        switch self {
        case .signInRequired:
            return sessionText("请在连接窗口登录 Perplexity，打开用量页面后点击「同步额度」。",
                               "Sign in to Perplexity in the connection window, open Usage, then click Sync usage.")
        case .unreadable:
            return sessionText("用量页面没有显示可识别的 Computer 额度。请打开账户用量页核对。",
                               "No recognizable Computer allowance was visible. Check your account’s Usage page.")
        case .network:
            return sessionText("Perplexity 用量页面加载失败，请重试。", "Couldn’t load Perplexity Usage. Please try again.")
        case .busy:
            return sessionText("正在同步 Perplexity 用量。", "Syncing Perplexity usage.")
        }
    }
}

@MainActor
final class PerplexityWebSession: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    static let usageURL = URL(string: "https://www.perplexity.ai/account/usage")!
    static var persistsLogin: Bool {
        if #available(macOS 14, *) { return true }
        return false
    }
    private lazy var dataStore: WKWebsiteDataStore = {
        if #available(macOS 14, *) {
            return WKWebsiteDataStore(forIdentifier: UUID(uuidString: "9b5b5348-ba02-4678-b7ae-25f32d53d04e")!)
        }
        return .nonPersistent()
    }()

    private var loginView: WKWebView?
    private var reader: WKWebView?
    private var window: NSWindow?
    private var popup: NSWindow?
    private var onSync: (() -> Void)?
    var onLoginWindowClosed: (() -> Void)?
    var isLoginWindowVisible: Bool { window?.isVisible == true }
    private let message = NSTextField(wrappingLabelWithString: "")
    private let origin = NSTextField(labelWithString: "")
    private lazy var syncButton = NSButton(title: "", target: self, action: #selector(syncNow))
    private lazy var usageButton = NSButton(title: "", target: self, action: #selector(openUsage))
    private var readLoginPageOnce = false
    private var deletingData = false
    private var completion: ((Result<PerplexityCredits, Error>) -> Void)?
    private var requestID: UUID?
    private weak var source: WKWebView?
    private var lastResult: Result<PerplexityCredits, Error>?

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        return view
    }

    func showLogin(onSync: @escaping () -> Void) {
        guard !deletingData else { return }
        self.onSync = onSync
        if window == nil {
            let view = makeWebView()
            loginView = view
            let box = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 720),
                               styleMask: [.titled, .closable, .resizable, .miniaturizable],
                               backing: .buffered, defer: false)
            box.minSize = NSSize(width: 640, height: 500)
            box.isReleasedWhenClosed = false
            box.delegate = self
            origin.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            origin.textColor = .secondaryLabelColor
            message.font = .systemFont(ofSize: 12)
            let actions = NSStackView(views: [origin, usageButton, syncButton])
            actions.spacing = 12
            let header = NSStackView(views: [message, actions])
            header.orientation = .vertical
            header.alignment = .leading
            header.spacing = 8
            header.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
            let root = NSView()
            for element in [header, view] {
                element.translatesAutoresizingMaskIntoConstraints = false
                root.addSubview(element)
            }
            NSLayoutConstraint.activate([
                header.leadingAnchor.constraint(equalTo: root.leadingAnchor), header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                header.topAnchor.constraint(equalTo: root.topAnchor), view.topAnchor.constraint(equalTo: header.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: root.leadingAnchor), view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                view.bottomAnchor.constraint(equalTo: root.bottomAnchor)
            ])
            box.contentView = root
            box.center()
            window = box
        }
        refreshLanguage()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if loginView?.url == nil { openUsage() }
        else if Self.canRead(loginView?.url, allowHomeDialog: false), loginView?.isLoading == false {
            loginView?.reloadFromOrigin()
        }
    }

    func refreshLanguage() {
        guard window != nil else { return }
        window?.title = sessionText("Agent Pace · 连接 Perplexity", "Agent Pace · Connect Perplexity")
        usageButton.title = sessionText("打开用量页", "Open Usage")
        syncButton.title = L("同步额度")
        if completion != nil {
            message.stringValue = PerplexitySessionError.busy.localizedDescription
        } else {
            switch lastResult {
            case .success?:
                message.stringValue = L("已连接，额度已同步。可以关闭此窗口，之后每 5 分钟自动刷新。")
            case .failure(let error)?:
                message.stringValue = error.localizedDescription
            case nil:
                message.stringValue = sessionText("在下方登录 Perplexity，然后点击「同步额度」。",
                                                  "Sign in to Perplexity below, then click Sync usage.")
            }
        }
    }

    @objc private func openUsage() { loginView?.load(URLRequest(url: Self.usageURL)) }

    @objc private func syncNow() {
        // A user-initiated read of the visible page supersedes a background load
        // that might still be waiting on the pre-login session.
        if completion != nil { finish(.failure(PerplexitySessionError.busy)) }
        readLoginPageOnce = Self.canRead(loginView?.url, allowHomeDialog: true)
        onSync?()
    }

    func fetch(completion: @escaping (Result<PerplexityCredits, Error>) -> Void) {
        guard self.completion == nil, !deletingData else {
            completion(.failure(PerplexitySessionError.busy))
            return
        }
        let id = UUID()
        self.completion = completion
        requestID = id
        let useLoginPage = readLoginPageOnce && Self.canRead(loginView?.url, allowHomeDialog: true)
        readLoginPageOnce = false
        refreshLanguage()
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.requestID == id else { return }
            self.finish(.failure(PerplexitySessionError.network))
        }
        if useLoginPage, let loginView {
            source = loginView
            if !loginView.isLoading { read(loginView, id: id) }
        } else {
            loadReader()
        }
    }

    private func loadReader() {
        // A separate view keeps refreshes from navigating the login form.
        let view = makeWebView()
        reader = view
        source = view
        view.load(URLRequest(url: Self.usageURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25))
    }

    private static func canRead(_ url: URL?, allowHomeDialog: Bool) -> Bool {
        guard let url, url.scheme == "https", url.port == nil || url.port == 443,
              url.user == nil, url.password == nil,
              ["www.perplexity.ai", "perplexity.ai"].contains(url.host?.lowercased() ?? "") else { return false }
        return ["/account/usage", "/account/usage/"].contains(url.path)
            || (allowHomeDialog && ["", "/"].contains(url.path))
    }

    // The account page can present the same screen as a modal on the home
    // route. In both layouts return only the labeled quota figures to Swift.
    static let usageScript = #"""
    if (!['https://www.perplexity.ai', 'https://perplexity.ai'].includes(location.origin)) return '';
    const canonical = /^\/account\/usage\/?$/.test(location.pathname);
    if (!canonical && location.pathname !== '/') return '';
    const visible = x => x.getClientRects().length && getComputedStyle(x).visibility === 'visible'
        && !x.closest('[inert], [aria-hidden="true"]');
    const title = /^(?:Usage (?:and|&) credits|使用情况[和与]积分|用量[和与]积分|使用量[与和]积分)$/i;
    const usageTitle = /^(?:Usage|Computer usage|用量|使用情况|Computer 用量)$/i;
    const weekly = /^(?:Included in Pro|Pro (?:套餐已包含|套餐包含|已包含|包含的用量|中包含))$/i;
    const credits = /^(?:(?:Computer |your |available )?Credits|credit balances?|积分(?:余额|明细)?|点数|额度|余额明细)$/i;
    const lines = x => x.innerText.split(/\r?\n/).map(s => s.normalize('NFKC').trim()).filter(Boolean);
    const panels = [...document.querySelectorAll('dialog[open], [role="dialog"], [aria-modal="true"]')].filter(visible);
    const panel = panels.find(x => {
        const rows = lines(x);
        return rows.some(s => title.test(s)) && rows.some(s => weekly.test(s) || credits.test(s));
    });
    const area = panel || (canonical && !panels.length ? document.querySelector('main, [role="main"]') || document.body : null);
    if (!area) return '';
    const rows = lines(area);
    if (!panel) {
        const labeled = [...area.querySelectorAll('h1, h2, [role="heading"]')].some(x =>
            visible(x) && (title.test(x.innerText.trim()) || usageTitle.test(x.innerText.trim())));
        if (!labeled && !title.test(rows[0] || '')) return '';
    }
    const weeklyRow = /^(?:Weekly limit|每周(?:限额|上限|额度|限制)|周[限额度]{2})(?:\s*[:：]?\s*(?:[\d.,]+\s*%\s*(?:left|remaining|available|used|可用|剩余|已用)?)?)?$/i;
    const pct = /^(?:(?:remaining|available|used|剩余|可用|已用|已使用)\s*:?\s*)?[\d.]+\s*%\s*(?:left|remaining|available|used|剩余|可用|已用|已使用)?$/i;
    const reset = /^(?:resets?(?: (?:on|at))?|next reset|下次重置(?:时间)?|重置(?:于|时间)?)[ :]*$/i;
    const datePart = /^(?:(?:Mon(?:day)?|Tue(?:sday|s)?|Wed(?:nesday)?|Thu(?:rsday|rs)?|Fri(?:day)?|Sat(?:urday)?|Sun(?:day)?|(?:星期|周|礼拜)[一二三四五六日天])\.?[, ]*(?:at\s*)?(?:上午|下午)?\s*\d{1,2}(?::\d{2})?\s*(?:am|pm)?\.?|\d{4}-\d\d-\d\dT[\d:.]+(?:Z|[+-]\d\d:\d\d))$/i;
    const combinedReset = /^(?:resets?(?: (?:on|at))?|next reset|下次重置(?:时间)?|重置(?:于|时间)?)[ :]+(.+)$/i;
    const creditLabel = /^(?:plan|bonus|purchased|(?:monthly(?: plan)?|plan|bonus|purchased|available|remaining|total) credits?|credits (?:available|remaining)|(?:credits?|total|current) balance|balance|total|套餐|计划|奖励|已购买|已购|(?:套餐|计划|奖励|赠送|已购|已购买|月度|每月|剩余|可用|总)积分|(?:积分|总)余额|余额|合计)(?=$|[ :+−\d-])(.*)$/i;
    const amount = /^(?:[:：]\s*)?[-+−]?[\d,.]+(?:\s*(?:credits?|积分|点数))?(?:\s*(?:left|remaining|available|可用|剩余))?$/i;
    const total = /^(?:[-+−]?[\d,.]+\s*credits?\s+(?:left|remaining|available)|(?:还剩|剩余|可用)\s*[-+−]?[\d,.]+\s*(?:积分|点数))$/i;
    const refresh = /^(?:(?:(?:plan|monthly) credits? )?(?:refresh(?:es)?|renews?|resets?) in \d{1,3} days?|(?:days until (?:your |the )?next monthly refresh|next (?:monthly )?(?:refresh|reset|renewal))[: ]*(?:\d{1,3}(?: days?)?)?|(?:距(?:离)?(?:下次|下一次)(?:月度|每月|套餐|计划)?(?:刷新|重置|续期)(?:还剩|还有)?\s*:?\s*(?:\d{1,3}\s*天)?|\d{1,3}\s*天后(?:刷新|重置|续期)))$/i;
    const end = /^(?:Add more|Turn on auto.refill|More details|Upgrade|Usage (?:by|breakdown|history|details|activity)|Recent|History|Auto.refill|Spending limit|Purchas(?:e credits|ing)|Buy credits|Payment|Transaction|Credit history|Tasks|Activity|Thread history|使用明细|使用记录|用量明细|用量记录|最近|自动充值|支出限额|消费上限|交易|购买积分|付款|任务记录|更多详情|添加更多|升级)/i;
    const output = [];
    let section = '', pending = '';
    for (const row of rows) {
        if (weekly.test(row)) { section = 'weekly'; pending = ''; output.push(row); continue; }
        if (credits.test(row)) {
            section = 'credits'; pending = creditLabel.test(row) ? 'amount' : ''; output.push(row); continue;
        }
        if (end.test(row)) { section = ''; pending = ''; continue; }
        let keep = false, next = '';
        if (section === 'weekly') {
            const combined = combinedReset.exec(row);
            keep = weeklyRow.test(row) || pct.test(row) || reset.test(row)
                || (combined && datePart.test(combined[1])) || (pending === 'date' && datePart.test(row))
                || (pending === 'direction' && /^(?:left|remaining|available|used|剩余|可用|已用|已使用)$/i.test(row));
            if (reset.test(row)) next = 'date';
            if (pct.test(row)) next = 'direction';
        } else if (section === 'credits') {
            const label = creditLabel.exec(row);
            keep = (label && (!label[1].trim() || amount.test(label[1].trim())))
                || total.test(row) || refresh.test(row) || (pending === 'amount' && amount.test(row))
                || (pending === 'days' && /^\d{1,3}(?:\s*(?:days?|天))?$/i.test(row));
            if (label && !label[1].trim()) next = 'amount';
            if (refresh.test(row) && !/\d/.test(row)) next = 'days';
        }
        if (keep && row.length <= 128) output.push(row);
        else if (section) { section = ''; output.push('Usage'); }
        pending = next;
        if (output.length >= 200) break;
    }
    return output.join('\n');
    """#

    private func read(_ view: WKWebView, id: UUID, attempt: Int = 0) {
        guard requestID == id, source === view else { return }
        guard Self.canRead(view.url, allowHomeDialog: true) else { finish(.failure(PerplexitySessionError.signInRequired)); return }
        // Check the document's own address again at execution time. Only the
        // rendered usage screen is read, after JavaScript hydration completes.
        view.callAsyncJavaScript(Self.usageScript, arguments: [:], in: nil, in: .defaultClient) { [weak self, weak view] result in
            guard let self, let view, self.requestID == id, self.source === view else { return }
            guard Self.canRead(view.url, allowHomeDialog: true) else { self.finish(.failure(PerplexitySessionError.signInRequired)); return }
            if let visibleText = try? result.get() as? String,
               let credits = PerplexityCredits.parse(visibleText: visibleText) {
                self.finish(.success(credits))
            } else if view === self.loginView, !Self.canRead(view.url, allowHomeDialog: false) {
                // The authentication provider can return to the home screen
                // without opening Usage. Start a fresh read of the account page.
                self.loadReader()
            } else if attempt < 12 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self, weak view] in
                    if let view { self?.read(view, id: id, attempt: attempt + 1) }
                }
            } else {
                self.finish(.failure(Self.canRead(view.url, allowHomeDialog: false)
                    ? PerplexitySessionError.unreadable : PerplexitySessionError.signInRequired))
            }
        }
    }

    private func finish(_ result: Result<PerplexityCredits, Error>) {
        lastResult = result
        let callback = completion
        completion = nil
        requestID = nil
        source = nil
        reader?.navigationDelegate = nil
        reader?.stopLoading()
        reader = nil
        refreshLanguage()
        callback?(result)
    }

    func disconnect(completion: @escaping () -> Void) {
        deletingData = true
        onSync = nil
        readLoginPageOnce = false
        finish(.failure(PerplexitySessionError.signInRequired))
        loginView?.navigationDelegate = nil
        loginView?.stopLoading()
        popup?.close()
        popup = nil
        window?.delegate = nil
        window?.close()
        window = nil
        loginView = nil
        lastResult = nil
        dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
            self?.deletingData = false
            completion()
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        popup?.close()
        popup = nil
        onLoginWindowClosed?()
    }

    func webView(_ view: WKWebView, didCommit navigation: WKNavigation!) {
        if view === loginView {
            origin.stringValue = view.url?.host.map { "https://\($0)" } ?? ""
        } else if let popup, view === popup.contentView { popup.title = view.url?.host ?? "Perplexity" }
    }

    func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
        if view === source, let id = requestID { read(view, id: id) }
    }

    func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        webView(view, didFail: navigation, withError: error)
    }

    func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        if view === source { finish(.failure(PerplexitySessionError.network)) }
        else if view === loginView {
            lastResult = .failure(PerplexitySessionError.network)
            refreshLanguage()
        }
    }

    func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if view === reader, action.targetFrame?.isMainFrame == true, !Self.canRead(url, allowHomeDialog: true) {
            decisionHandler(.cancel)
            finish(.failure(PerplexitySessionError.signInRequired))
            return
        }
        let allowed = url.scheme == "https" || ["about:blank", "about:srcdoc"].contains(url.absoluteString)
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(_ view: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard view === loginView, window?.isVisible == true, let url = action.request.url,
              url.scheme == "https" || url.absoluteString == "about:blank" else { return nil }
        let child = WKWebView(frame: .zero, configuration: configuration)
        child.navigationDelegate = self
        child.uiDelegate = self
        let box = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 680),
                           styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        box.isReleasedWhenClosed = false
        box.title = url.host ?? "Perplexity"
        box.contentView = child
        box.center()
        popup?.close()
        popup = box
        box.makeKeyAndOrderFront(nil)
        return child
    }

    func webViewDidClose(_ view: WKWebView) {
        if let popup, view === popup.contentView {
            popup.close()
            self.popup = nil
        }
    }
}
