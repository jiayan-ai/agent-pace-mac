import AppKit
import SwiftUI
import PaceCore

@MainActor
final class PaceStore: ObservableObject {
    @Published private var history = PaceHistory()
    @Published private var refreshing: Set<UsageProvider> = []
    @Published private var errors: [UsageProvider: Error] = [:]
    @Published private var verified: Set<UsageProvider> = []
    @Published var now = Date()
    @Published private var persistenceFailed = false
    @Published private(set) var language = Localization.language
    var persistenceError: String? { persistenceFailed ? L("今日记录暂时无法保存；重新打开后会重新计算预算。") : nil }
    @Published private(set) var claudeEnabled = UserDefaults.standard.bool(forKey: "claudeWebConnectionEnabled")
    @Published private(set) var claudeNeedsLogin = false
    @Published private(set) var disconnectingClaude = false
    @Published private(set) var resetRadar: ResetRadarSnapshot?
    @Published private(set) var resetRadarRefreshing = false
    @Published private var resetRadarFailure: Error?
    var resetRadarError: String? {
        resetRadarFailure.map { ($0 as? ResetRadarError)?.errorDescription ?? L("Reset 动态暂时无法同步。") }
    }
    @Published private(set) var resetRadarEnabled = UserDefaults.standard.object(forKey: "resetRadarEnabled") as? Bool ?? true
    @Published private var resetRadarVerified = false
    private var resetRadarTask: Task<Void, Never>?
    private var resetRadarAttempt: Date?
    private let resetRadarCacheURL: URL
    private let claudeSession = ClaudeWebSession()
    var onChange: (() -> Void)?
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var lastAttempt: [UsageProvider: Date] = [:]
    private var retryAfter: [UsageProvider: Date] = [:]
    private let cacheURL: URL

