import Foundation

public enum UsageProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex, claude, perplexity
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .perplexity: return "Perplexity"
        }
    }
    public var shortTitle: String { self == .claude ? "Claude" : title }
}

public struct ClaudeResetObservation: Codable, Equatable {
    public let accountKey: String
    public let observedAt: Date
    public let inventory: ClaudeLimitResets
}

public struct ProviderHistory: Codable {
    public var snapshot: UsageSnapshot?
    public var budgets: [String: DailyBudget]
    // Optional for compatibility with existing saved histories.
    public var resetPlanBudgets: [String: ResetPlanBudget]?
    public var selectedID: String
    public var activity: AccountActivity?
    public var activityFetchedAt: Date?
    // Keep a prior observation only when the quota query
    // succeeds but the independent offers section cannot be verified.
    private var previousClaudeResets: ClaudeResetObservation?

    /// If the latest quota snapshot has no Claude reset inventory, the returned
    /// observation is historical. Its timestamp must be labeled as last recorded.
    public var claudeResetObservation: ClaudeResetObservation? {
        guard let snapshot else { return nil }
        if let inventory = snapshot.response.claudeLimitResets {
            return ClaudeResetObservation(accountKey: snapshot.accountKey, observedAt: snapshot.fetchedAt,
                                         inventory: inventory)
        }
        guard previousClaudeResets?.accountKey == snapshot.accountKey else { return nil }
        return previousClaudeResets
    }

    public mutating func clearClaudeResetObservation() {
        previousClaudeResets = nil
        guard let current = snapshot, current.response.claudeLimitResets != nil else { return }
        var quotas = current.response
        quotas.claudeLimitResets = nil
        snapshot = UsageSnapshot(response: quotas, accountKey: current.accountKey,
                                 fetchedAt: current.fetchedAt, activity: current.activity)
    }

    public init(snapshot: UsageSnapshot? = nil, budgets: [String: DailyBudget] = [:], selectedID: String = "") {
        self.snapshot = snapshot
        self.budgets = budgets
        self.selectedID = selectedID
    }

    public mutating func ingest(_ current: UsageSnapshot, confirmedReset: Bool = false,
                                confirmedResetAt: Date? = nil,
                                excludedCreditIDs: Set<String> = [],
                                calendar: Calendar = .current) {
        let priorSnapshot = snapshot
        previousClaudeResets = current.response.claudeLimitResets == nil && priorSnapshot?.accountKey == current.accountKey
            ? claudeResetObservation : nil
        if snapshot?.accountKey != current.accountKey {
            budgets = [:]
            resetPlanBudgets = nil
            activity = nil
            activityFetchedAt = nil
        }
        if let currentActivity = current.activity,
           currentActivity.dailyUsageBuckets != nil || currentActivity.summary != nil {
            activity = currentActivity.sanitized(now: current.fetchedAt)
            activityFetchedAt = current.fetchedAt
        }
        snapshot = current
        var next: [String: DailyBudget] = [:]
        // Keep today's observation ledger through a temporarily missing window.
        // The UI requires its observedAt to match the fresh snapshot before use.
        var nextPlans = (resetPlanBudgets ?? [:]).filter {
            $0.value.dayStart == calendar.startOfDay(for: current.fetchedAt) &&
                $0.value.timeZoneID == calendar.timeZone.identifier
        }
        for item in current.response.windows {
            let key = "\(current.accountKey)/\(item.id)"
            let priorPlan = resetPlanBudgets?[key]
            let lastWindowObservation = priorPlan?.observedAt ??
                (priorSnapshot?.accountKey == current.accountKey ? priorSnapshot?.fetchedAt : nil)
            // A receipt must be applied to every affected window once. A newer
            // provider snapshot may have omitted one of those windows, so its
            // timestamp cannot replace that window's own observation baseline.
            let hasNewResetReceipt = confirmedResetAt.map { receipt in
                receipt.timeIntervalSince1970.isFinite && receipt <= current.fetchedAt &&
                    lastWindowObservation.map { receipt > $0 } != false
            } ?? false
            if let budget = DailyBudget.reconcile(previous: budgets[key], window: item.window, now: current.fetchedAt, calendar: calendar) {
                next[key] = budget
            }
            if item.bucketID == "codex", let plan = ResetPlanBudget.reconcile(
                previous: priorPlan, window: item.window,
                credits: current.response.rateLimitResetCredits, now: current.fetchedAt,
                confirmedReset: confirmedReset || hasNewResetReceipt,
                excludedCreditIDs: excludedCreditIDs, calendar: calendar,
                priorDailyBudget: budgets[key]) {
                nextPlans[key] = plan
            }
        }
        budgets = next
        resetPlanBudgets = nextPlans.isEmpty ? nil : nextPlans
        if !current.response.windows.contains(where: { $0.id == selectedID }) {
            selectedID = current.response.windows.first?.id ?? ""
        }
    }
}

public struct PaceHistory: Codable {
    public var providers: [String: ProviderHistory]
    public var selectedProvider: UsageProvider
    public var perplexityCredits: PerplexityCredits?
    public var perplexityImported: Bool?

    public init(providers: [String: ProviderHistory] = [:], selectedProvider: UsageProvider = .codex) {
        self.providers = providers
        self.selectedProvider = selectedProvider
    }

    public subscript(_ provider: UsageProvider) -> ProviderHistory {
        get { providers[provider.rawValue] ?? ProviderHistory() }
        set { providers[provider.rawValue] = newValue }
    }

    private enum CodingKeys: String, CodingKey { case providers, selectedProvider, perplexityCredits, perplexityImported }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.providers) {
            providers = try container.decode([String: ProviderHistory].self, forKey: .providers)
            let selection = try container.decodeIfPresent(String.self, forKey: .selectedProvider) ?? "codex"
            selectedProvider = UsageProvider(rawValue: selection) ?? .codex
            perplexityCredits = try? container.decode(PerplexityCredits.self, forKey: .perplexityCredits)
            perplexityImported = try container.decodeIfPresent(Bool.self, forKey: .perplexityImported)
        } else {
            // Version 1 stored a single Codex record at the root. Preserve its budget.
            let legacy = try ProviderHistory(from: decoder)
            providers = [UsageProvider.codex.rawValue: legacy]
            selectedProvider = .codex
        }
    }
}
