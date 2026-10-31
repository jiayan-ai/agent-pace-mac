import Foundation

public struct AccountTokenSummary: Codable, Equatable {
    public let lifetimeTokens: Double?
    public let peakDailyTokens: Double?

    public init(lifetimeTokens: Double? = nil, peakDailyTokens: Double? = nil) {
        self.lifetimeTokens = lifetimeTokens
        self.peakDailyTokens = peakDailyTokens
    }

    public var sanitized: AccountTokenSummary {
        AccountTokenSummary(lifetimeTokens: validTokenCount(lifetimeTokens),
                            peakDailyTokens: validTokenCount(peakDailyTokens))
    }
}

private func validTokenCount(_ value: Double?) -> Double? {
    guard let value, value.isFinite, value >= 0, value <= 9_007_199_254_740_991,
          value.rounded(.towardZero) == value else { return nil }
    return value
}

extension AccountActivity {
    /// Preserve today's server bucket for token totals; pattern analysis still uses recent().
    public func sanitized(now: Date) -> AccountActivity {
        guard let dailyUsageBuckets else {
            return AccountActivity(dailyUsageBuckets: nil, summary: summary?.sanitized)
        }
        let today = Self.calendar.startOfDay(for: now)
        let first = Self.calendar.date(byAdding: .day, value: -30, to: today)!
        var days: [String: DailyActivity] = [:]
        for bucket in dailyUsageBuckets {
            guard validTokenCount(bucket.tokens) != nil, let date = Self.date(bucket.startDate),
                  date >= first, date <= today else { continue }
            if bucket.tokens >= (days[bucket.startDate]?.tokens ?? -1) { days[bucket.startDate] = bucket }
        }
        return AccountActivity(dailyUsageBuckets: days.values.sorted { $0.startDate < $1.startDate },
                               summary: summary?.sanitized)
    }
}

/// Values describe service-reported account activity, not a conversion from quota percentages.
public struct CodexTokenActivity {
    public let today: Double?
    public let last30Days: Double?
    public let lifetime: Double?
    public let recordedDays: Int

    public init(activity: AccountActivity?, now: Date) {
        let clean = activity?.sanitized(now: now)
        let todayStart = AccountActivity.calendar.startOfDay(for: now)
        let first = AccountActivity.calendar.date(byAdding: .day, value: -29, to: todayStart)!
        let buckets = (clean?.dailyUsageBuckets ?? []).filter {
            AccountActivity.date($0.startDate).map { $0 >= first } ?? false
        }
        today = buckets.first { $0.startDate == AccountActivity.dayLabel(now) }?.tokens
        recordedDays = buckets.count
        let total = buckets.reduce(0) { $0 + $1.tokens }
        last30Days = buckets.isEmpty ? nil : validTokenCount(total)
        lifetime = clean?.summary?.lifetimeTokens
    }
}
