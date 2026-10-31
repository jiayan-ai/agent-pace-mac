import Foundation
import PaceCore

struct TokenActivityTests {
    private let now = Date(timeIntervalSince1970: 1_793_570_400) // 2026-11-01 UTC

    func testTodayAndSummarySurviveWithoutChangingHistoricalPatterns() throws {
        let today = AccountActivity.dayLabel(now)
        let yesterday = AccountActivity.dayLabel(now.addingTimeInterval(-86400))
        let old = AccountActivity.dayLabel(now.addingTimeInterval(-31 * 86400))
        let future = AccountActivity.dayLabel(now.addingTimeInterval(86400))
        let activity = AccountActivity(dailyUsageBuckets: [
            DailyActivity(startDate: today, tokens: 200), DailyActivity(startDate: today, tokens: 250),
            DailyActivity(startDate: yesterday, tokens: 100), DailyActivity(startDate: old, tokens: 999),
            DailyActivity(startDate: future, tokens: 999), DailyActivity(startDate: "invalid", tokens: 999)
        ], summary: AccountTokenSummary(lifetimeTokens: 12_345, peakDailyTokens: 250))
        let clean = activity.sanitized(now: now)
        try expect(clean.dailyUsageBuckets?.count == 2)
        try expect(clean.recent(now: now).dailyUsageBuckets?.count == 1)
        let tokens = CodexTokenActivity(activity: clean, now: now)
        try expect(tokens.today == 250 && tokens.last30Days == 350 && tokens.recordedDays == 2 && tokens.lifetime == 12_345)
        let saved = try JSONDecoder().decode(AccountActivity.self, from: JSONEncoder().encode(clean))
        try expect(CodexTokenActivity(activity: saved, now: now).today == 250)
    }

    func testMissingInvalidAndExplicitZeroAreDistinct() throws {
        let today = AccountActivity.dayLabel(now)
        let missing = CodexTokenActivity(activity: AccountActivity(dailyUsageBuckets: nil,
            summary: AccountTokenSummary(lifetimeTokens: 10)), now: now)
        try expect(missing.today == nil && missing.last30Days == nil && missing.lifetime == 10)
        let invalid = CodexTokenActivity(activity: AccountActivity(dailyUsageBuckets: [
            DailyActivity(startDate: today, tokens: -1), DailyActivity(startDate: today, tokens: .infinity),
            DailyActivity(startDate: today, tokens: 0.5)
        ], summary: AccountTokenSummary(lifetimeTokens: .nan, peakDailyTokens: -1)), now: now)
        try expect(invalid.today == nil && invalid.last30Days == nil && invalid.lifetime == nil)
        let zero = CodexTokenActivity(activity: AccountActivity(dailyUsageBuckets: [DailyActivity(startDate: today, tokens: 0)]), now: now)
        try expect(zero.today == 0 && zero.last30Days == 0 && zero.recordedDays == 1)
        let overflow = AccountActivity(dailyUsageBuckets: [
            DailyActivity(startDate: today, tokens: 9_007_199_254_740_991),
            DailyActivity(startDate: AccountActivity.dayLabel(now.addingTimeInterval(-86400)), tokens: 1)
        ])
        try expect(CodexTokenActivity(activity: overflow, now: now).last30Days == nil)
        let boundary = AccountActivity(dailyUsageBuckets: [
            DailyActivity(startDate: AccountActivity.dayLabel(now.addingTimeInterval(-30 * 86400)), tokens: 500),
            DailyActivity(startDate: AccountActivity.dayLabel(now.addingTimeInterval(-29 * 86400)), tokens: 100)
        ])
        let total = CodexTokenActivity(activity: boundary, now: now)
        try expect(total.last30Days == 100 && total.recordedDays == 1 && total.today == nil)
    }

    func testAccountIsolationAndLegacySummaryMigration() throws {
        let response = UsageResponse(rateLimits: UsageBucket(limitId: "codex", limitName: nil,
            primary: UsageWindow(usedPercent: 0, windowDurationMins: 10080, resetsAt: now.addingTimeInterval(86400).timeIntervalSince1970)))
        var history = ProviderHistory()
        history.ingest(UsageSnapshot(response: response, accountKey: "a", fetchedAt: now,
            activity: AccountActivity(dailyUsageBuckets: nil, summary: AccountTokenSummary(lifetimeTokens: 40))))
        try expect(history.activity?.summary?.lifetimeTokens == 40 && history.activityFetchedAt == now)
        history.ingest(UsageSnapshot(response: response, accountKey: "a", fetchedAt: now.addingTimeInterval(10)))
        try expect(history.activity?.summary?.lifetimeTokens == 40 && history.activityFetchedAt == now)
        history.ingest(UsageSnapshot(response: response, accountKey: "b", fetchedAt: now.addingTimeInterval(20)))
        try expect(history.activity == nil && history.activityFetchedAt == nil)
        let old = try JSONDecoder().decode(AccountActivity.self, from: Data(#"{"dailyUsageBuckets":[]}"#.utf8))
        try expect(old.summary == nil && old.dailyUsageBuckets?.isEmpty == true)
    }
}
