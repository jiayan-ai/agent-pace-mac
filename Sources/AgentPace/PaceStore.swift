import AppKit
import SwiftUI
import PaceCore

@MainActor
final class PaceStore: ObservableObject {
    @Published private(set) var autoResetEnabled = (try? AutoResetAuthorization.authorizedAccount()) != nil
    @Published private(set) var autoResetUnconfirmed = false
    @Published private(set) var autoResetMessage: String?
    @Published private(set) var lastResetResult: AutoResetCompletedAttempt?
    @Published private var confirmedResetCreditIDs: Set<String> = []
    @Published private var resetJournalReadable = true
    @Published private var autoResetRunning = false
    @Published private var resetAwaitingQuotaSync = false
    @Published private(set) var manualResetCreditID: String?
    var resetBusy: Bool { autoResetRunning || manualResetCreditID != nil }
    private var autoResetAttempt: Date?
    @Published private var history = PaceHistory()
    @Published private var refreshing: Set<UsageProvider> = []
    @Published private var errors: [UsageProvider: Error] = [:]
    @Published private var verified: Set<UsageProvider> = []
    @Published var now = Date()
    @Published private var persistenceFailed = false
    @Published private(set) var language = Localization.language
    @Published private(set) var claudeTokens: ClaudeTokenSnapshot?
    @Published private(set) var claudeTokensRefreshing = false
    private var claudeTokensAttempt: Date?
    private var claudeTokensTimeZone: String?
    var persistenceError: String? { persistenceFailed ? L("今日记录暂时无法保存；重新打开后会重新计算预算。") : nil }
    @Published private(set) var claudeEnabled = UserDefaults.standard.bool(forKey: "claudeWebConnectionEnabled")
    @Published private(set) var claudeNeedsLogin = false
    @Published private(set) var disconnectingClaude = false
    @Published private(set) var perplexityEnabled = PerplexityWebSession.persistsLogin && UserDefaults.standard.bool(forKey: "perplexityConnectionEnabled")
    @Published private(set) var perplexityNeedsLogin = false
    @Published private(set) var perplexityConnecting = false
    @Published private(set) var disconnectingPerplexity = false
    private lazy var perplexitySession = PerplexityWebSession()
    private var perplexityGeneration = 0
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
    private let diagnostics: Bool
    // These summaries depend on activity and the UTC day, not the current minute.
    // Keep their caches unpublished so reading them while rendering emits no updates.
    private var usagePatternCache: (provider: UsageProvider, day: Date, value: UsagePattern)?
    private var codexTokensCache: (day: Date, value: CodexTokenActivity)?

