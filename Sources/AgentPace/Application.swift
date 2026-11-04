import AppKit
import SwiftUI
import PaceCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let store = PaceStore(diagnostics: CommandLine.arguments.contains("--check-menu"))
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var menuHost: NSHostingController<AnyView>?
    private var preparedMenuSize: NSSize?
    private var menuGeneration = 0
    private var screenObserver: NSObjectProtocol?
    private var window: NSWindow?
    private var renderedStatusTitle: String?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Agent Pace"
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.hideMenu()
                self?.updateStatusItem(force: true)
                self?.prepareMenuForCurrentScreen()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateStatusItem(force: true) }
        }
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        store.onChange = { [weak self] in self?.updateStatusItem() }
        store.onChange?()
        // Build and lay out the details before a click needs them. This never
        // fetches an account, opens a window or consumes a reset credit.
        prepareMenuForCurrentScreen()
        if CommandLine.arguments.contains("--check-menu") {
            Task { await checkMenu() }
            return
        }
        store.refreshAll()
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "hasLaunched") || CommandLine.arguments.contains("--show-window") {
            showWindow()
            defaults.set(true, forKey: "hasLaunched")
        }
        // Normal startup leaves the menu closed. The first status-button click
        // opens it exactly once, after the status item has joined its window.
    }

    @objc private func togglePopover() {
        if popover.isShown { hideMenu() }
        else { showMenu() }
    }

    private func updateStatusItem(force: Bool = false) {
        guard let button = statusItem.button else { return }
        let title = store.menuTitle
        if force || renderedStatusTitle != title || button.image == nil {
            let image = StatusItemLabel.image(for: title)
            button.title = ""
            button.image = image
            // Reserve the full label width rather than relying on a mixed
            // image/title cell to invalidate its intrinsic size after refresh.
            statusItem.length = image.size.width + 16
            button.setAccessibilityLabel("Agent Pace · \(title)")
            renderedStatusTitle = title
            button.needsDisplay = true
        }
        button.contentTintColor = nil
        button.toolTip = store.menuTooltip
    }

    private func showMenu() {
        let started = ProcessInfo.processInfo.systemUptime
        defer {
            if CommandLine.arguments.contains("--check-menu") {
                print(String(format: "Menu open main-thread work: %.1f ms", (ProcessInfo.processInfo.systemUptime - started) * 1000))
            }
        }
        guard !popover.isShown, let button = statusItem.button, button.window != nil,
              let screen = button.window?.screen ?? NSScreen.main else { return }
        store.now = Date()
        prepareMenu(size: menuSize(on: screen))
        // AppKit owns outside-click dismissal, focus, and nested Picker/Menu
        // tracking. Do not activate the app or install competing event monitors.
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func menuSize(on screen: NSScreen) -> NSSize {
        NSSize(width: min(400, screen.visibleFrame.width - 16),
               height: min(600, screen.visibleFrame.height - 32))
    }

    private func prepareMenuForCurrentScreen(resetContent: Bool = false) {
        guard let screen = statusItem.button?.window?.screen ?? NSScreen.main else { return }
        prepareMenu(size: menuSize(on: screen), resetContent: resetContent)
    }

    private func prepareMenu(size: NSSize, resetContent: Bool = false) {
        guard menuHost == nil || preparedMenuSize != size || resetContent else { return }
        if resetContent { menuGeneration += 1 }
        let content = AnyView(ScrollView(.vertical) {
            PaceView(store: store, openWindow: { [weak self] in self?.showWindow() })
        }
        .id(menuGeneration)
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor)))
        let host: NSHostingController<AnyView>
        if let existing = menuHost {
            host = existing
            host.rootView = content
        } else {
            host = NSHostingController(rootView: content)
            host.sizingOptions = []
            menuHost = host
            popover.contentViewController = host
        }
        preparedMenuSize = size
        popover.contentSize = size
        host.view.setFrameSize(size)
        host.view.layoutSubtreeIfNeeded()
    }

    private func hideMenu() { popover.performClose(nil) }

    func popoverDidClose(_ notification: Notification) {
        updateStatusItem(force: true)
        // Reset transient confirmations/disclosures as before, and do their
        // layout while closed instead of rebuilding on the next click.
        prepareMenuForCurrentScreen(resetContent: true)
    }

    // Exercises real AppKit status-button actions across run-loop turns. It does
    // not fetch accounts or change saved preferences and needs a macOS desktop.
    private func checkMenu() async {
        func fail(_ message: String) -> Never { fputs("FAIL \(message)\n", stderr); exit(1) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard let button = statusItem.button, button.window != nil, !popover.isShown else {
            fail("Startup must leave a ready status button and a closed popover")
        }
        checkStatusRendering()
        guard let preparedHost = menuHost, popover.contentViewController === preparedHost else {
            fail("Details must be prepared before the first click")
        }
        for cycle in 1...3 {
            button.performClick(nil)
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard popover.contentViewController === preparedHost else {
                fail("Opening rebuilt the hosting controller")
            }
            guard popover.isShown, let popupWindow = popover.contentViewController?.view.window, popupWindow.isVisible else {
                fail("Click \(cycle) did not keep the details visible")
            }
            guard let screen = popupWindow.screen, screen.frame.contains(popupWindow.frame) else {
                fail("Popover extends beyond the screen")
            }
            updateStatusItem()
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard popover.isShown else { fail("Status update closed the popover") }
            button.performClick(nil)
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !popover.isShown else { fail("Second click did not close the popover") }
            guard let image = button.image, image.isTemplate, image.size.width > 21,
                  button.bounds.width >= image.size.width, !button.isHidden,
                  button.alphaValue > 0, button.title.isEmpty else {
                fail("Status label is missing, clipped or using a separate title")
            }
        }
        let originalSize = preparedMenuSize!
        prepareMenu(size: NSSize(width: originalSize.width, height: originalSize.height - 40))
        guard popover.contentViewController === preparedHost,
              popover.contentSize.height == originalSize.height - 40 else {
            fail("Cached details did not adapt to available screen height")
        }
        prepareMenu(size: originalSize)
        print("PASS 菜单栏预加载、控制器复用、连续展开/收起、更新时保持显示及屏幕尺寸适配")
        exit(0)
    }

    private func checkStatusRendering() {
        for title in ["Fable 22.9%", "Codex -7.6%", "Claude ≈30.7%/h", "Claude 60.0% · <1h", "Claude 同步中"] {
            let image = StatusItemLabel.image(for: title)
            // Check the actual rendered alpha, including the text region, at
            // both display scales. A nonempty title alone missed the blank bug.
            for scale in [1, 2] {
                let width = Int(image.size.width) * scale
                let height = Int(image.size.height) * scale
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
                NSGraphicsContext.restoreGraphicsState()
                var symbolPixels = 0
                var textPixels = 0
                for x in 0..<width {
                    for y in 0..<height where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                        if x < 18 * scale { symbolPixels += 1 } else { textPixels += 1 }
                    }
                }
                guard image.isTemplate, symbolPixels > 20, textPixels > 20 else {
                    fputs("FAIL Status label rendered blank at \(scale)x\n", stderr); exit(1)
                }
            }
        }
        print("PASS 状态栏图标与数字实际绘制、负数/小时/同步状态及 1x/2x 分辨率")
    }

    func showWindow() {
        hideMenu()
        if window == nil {
            let host = NSHostingController(rootView: ScrollView(.vertical) {
                PaceView(store: store)
            }.frame(width: 400, height: 600))
            let newWindow = NSWindow(contentViewController: host)
            newWindow.title = "Agent Pace"
            newWindow.styleMask = [.titled, .closable, .miniaturizable]
            newWindow.isReleasedWhenClosed = false
            newWindow.setContentSize(NSSize(width: 400, height: 600))
            newWindow.center()
            window = newWindow
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMenu()
        return true
    }
}