    init() {
        cacheURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexPace/state.json")
        resetRadarCacheURL = cacheURL.deletingLastPathComponent().appendingPathComponent("reset-radar.json")
        if let data = try? Data(contentsOf: resetRadarCacheURL), data.count <= ResetRadarClient.maximumBytes,
           let saved = try? JSONDecoder().decode(ResetRadarSnapshot.self, from: data) {
            resetRadar = saved
        }
        if let data = try? Data(contentsOf: cacheURL), let saved = try? JSONDecoder().decode(PaceHistory.self, from: data) {
            history = saved
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.now = Date()
                self.onChange?()
                // Keep both daily baselines up to date even while one is hidden.
                for provider in UsageProvider.allCases {
                    let record = self.history[provider]
                    let crossedDay = record.snapshot.map { !Calendar.current.isDate($0.fetchedAt, inSameDayAs: self.now) } ?? false
                    let sessionResetPassed = provider == .claude && (record.snapshot?.response.windows.contains {
                        $0.window.windowDurationMins == 300 &&
                        ClaudeSessionPace(window: $0.window, now: self.now).awaitingReset
                    } ?? false)
                    let creditExpired = provider == .codex && (record.snapshot?.response.rateLimitResetCredits?.availableCount ?? 0) > 0 && (record.snapshot?.response.rateLimitResetCredits?.credits?.contains {
                        $0.status == "available" && $0.resetType == "codexRateLimits" &&
                        $0.expiryDate.map { $0 <= self.now } == true
                    } ?? false)
                    let interval: TimeInterval = crossedDay || sessionResetPassed || creditExpired ? 60 : 300
                    if self.now.timeIntervalSince(self.lastAttempt[provider] ?? .distantPast) >= interval {
                        self.refresh(provider: provider)
                    }
                }
                if self.now.timeIntervalSince(self.resetRadarAttempt ?? .distantPast) >= ResetRadarClient.refreshInterval {
                    self.refreshResetRadar()
                }
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
    }

    var provider: UsageProvider { history.selectedProvider }
    var snapshot: UsageSnapshot? { history[provider].snapshot }
    var selectedID: String { history[provider].selectedID }
    var isRefreshing: Bool { refreshing.contains(provider) }
    var error: String? { errors[provider].map { ($0 as? LocalizedError)?.errorDescription ?? L("额度同步失败，请稍后重试。") } }
    var windows: [MeteredWindow] { snapshot?.response.windows ?? [] }
    var selected: MeteredWindow? { windows.first(where: { $0.id == selectedID }) ?? windows.first }
    var sessionPace: ClaudeSessionPace? {
        guard provider == .claude, let selected, selected.window.windowDurationMins == 300 else { return nil }
        return ClaudeSessionPace(window: selected.window, now: now)
    }
    var creditPace: ResetCreditPace? {
        guard provider == .codex, let selected, selected.bucketID == "codex", let snapshot,
              now.timeIntervalSince(snapshot.fetchedAt) >= 0 else { return nil }
        return ResetCreditPace.evaluate(window: selected.window,
                                        credits: snapshot.response.rateLimitResetCredits,
                                        stale: stale, now: now)
    }
    var creditPlanNeedsConfirmation: Bool {
        guard provider == .codex, let snapshot, let selected, selected.bucketID == "codex",
              let credits = snapshot.response.rateLimitResetCredits, credits.availableCount > 0 else { return false }
        let expired = (credits.credits ?? []).contains {
            $0.status == "available" && $0.resetType == "codexRateLimits" &&
            $0.expiryDate.map { $0 <= now } == true
        }
        let unverified = stale || now.timeIntervalSince(snapshot.fetchedAt) < 0
        return expired || (unverified && ResetCreditPace.evaluate(window: selected.window, credits: credits,
                                                                    stale: false, now: now) != nil)
    }
    var budget: DailyBudget? {
        guard let selected, let snapshot else { return nil }
        return history[provider].budgets["\(snapshot.accountKey)/\(selected.id)"]
    }
    var stale: Bool {
        guard verified.contains(provider), let snapshot else { return true }
        return error != nil || now.timeIntervalSince(snapshot.fetchedAt) > 660
    }
    var validBudget: DailyBudget? {
        guard let budget, Calendar.current.startOfDay(for: now) == budget.dayStart,
              budget.timeZoneID == Calendar.current.timeZone.identifier,
              budget.resetAt > now.timeIntervalSince1970 else { return nil }
        return budget
    }
    var menuTitle: String {
        if let sessionPace { return sessionPace.menuTitle(stale: stale) }
        if creditPlanNeedsConfirmation { return "Codex \(L("待同步"))" }
        if let pace = creditPace {
            return "Codex \(number(pace.allowance))\(pace.isFinalHour ? "% · <1h" : "%/h")"
        }
        let title = selected?.bucketID == "claude_fable" ? "Fable" : provider.shortTitle
        guard let budget = validBudget else { return "\(title) \(isRefreshing ? L("同步中") : L("待同步"))" }
        return "\(title) \(stale ? "≈" : "")\(number(budget.leftToday))%"
    }
    var menuTooltip: String {
        if let pace = sessionPace {
            let allowance = pace.allowance.map { "\(number($0))\(pace.unit)" } ?? L("待同步")
            return "Claude · \(pace.heading) \(allowance)\n\(pace.countdown)\(stale ? L(" · 上次记录") : "")"
        }
        if creditPlanNeedsConfirmation { return L("Reset 券状态待同步确认，请刷新额度。") }
        if let pace = creditPace {
            let value = "\(number(pace.allowance))\(pace.isFinalHour ? "%" : L("% / 小时"))"
            return L("Codex · Reset 券到期前建议 \(value)\n距到期 \(pace.countdown)")
        }
        let over = validBudget?.overBudget ?? 0
        return over > 0 ? L("\(provider.title) · 今日已超额 \(number(over)) 个百分点")
            : L("\(provider.title) · 今天还可用的额度")
    }
    var daysLeft: Double? { selected?.window.resetDate.map { max(0, $0.timeIntervalSince(now) / 86400) } }
    var usagePattern: UsagePattern { UsagePattern(activity: history[provider].activity, now: now) }
    var activityUpdatedAt: Date? { history[provider].activityFetchedAt }
    var resetAdvice: ResetAdvice {
        let historyAge = activityUpdatedAt.map { now.timeIntervalSince($0) } ?? .infinity
        return ResetAdvice.evaluate(response: snapshot?.response, pattern: usagePattern,
                                    historyFresh: historyAge >= 0 && historyAge < 6 * 3600,
                                    stale: stale, now: now)
    }
    func selectLanguage(_ value: AppLanguage) {
        Localization.language = value
        language = value
        value.save()
        claudeSession.refreshLanguage()
        ResetForecastWindow.shared.refreshLanguage()
        onChange?()
    }
    func choose(_ id: String) { history[provider].selectedID = id; persist(); onChange?() }
    func selectProvider(_ value: UsageProvider) {
        guard value != provider else { return }
        history.selectedProvider = value
        now = Date()
        persist()
        onChange?()
        if stale { refresh() }
    }
    func refreshAll() {
        for provider in UsageProvider.allCases { refresh(provider: provider) }
        refreshResetRadar()
    }
    func refresh() {
        refresh(provider: provider)
        if provider == .codex { refreshResetRadar() }
    }
    var resetRadarAssessment: ResetRadarAssessment? {
        resetRadar?.assessment(at: now, failed: resetRadarError != nil || !resetRadarVerified)
    }
    var canRefreshResetRadar: Bool {
        resetRadarEnabled && !resetRadarRefreshing && now.timeIntervalSince(resetRadarAttempt ?? .distantPast) >= ResetRadarClient.minimumInterval
    }
    func setResetRadarEnabled(_ enabled: Bool) {
        resetRadarEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "resetRadarEnabled")
        if enabled { refreshResetRadar() }
    }
    func refreshResetRadar() {
        guard canRefreshResetRadar else { return }
        resetRadarRefreshing = true
        resetRadarAttempt = Date()
        resetRadarTask = Task { [weak self] in
            let result: Result<ResetRadarSnapshot, Error>
            do { result = .success(try await ResetRadarClient.fetch()) }
            catch { result = .failure(error) }
            guard let self else { return }
            self.resetRadarRefreshing = false
            self.now = Date()
            // Disabling this public feed never changes an account's quota or budget.
            guard self.resetRadarEnabled else { return }
            switch result {
            case .success(let snapshot):
                self.resetRadar = snapshot
                self.resetRadarVerified = true
                self.resetRadarFailure = nil
                // Public cache is independent of account history; cache failure is non-fatal.
                try? FileManager.default.createDirectory(at: self.resetRadarCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let data = try? JSONEncoder().encode(snapshot) {
                    try? data.write(to: self.resetRadarCacheURL, options: .atomic)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.resetRadarCacheURL.path)
                }
            case .failure(let error):
                self.resetRadarFailure = error
            }
        }
    }
    func connectClaude() {
        guard !disconnectingClaude else { return }
        claudeEnabled = true
        UserDefaults.standard.set(true, forKey: "claudeWebConnectionEnabled")
        claudeSession.showLogin { [weak self] in
            self?.claudeNeedsLogin = false
            self?.refresh(provider: .claude)
        }
    }
    func disconnectClaude() {
        claudeEnabled = false
        disconnectingClaude = true
        UserDefaults.standard.set(false, forKey: "claudeWebConnectionEnabled")
        verified.remove(.claude)
        errors[.claude] = nil
        retryAfter[.claude] = nil
        claudeNeedsLogin = false
        claudeSession.disconnect { [weak self] in
            self?.disconnectingClaude = false
            self?.onChange?()
        }
        onChange?()
    }
    func openClaude() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Claude.app"))
    }

    private func refresh(provider: UsageProvider) {
        guard provider != .claude || (claudeEnabled && !claudeNeedsLogin && !disconnectingClaude) else { return }
        guard !refreshing.contains(provider), Date() >= (retryAfter[provider] ?? .distantPast) else { return }
        refreshing.insert(provider)
        lastAttempt[provider] = Date()
        onChange?()
        if provider == .claude {
            claudeSession.fetch { [weak self] result in self?.complete(result, provider: .claude) }
        } else {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let result = Result { try CodexClient.fetch() }
                Task { @MainActor in self?.complete(result, provider: .codex) }
            }
        }
    }

    private func complete(_ result: Result<UsageSnapshot, Error>, provider: UsageProvider) {
        refreshing.remove(provider)
        now = Date()
        guard provider != .claude || claudeEnabled else { onChange?(); return }
        switch result {
        case .success(let current):
            errors[provider] = nil
            retryAfter[provider] = nil
            verified.insert(provider)
            if provider == .claude { claudeNeedsLogin = false }
            // Commit to the provider that started this request, even if the
            // visible toggle changed while it was loading.
            history[provider].ingest(current)
            persist()
        case .failure(let failure):
            errors[provider] = failure
            if let error = failure as? ClaudeUsageError {
                switch error {
                case .notSignedIn, .expired, .scopeMissing, .ambiguousAccount:
                    claudeNeedsLogin = true
                    verified.remove(.claude)
                case .throttled(let seconds):
                    retryAfter[provider] = Date().addingTimeInterval(seconds)
                default: break
                }
            }
        }
        onChange?()
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(history).write(to: cacheURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
            persistenceFailed = false
        } catch { persistenceFailed = true }
    }
}

func number(_ value: Double) -> String { String(format: "%.1f", value) }
func localTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Localization.locale
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}
func resetTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Localization.locale
    formatter.dateFormat = L("M 月 d 日 HH:mm")
    return formatter.string(from: date)
}