    init(diagnostics: Bool = false) {
        self.diagnostics = diagnostics
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
        checkAutoResetStatus()
        // Menu diagnostics can use saved display data without triggering background
        // account refreshes, automatic Reset, wake handling, or local token scans.
        guard !diagnostics else { perplexityEnabled = false; return }
        timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
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
                    let creditExpired = provider == .codex && ResetCreditPace.expiredDetailsNeedRefresh(
                        credits: record.snapshot?.response.rateLimitResetCredits, now: self.now)
                    var interval: TimeInterval = crossedDay || sessionResetPassed || creditExpired ? 60 : 300
                    if provider == .codex {
                        // A failed quota refresh must not block redemption for the
                        // entire five-minute window before the next normal refresh.
                        interval = min(interval, AutoResetPolicy.refreshInterval(
                            credits: self.resetCreditsExcludingConfirmed(record.snapshot),
                            enabled: self.autoResetEnabled, now: self.now))
                        if self.resetAwaitingQuotaSync || !self.resetJournalReadable { interval = min(interval, 60) }
                    }
                    if self.now.timeIntervalSince(self.lastAttempt[provider] ?? .distantPast) >= interval {
                        self.refresh(provider: provider)
                    }
                }
                self.checkAutoResetStatus()
                self.tryAutoReset()
                if self.now.timeIntervalSince(self.claudeTokensAttempt ?? .distantPast) >= 300 ||
                    (self.claudeTokens != nil && self.claudeTokensDayChanged) {
                    self.refreshClaudeTokens()
                }
                if self.now.timeIntervalSince(self.resetRadarAttempt ?? .distantPast) >= ResetRadarClient.refreshInterval {
                    self.refreshResetRadar()
                }
            }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
        refreshClaudeTokens()
    }

    var provider: UsageProvider { history.selectedProvider }
    var perplexityCredits: PerplexityCredits? { history.perplexityCredits }
    var perplexityImported: Bool { history.perplexityImported == true }
    var perplexityWeeklyPace: Double? {
        guard !stale, let balance = perplexityCredits, let remaining = balance.weeklyRemainingPercent,
              let reset = balance.weeklyResetAt, reset > now else { return nil }
        return remaining / max(1, reset.timeIntervalSince(now) / 86400)
    }
    var perplexityPlanPace: Double? {
        stale ? nil : perplexityCredits?.dailyPlanCredits(asOf: now)
    }
    var snapshot: UsageSnapshot? { history[provider].snapshot }
    var planningResetCredits: ResetCredits? {
        resetCreditsExcludingConfirmed(snapshot)
    }
    private func resetCreditsExcludingConfirmed(_ snapshot: UsageSnapshot?) -> ResetCredits? {
        guard let credits = snapshot?.response.rateLimitResetCredits else { return nil }
        return ResetCredits(availableCount: credits.availableCount,
                            credits: credits.credits?.filter { !confirmedResetCreditIDs.contains($0.id) })
    }
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
        guard provider == .codex, !resetBusy, !resetAwaitingQuotaSync, !autoResetUnconfirmed, resetJournalReadable,
              let selected, selected.bucketID == "codex", let snapshot,
              now.timeIntervalSince(snapshot.fetchedAt) >= 0 else { return nil }
        return ResetCreditPace.evaluate(window: selected.window,
                                        credits: planningResetCredits,
                                        stale: stale, now: now)
    }
    var creditPlanNeedsConfirmation: Bool {
        guard provider == .codex, let snapshot, let selected, selected.bucketID == "codex" else { return false }
        if resetBusy || resetAwaitingQuotaSync || autoResetUnconfirmed || !resetJournalReadable { return true }
        if let plan = history[provider].resetPlanBudgets?["\(snapshot.accountKey)/\(selected.id)"],
           Calendar.current.startOfDay(for: now) == plan.dayStart,
           plan.timeZoneID == Calendar.current.timeZone.identifier,
           !plan.isCurrent(now: now, snapshotAt: snapshot.fetchedAt, stale: stale) { return true }
        guard let credits = planningResetCredits, credits.availableCount > 0 else { return false }
        return ResetCreditPace.needsConfirmation(window: selected.window, credits: credits, stale: stale,
                                                  snapshotInFuture: now.timeIntervalSince(snapshot.fetchedAt) < 0,
                                                  now: now)
    }
    var budget: DailyBudget? {
        guard let selected, let snapshot else { return nil }
        return history[provider].budgets["\(snapshot.accountKey)/\(selected.id)"]
    }
    var resetPlanBudget: ResetPlanBudget? {
        guard provider == .codex, let selected, selected.bucketID == "codex", let snapshot,
              let plan = history[provider].resetPlanBudgets?["\(snapshot.accountKey)/\(selected.id)"],
              plan.isCurrent(now: now, snapshotAt: snapshot.fetchedAt, stale: stale) else { return nil }
        return plan
    }
    var noActiveClaudeLimits: Bool {
        provider == .claude && snapshot != nil && windows.isEmpty && !stale
    }
    var stale: Bool {
        if provider == .perplexity {
            guard verified.contains(.perplexity), let balance = perplexityCredits else { return true }
            let age = now.timeIntervalSince(balance.fetchedAt)
            return error != nil || age < 0 || age > 660
        }
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
        if provider == .perplexity {
            let prefix = stale || perplexityImported ? "≈" : ""
            if let balance = perplexityCredits {
                if let weekly = balance.weeklyRemainingPercent, balance.weeklyResetAt.map({ $0 > now }) != false {
                    let credits = weekly == 0 ? balance.total.map { " · \(creditNumber($0)) cr" } ?? "" : ""
                    return "Perplexity \(prefix)\(creditNumber(weekly))%\(credits)"
                }
                if let total = balance.total { return "Perplexity \(prefix)\(creditNumber(total)) cr" }
                if let pace = perplexityPlanPace { return "Perplexity \(prefix)\(creditNumber(pace)) cr/d" }
            }
            return "Perplexity \(isRefreshing ? L("同步中") : L("待同步"))"
        }
        if let sessionPace { return sessionPace.menuTitle(stale: stale) }
        if creditPlanNeedsConfirmation { return "Codex \(L("待同步"))" }
        if let pace = creditPace {
            return "Codex \(number(pace.allowance))\(pace.isFinalHour ? "% · <1h" : "%/h")"
        }
        if let plan = resetPlanBudget {
            return "Codex \(number(plan.leftToday))%" + (plan.includesReset ? " · \(L("计划"))" : "")
        }
        let title = selected?.bucketID == "claude_fable" ? "Fable" : provider.shortTitle
        if noActiveClaudeLimits { return "Claude · \(L("无生效额度窗口"))" }
        guard let budget = validBudget else { return "\(title) \(isRefreshing ? L("同步中") : L("待同步"))" }
        return "\(title) \(stale ? "≈" : "")\(number(budget.leftToday))%"
    }
    var menuTooltip: String {
        if provider == .perplexity {
            guard let balance = perplexityCredits else { return L("连接 Perplexity 以查看 Computer 用量") }
            var parts = ["Perplexity Computer"]
            if let weekly = balance.weeklyRemainingPercent {
                if let reset = balance.weeklyResetAt, reset <= now { parts.append(L("周额度等待刷新")) }
                else { parts.append(L("周额度剩余 \(creditNumber(weekly))%")) }
            }
            if let total = balance.total { parts.append(L("积分余额 \(creditNumber(total))")) }
            parts.append(L("记录时间 \(resetTime(balance.fetchedAt))"))
            return parts.joined(separator: "\n")
        }
        if let pace = sessionPace {
            let allowance = pace.allowance.map { "\(number($0))\(pace.unit)" } ?? L("待同步")
            return "Claude · \(pace.heading) \(allowance)\n\(pace.countdown)\(stale ? L(" · 上次记录") : "")"
        }
        if creditPlanNeedsConfirmation { return L("额度计划待同步确认，请刷新额度。") }
        if let pace = creditPace {
            let value = "\(number(pace.allowance))\(pace.isFinalHour ? "%" : L("% / 小时"))"
            return L("Codex · Reset 券到期前建议 \(value)\n距到期 \(pace.countdown)")
        }
        if let plan = resetPlanBudget {
            return plan.includesReset
                ? L("Codex · 今日计划剩余 \(number(plan.leftToday))%（含 Reset 计划）；当前实际余额 \(number(plan.actualRemaining))%。")
                : L("Codex · 今日建议剩余 \(number(plan.leftToday))%；当前实际余额 \(number(plan.actualRemaining))%。")
        }
        let over = validBudget?.overBudget ?? 0
        return over > 0 ? L("\(provider.title) · 今日已超额 \(number(over)) 个百分点")
            : L("\(provider.title) · 今天还可用的额度")
    }
    var daysLeft: Double? { selected?.window.resetDate.map { max(0, $0.timeIntervalSince(now) / 86400) } }
    var usagePattern: UsagePattern {
        let day = AccountActivity.calendar.startOfDay(for: now)
        if let cached = usagePatternCache, cached.provider == provider, cached.day == day {
            return cached.value
        }
        let value = UsagePattern(activity: history[provider].activity, now: now)
        usagePatternCache = (provider, day, value)
        return value
    }
    var activityUpdatedAt: Date? { history[provider].activityFetchedAt }
    var codexTokens: CodexTokenActivity {
        let day = AccountActivity.calendar.startOfDay(for: now)
        if let cached = codexTokensCache, cached.day == day { return cached.value }
        let value = CodexTokenActivity(activity: history[.codex].activity, now: now)
        codexTokensCache = (day, value)
        return value
    }
    var codexTokensUpdatedAt: Date? { history[.codex].activityFetchedAt }
    var codexTokensStale: Bool {
        let record = history[.codex]
        guard verified.contains(.codex), let date = record.activityFetchedAt else { return true }
        return errors[.codex] != nil || date != record.snapshot?.fetchedAt ||
            now.timeIntervalSince(date) < 0 || now.timeIntervalSince(date) > 660
    }
    var claudeTokensDayChanged: Bool {
        guard let snapshot = claudeTokens else { return false }
        return !snapshot.isCurrentDay(now: now, calendar: .current, scannedTimeZoneID: claudeTokensTimeZone)
    }
    var claudeTokensStale: Bool {
        guard let date = claudeTokens?.fetchedAt else { return true }
        return claudeTokensDayChanged || now.timeIntervalSince(date) < 0 || now.timeIntervalSince(date) > 660
    }

    func refreshClaudeTokens() {
        guard !claudeTokensRefreshing else { return }
        claudeTokensRefreshing = true
        claudeTokensAttempt = Date()
        let scanTime = Date()
        let scanCalendar = Calendar.current
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = ClaudeLocalTokens.read(now: scanTime, calendar: scanCalendar)
            Task { @MainActor in
                guard let self else { return }
                self.claudeTokens = result
                self.claudeTokensTimeZone = scanCalendar.timeZone.identifier
                self.claudeTokensRefreshing = false
            }
        }
    }
    var resetAdvice: ResetAdvice {
        let historyAge = activityUpdatedAt.map { now.timeIntervalSince($0) } ?? .infinity
        return ResetAdvice.evaluate(response: snapshot?.response, pattern: usagePattern,
                                    historyFresh: historyAge >= 0 && historyAge < 6 * 3600,
                                    stale: stale, now: now)
    }
    func setAutoResetEnabled(_ enabled: Bool) {
        guard !enabled || (verified.contains(.codex) && history[.codex].snapshot != nil) else {
            autoResetMessage = L("请先同步 Codex 账户后再开启。")
            refresh(provider: .codex)
            return
        }
        let account = enabled ? history[.codex].snapshot?.accountKey : nil
        do { try AutoResetAuthorization.setEnabled(enabled, accountKey: account) }
        catch { autoResetMessage = L("无法保存自动 Reset 设置，请重试。"); return }
        autoResetEnabled = enabled
        autoResetMessage = nil
        if enabled { refresh(provider: .codex); tryAutoReset() }
    }

    private func tryAutoReset() {
        guard autoResetEnabled, !resetBusy, !resetAwaitingQuotaSync, !refreshing.contains(.codex), verified.contains(.codex),
              errors[.codex] == nil, let snapshot = history[.codex].snapshot,
              (try? AutoResetAuthorization.authorizedAccount()) == snapshot.accountKey,
              now.timeIntervalSince(snapshot.fetchedAt) >= 0,
              now.timeIntervalSince(snapshot.fetchedAt) < 660,
              let credit = AutoResetPolicy.candidate(credits: resetCreditsExcludingConfirmed(snapshot), now: now),
              now.timeIntervalSince(autoResetAttempt ?? .distantPast) >= 60 else { return }
        autoResetRunning = true
        autoResetAttempt = now
        autoResetMessage = L("正在确认并使用即将到期的 Reset…")
        let directory = cacheURL.deletingLastPathComponent()
        let accountKey = snapshot.accountKey
        let creditID = credit.id
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result {
                try AutoResetJournal.perform(directory: directory, accountKey: accountKey, creditID: creditID,
                                             retryKnownUnused: true, minimumRetryInterval: 60) { key in
                    try CodexClient.consumeResetCredit(expectedAccountKey: accountKey, creditID: creditID, idempotencyKey: key)
                }
            }
            Task { @MainActor in
                guard let self else { return }
                self.autoResetRunning = false
                self.resetAwaitingQuotaSync = true
                // Space retries from the result, matching the durable journal's
                // interval even when the request itself takes several seconds.
                self.autoResetAttempt = Date()
                switch result {
                case .success(.reset): self.autoResetMessage = L("已自动使用 Reset，正在同步额度。")
                case .success(.alreadyRedeemed): self.autoResetMessage = L("这张 Reset 已使用，正在同步额度。")
                case .success(.nothingToReset): self.autoResetMessage = L("未使用：当前没有可重置的额度。")
                case .success(.noCredit): self.autoResetMessage = L("未使用：该 Reset 已不可用。")
                case .failure(let error):
                    self.autoResetMessage = L("自动 Reset 未确认：\((error as? LocalizedError)?.errorDescription ?? L("请检查网络后重试。"))")
                }
                self.checkAutoResetStatus()
                self.refresh(provider: .codex)
                self.onChange?()
            }
        }
    }

    private func checkAutoResetStatus() {
        guard !resetBusy, let account = history[.codex].snapshot?.accountKey else { return }
        do {
            let latest = try AutoResetJournal.latestCompletedAttempt(directory: cacheURL.deletingLastPathComponent(), accountKey: account)
            if latest != lastResetResult { lastResetResult = latest }
            let accounting = try AutoResetJournal.accountingState(directory: cacheURL.deletingLastPathComponent(), accountKey: account)
            confirmedResetCreditIDs = accounting.confirmedCreditIDs
            let currentKeys = Set((history[.codex].snapshot?.response.windows ?? []).map { "\(account)/\($0.id)" })
            if history[.codex].resetPlanBudgets?.contains(where: { key, plan in
                currentKeys.contains(key) &&
                    (!Set(plan.availableCreditIDs).isDisjoint(with: accounting.confirmedCreditIDs) ||
                     accounting.latestResetAt.map { $0 > plan.observedAt } == true)
            }) == true {
                resetAwaitingQuotaSync = true
            }
            resetJournalReadable = true
        } catch {
            // Never carry another account's result across a switch if reading fails.
            lastResetResult = nil
            confirmedResetCreditIDs = []
            resetJournalReadable = false
        }
        if let value = try? AutoResetJournal.hasUnconfirmed(directory: cacheURL.deletingLastPathComponent(), accountKey: account) {
            autoResetUnconfirmed = value
        }
    }

    func clearUnconfirmedAutoReset() {
        guard !resetBusy, let account = history[.codex].snapshot?.accountKey else { return }
        do {
            try AutoResetJournal.clearUnconfirmed(directory: cacheURL.deletingLastPathComponent(), accountKey: account)
            autoResetUnconfirmed = false
            autoResetMessage = L("已解除暂停；已核实的旧操作不会重新提交。")
            refresh(provider: .codex)
        } catch { autoResetMessage = L("无法保存自动 Reset 记录，操作已暂停。") }
    }

    func canUseReset(_ credit: ResetCredit) -> Bool {
        guard provider == .codex, !resetBusy, !resetAwaitingQuotaSync, resetJournalReadable,
              !confirmedResetCreditIDs.contains(credit.id), !isRefreshing, !stale,
              let snapshot, Date().timeIntervalSince(snapshot.fetchedAt) >= 0 else { return false }
        return ManualResetPolicy.credit(id: credit.id, credits: snapshot.response.rateLimitResetCredits, now: Date()) != nil
    }

    func useReset(_ credit: ResetCredit, accountKey: String) {
        guard !resetBusy else { return }
        guard history[.codex].snapshot?.accountKey == accountKey else {
            autoResetMessage = AutoResetError.accountChanged.errorDescription
            return
        }
        guard canUseReset(credit) else {
            autoResetMessage = L("请先同步最新额度，再使用 Reset。")
            refresh(provider: .codex)
            return
        }
        manualResetCreditID = credit.id
        autoResetMessage = L("正在确认并使用这张 Reset…")
        let directory = cacheURL.deletingLastPathComponent()
        let creditID = credit.id
        let expectedExpiry = credit.expiryDate
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result {
                try AutoResetJournal.perform(directory: directory, accountKey: accountKey, creditID: creditID,
                                             retryKnownUnused: true) { key in
                    try CodexClient.consumeResetCredit(expectedAccountKey: accountKey, creditID: creditID,
                                                       idempotencyKey: key, mode: .manual(expectedExpiry: expectedExpiry))
                }
            }
            Task { @MainActor in
                guard let self else { return }
                self.manualResetCreditID = nil
                self.resetAwaitingQuotaSync = true
                // Let the fresh response arrive before another automatic attempt.
                self.autoResetAttempt = Date()
                if self.history[.codex].snapshot?.accountKey == accountKey {
                    switch result {
                    case .success(.reset): self.autoResetMessage = L("已使用 Reset，正在同步额度。")
                    case .success(.alreadyRedeemed): self.autoResetMessage = L("这张 Reset 已使用，正在同步额度。")
                    case .success(.nothingToReset): self.autoResetMessage = L("未使用：当前没有可重置的额度。")
                    case .success(.noCredit): self.autoResetMessage = L("未使用：该 Reset 已不可用。")
                    case .failure(let error):
                        self.autoResetMessage = (error as? LocalizedError)?.errorDescription ?? L("Reset 结果未确认，请刷新额度或在 Codex 核对。")
                    }
                } else {
                    self.autoResetMessage = L("账户已切换，请回到原账户核对 Reset 结果。")
                }
                self.checkAutoResetStatus()
                self.refresh(provider: .codex)
                self.onChange?()
            }
        }
    }

    func selectLanguage(_ value: AppLanguage) {
        Localization.language = value
        language = value
        value.save()
        claudeSession.refreshLanguage()
        if perplexityConnecting || perplexityEnabled { perplexitySession.refreshLanguage() }
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
        if !diagnostics && stale { refresh() }
    }
    func refreshAll() {
        refreshClaudeTokens()
        for provider in UsageProvider.allCases { refresh(provider: provider) }
        refreshResetRadar()
    }
    func refresh() {
        if provider == .claude { refreshClaudeTokens() }
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

    func connectPerplexity() {
        guard !disconnectingPerplexity else { return }
        perplexityConnecting = true
        perplexitySession.onLoginWindowClosed = { [weak self] in self?.perplexityConnecting = false }
        perplexitySession.showLogin { [weak self] in self?.refreshPerplexity(interactive: true) }
    }

    func disconnectPerplexity() {
        guard !disconnectingPerplexity else { return }
        perplexityGeneration += 1
        disconnectingPerplexity = true
        perplexityEnabled = false
        perplexityConnecting = false
        perplexityNeedsLogin = false
        UserDefaults.standard.removeObject(forKey: "perplexityConnectionEnabled")
        clearPerplexityRecord()
        refreshing.remove(.perplexity)
        perplexitySession.disconnect { [weak self] in self?.disconnectingPerplexity = false }
    }

    func clearPerplexityRecord() {
        history.perplexityCredits = nil
        history.perplexityImported = nil
        verified.remove(.perplexity)
        errors[.perplexity] = nil
        persist()
        onChange?()
    }

    func importPerplexity(_ text: String) -> Bool {
        guard !perplexityEnabled, !disconnectingPerplexity, !refreshing.contains(.perplexity),
              let balance = PerplexityCredits.parse(visibleText: text) else { return false }
        savePerplexity(balance, imported: true)
        return true
    }

    private func savePerplexity(_ balance: PerplexityCredits, imported: Bool) {
        now = Date()
        history.perplexityCredits = balance
        history.perplexityImported = imported
        errors[.perplexity] = nil
        verified.insert(.perplexity)
        persist()
        onChange?()
    }

    private func refreshPerplexity(interactive: Bool) {
        guard !disconnectingPerplexity, !refreshing.contains(.perplexity),
              interactive || (perplexityEnabled && !perplexityNeedsLogin && !perplexityConnecting) else { return }
        refreshing.insert(.perplexity)
        lastAttempt[.perplexity] = Date()
        onChange?()
        let generation = perplexityGeneration
        perplexitySession.fetch { [weak self] result in
            guard let self, self.perplexityGeneration == generation else { return }
            self.refreshing.remove(.perplexity)
            self.now = Date()
            switch result {
            case .success(let balance):
                self.perplexityEnabled = true
                UserDefaults.standard.set(PerplexityWebSession.persistsLogin, forKey: "perplexityConnectionEnabled")
                self.perplexityNeedsLogin = false
                self.perplexityConnecting = false
                self.savePerplexity(balance, imported: false)
            case .failure(let error):
                if case .signInRequired? = error as? PerplexitySessionError {
                    self.perplexityNeedsLogin = true
                    if !self.perplexityImported { self.clearPerplexityRecord() }
                }
                self.errors[.perplexity] = error
                self.onChange?()
            }
        }
    }

    private func refresh(provider: UsageProvider) {
        if provider == .perplexity { refreshPerplexity(interactive: false); return }
        guard provider != .codex || !resetBusy else { return }
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
            let accounting: (confirmedCreditIDs: Set<String>, latestResetAt: Date?)
            do {
                accounting = provider == .codex
                    ? try AutoResetJournal.accountingState(directory: cacheURL.deletingLastPathComponent(), accountKey: current.accountKey)
                    : ([], nil)
            } catch {
                // Without the redemption ledger, delayed server rows could count
                // an already-used credit twice. Keep the old plan unconfirmed.
                resetJournalReadable = false
                errors[provider] = error
                onChange?()
                return
            }
            if provider == .codex { resetAwaitingQuotaSync = false }
            errors[provider] = nil
            retryAfter[provider] = nil
            verified.insert(provider)
            if provider == .claude { claudeNeedsLogin = false }
            if provider == .codex, autoResetEnabled,
               (try? AutoResetAuthorization.authorizedAccount()) != current.accountKey {
                do {
                    try AutoResetAuthorization.setEnabled(false, accountKey: nil)
                    autoResetEnabled = false
                    autoResetMessage = L("Codex 账户已变化，请重新开启自动 Reset。")
                } catch {
                    autoResetEnabled = false
                    autoResetMessage = L("账户已变化，但无法保存关闭状态；请检查应用存储权限。")
                }
            }
            // Commit to the provider that started this request, even if the
            // visible toggle changed while it was loading.
            history[provider].ingest(current, confirmedResetAt: accounting.latestResetAt,
                                     excludedCreditIDs: accounting.confirmedCreditIDs)
            // Ingestion may replace activity or clear it after an account change.
            if usagePatternCache?.provider == provider { usagePatternCache = nil }
            if provider == .codex { codexTokensCache = nil }
            persist()
            if provider == .codex { checkAutoResetStatus(); tryAutoReset() }
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
        guard !diagnostics else { return }
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
