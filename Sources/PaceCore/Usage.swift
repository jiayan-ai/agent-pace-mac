import Foundation

public struct UsageWindow: Codable, Equatable {
    public let usedPercent: Double?
    public let windowDurationMins: Int?
    public let resetsAt: Double?

    public init(usedPercent: Double?, windowDurationMins: Int?, resetsAt: Double?) {
        self.usedPercent = usedPercent
        self.windowDurationMins = windowDurationMins
        self.resetsAt = resetsAt
    }

    public var remaining: Double? {
        guard let usedPercent, usedPercent.isFinite else { return nil }
        return max(0, min(100, 100 - usedPercent))
    }
    public var resetDate: Date? { resetsAt.map(Date.init(timeIntervalSince1970:)) }
}

public struct UsageBucket: Codable {
    public let limitId: String?
    public let limitName: String?
    public let primary: UsageWindow?
    public let secondary: UsageWindow?
    public let planType: String?

    public init(limitId: String?, limitName: String?, primary: UsageWindow?, secondary: UsageWindow? = nil, planType: String? = nil) {
        self.limitId = limitId
        self.limitName = limitName
        self.primary = primary
        self.secondary = secondary
        self.planType = planType
    }
}

public struct UsageResponse: Codable {
    public let rateLimits: UsageBucket?
    public let rateLimitsByLimitId: [String: UsageBucket]?
    public let rateLimitResetCredits: ResetCredits?
    public internal(set) var claudeLimitResets: ClaudeLimitResets?
    public internal(set) var claudeNoActiveLimits: Bool?

    public init(rateLimits: UsageBucket?, rateLimitsByLimitId: [String: UsageBucket]? = nil,
                rateLimitResetCredits: ResetCredits? = nil) {
        self.rateLimits = rateLimits
        self.rateLimitsByLimitId = rateLimitsByLimitId
        self.rateLimitResetCredits = rateLimitResetCredits
    }

    public var windows: [MeteredWindow] {
        let buckets: [String: UsageBucket]
        if let multiple = rateLimitsByLimitId, !multiple.isEmpty {
            buckets = multiple
        } else if let legacy = rateLimits {
            buckets = [legacy.limitId ?? "codex": legacy]
        } else {
            buckets = [:]
        }
        return buckets.flatMap { key, bucket in
            [("primary", bucket.primary), ("secondary", bucket.secondary)].compactMap { slot, window in
                window.map { MeteredWindow(bucketID: key, name: bucket.limitName ?? key, slot: slot, window: $0) }
            }
        }.sorted {
            let aMain = ["codex", "claude"].contains($0.bucketID)
            let bMain = ["codex", "claude"].contains($1.bucketID)
            if aMain != bMain { return aMain }
            if $0.bucketID != $1.bucketID { return $0.bucketID < $1.bucketID }
            let a = $0.window.windowDurationMins ?? 0
            let b = $1.window.windowDurationMins ?? 0
            return a == b ? $0.id < $1.id : a > b
        }
    }
}

public struct MeteredWindow: Identifiable, Equatable, Codable {
    public let bucketID: String
    public let name: String
    public let slot: String
    public let window: UsageWindow
    public var id: String { "\(bucketID)/\(slot)" }
    public var label: String {
        let title = name == "codex" ? "Codex" : name
        guard let mins = window.windowDurationMins else { return L("\(title) · 未知周期") }
        if mins % 1440 == 0 { return L("\(title) · \(mins / 1440) 天") }
        if mins % 60 == 0 { return L("\(title) · \(mins / 60) 小时") }
        return L("\(title) · \(mins) 分钟")
    }
}

public struct DailyBudget: Codable, Equatable {
    public let dayStart: Date
    public let timeZoneID: String
    public let resetAt: Double
    public let windowDurationMins: Int
    public let startedAt: Date
    public let startingUsed: Double
    public let startingRemaining: Double
    public let planningDays: Double
    public let allowance: Double
    public var lastUsed: Double

    /// Freeze a daily allowance once. Repeated refreshes only subtract observed use.
    public static func reconcile(previous: DailyBudget?, window: UsageWindow, now: Date,
                                 calendar: Calendar = .current) -> DailyBudget? {
        guard let remaining = window.remaining, let rawUsed = window.usedPercent,
              let reset = window.resetsAt, reset.isFinite,
              let duration = window.windowDurationMins, duration > 0,
              reset > now.timeIntervalSince1970 else { return nil }
        let used = max(0, min(100, rawUsed))
        let start = calendar.startOfDay(for: now)
        if var old = previous, old.dayStart == start,
           old.timeZoneID == calendar.timeZone.identifier,
           old.resetAt > now.timeIntervalSince1970,
           abs(old.resetAt - reset) < min(60, Double(duration) * 0.6),
           old.windowDurationMins == duration,
           used + 0.001 >= old.lastUsed {
            old.lastUsed = used
            return old
        }
        let days = max(1, (reset - now.timeIntervalSince1970) / 86400)
        return DailyBudget(dayStart: start, timeZoneID: calendar.timeZone.identifier,
                           resetAt: reset, windowDurationMins: duration, startedAt: now,
                           startingUsed: used, startingRemaining: remaining,
                           planningDays: days, allowance: remaining / days, lastUsed: used)
    }

    public var consumed: Double { max(0, lastUsed - startingUsed) }
    public var leftToday: Double { min(100 - lastUsed, allowance - consumed) }
    public var overBudget: Double { max(0, consumed - allowance) }
    public var progress: Double { allowance > 0 ? min(1, consumed / allowance) : 1 }
}