@main
struct AgentPaceApplication {
    @MainActor static func main() {
        Localization.language = AppLanguage.load()
        if CommandLine.arguments.contains("--check-reset-radar") {
            Task {
                do {
                    let snapshot = try await ResetRadarClient.fetch()
                    let assessment = snapshot.assessment(at: Date())
                    print("Tibo Reset: \(assessment.title)；\(assessment.detail)")
                    if let updated = snapshot.feed.archiveDate { print("来源更新：\(resetTime(updated))") }
                    for type in ["global_reset", "banked_reset"] {
                        if let event = snapshot.feed.latest(type, at: Date()) {
                            print("\(event.kindLabel)：\(event.dateOnlyLabel ?? event.date.map(resetTime) ?? "未知") · \(event.verificationLabel)")
                        }
                    }
                    print("社区预测：\(ResetRadarLinks.forecast.absoluteString)")
                    exit(0)
                } catch {
                    fputs("\(error.localizedDescription)\n", stderr)
                    exit(1)
                }
            }
            RunLoop.main.run()
            return
        }
        // Small diagnostic command for verifying the real account integration without starting the UI.
        if CommandLine.arguments.contains("--check-connection") || CommandLine.arguments.contains("--check-claude") {
            do {
                let snapshot: UsageSnapshot
                if CommandLine.arguments.contains("--check-claude") {
                    let app = NSApplication.shared
                    app.setActivationPolicy(.prohibited)
                    let session = ClaudeWebSession()
                    var reply: Result<UsageSnapshot, Error>?
                    session.fetch { reply = $0; app.stop(nil)
                        if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) { app.postEvent(event, atStart: true) }
                    }
                    withExtendedLifetime(session) { app.run() }
                    snapshot = try reply!.get()
                } else { snapshot = try CodexClient.fetch() }
                for item in snapshot.response.windows {
                    if CommandLine.arguments.contains("--check-claude"), item.window.windowDurationMins == 300 {
                        let pace = ClaudeSessionPace(window: item.window, now: snapshot.fetchedAt)
                        print("\(item.label): 剩余 \(pace.remaining.map(number) ?? "未知")%; \(pace.heading) \(pace.allowance.map(number) ?? "未知")\(pace.unit); \(pace.countdown)")
                        continue
                    }
                    let budget = DailyBudget.reconcile(previous: nil, window: item.window, now: snapshot.fetchedAt)
                    print("\(item.label): 剩余 \(item.window.remaining.map(number) ?? "未知")%; 日均 \(budget.map { number($0.allowance) } ?? "未知")%; 重置 \(item.window.resetDate.map(resetTime) ?? "未知")")
                }
                if CommandLine.arguments.contains("--check-connection") {
                    let pattern = UsagePattern(activity: snapshot.activity, now: snapshot.fetchedAt)
                    let advice = ResetAdvice.evaluate(response: snapshot.response, pattern: pattern,
                                                      historyFresh: snapshot.activity != nil, stale: false, now: snapshot.fetchedAt)
                    print("Reset: \(snapshot.response.rateLimitResetCredits.map { String($0.availableCount) } ?? "未知") 次；近 30 天有效记录 \(pattern.observedDays) 天；\(advice.title)")
                }
                if snapshot.response.windows.isEmpty { print("未返回额度窗口") }
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
