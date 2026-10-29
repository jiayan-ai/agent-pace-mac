import Foundation
import PaceCore

struct ResetTests {
    let now = AccountActivity.date("2026-10-12")!.addingTimeInterval(12 * 3600)

    func activity(busy: Bool = false) -> AccountActivity {
        let days = (1...30).map { offset -> DailyActivity in
            let date = AccountActivity.calendar.date(byAdding: .day, value: -offset, to: now)!
            let monday = AccountActivity.calendar.component(.weekday, from: date) == 2
            return DailyActivity(startDate: AccountActivity.dayLabel(date), tokens: busy && monday ? 1000 : 100)
        }
        return AccountActivity(dailyUsageBuckets: days)
    }
    func credits(_ extra: String = "") throws -> ResetCredits {
        let json = """
        {"availableCount":2,"credits":[{"id":"fixture-credit","resetType":"codexRateLimits","status":"available","grantedAt":1,"expiresAt":\(now.addingTimeInterval(2*86400).timeIntervalSince1970),"title":"Full reset","description":null}\(extra)]}
        """
        return try JSONDecoder().decode(ResetCredits.self, from: Data(json.utf8))
    }
    func response(used: Double, hours: Double = 48, credits: ResetCredits? = ResetCredits(availableCount: 2)) -> UsageResponse {
        UsageResponse(rateLimits: UsageBucket(limitId: "codex", limitName: "Codex",
                                              primary: UsageWindow(usedPercent: used, windowDurationMins: 10080,
                                                                   resetsAt: now.addingTimeInterval(hours*3600).timeIntervalSince1970)),
                      rateLimitResetCredits: credits)
    }
    func advice(_ response: UsageResponse, busy: Bool = false, fresh: Bool = true, stale: Bool = false) -> ResetAdvice {
        ResetAdvice.evaluate(response: response, pattern: UsagePattern(activity: activity(busy: busy), now: now),
                             historyFresh: fresh, stale: stale, now: now)
    }
    func testResetCountsAndUnknownDetails() throws {
        let value = try credits()
        try expect(value.availableCount == 2 && value.usableDetails(at: now).count == 1)
        try expect(advice(response(used: 20, credits: nil)).kind == .unavailable)
        try expect(advice(response(used: 20, credits: ResetCredits(availableCount: 0))).kind == .noCredits)
        let old = try JSONDecoder().decode(UsageResponse.self, from: Data(#"{"rateLimits":null}"#.utf8))
        try expect(old.rateLimitResetCredits == nil)
    }
    func testRollingMonthAndMissingDays() throws {
        var days = activity().dailyUsageBuckets!
        days.removeLast()
        days += [DailyActivity(startDate: "2026-10-12", tokens: 999999),
                 DailyActivity(startDate: "2026-09-01", tokens: 999999),
                 DailyActivity(startDate: "2026-10-11", tokens: 100),
                 DailyActivity(startDate: "2026-02-30", tokens: 4),
                 DailyActivity(startDate: "2026-10-10", tokens: -1)]
        let pattern = UsagePattern(activity: AccountActivity(dailyUsageBuckets: days), now: now)
        try expect(pattern.observedDays == 29)
        try expect(pattern.days.allSatisfy { $0.tokens == 100 })
        try expect(AccountActivity(dailyUsageBuckets: nil).recent(now: now).dailyUsageBuckets == nil)
    }
    func testBusyWeekdayAndTrend() throws {
        let pattern = UsagePattern(activity: activity(busy: true), now: now)
        try expect(pattern.sufficient && pattern.busyWeekday == 2 && pattern.highDemandSoon)
        let steady = UsagePattern(activity: activity(), now: now)
        try expect(steady.busyWeekday == nil && !steady.highDemandSoon)
        try expect(abs(try require(steady.recentRatio) - 1) < 0.001)
        let sparse = UsagePattern(activity: AccountActivity(dailyUsageBuckets: Array(activity().dailyUsageBuckets!.prefix(6))), now: now)
        try expect(!sparse.sufficient && sparse.busyWeekday == nil && sparse.recentRatio == nil)
    }
    func testAdviceUsesActualQuotaInsteadOfDailyOverspend() throws {
        try expect(advice(response(used: 30), busy: true).kind == .reserve)
        try expect(advice(response(used: 95), busy: true).kind == .consider)
        try expect(advice(response(used: 95), busy: false).kind == .wait)
        try expect(advice(response(used: 100), fresh: false).kind == .consider)
        try expect(advice(response(used: 100, hours: 2), busy: true).kind == .wait)
        try expect(advice(response(used: 95), busy: true, stale: true).kind == .refresh)
        try expect(advice(response(used: 95), busy: true, fresh: false).kind == .learning)
    }
    func testExpiringCreditsAndResetBoundaries() throws {
        let value = try credits()
        let result = advice(response(used: 20, credits: value))
        try expect(result.kind == .reserve && result.preferredCreditID == "fixture-credit")
        let expired = try JSONDecoder().decode(ResetCredits.self, from: Data(#"{"availableCount":1,"credits":[{"id":"expired","status":"available","resetType":"codexRateLimits","expiresAt":1}]}"#.utf8))
        try expect(advice(response(used: 100, credits: expired)).kind == .refresh)
        try expect(advice(response(used: 100, hours: 0)).kind == .refresh)
        let unknownKind = try JSONDecoder().decode(ResetCredits.self, from: Data(#"{"availableCount":1,"credits":[{"id":"future","status":"future-status","resetType":"future-kind"}]}"#.utf8))
        try expect(unknownKind.usableDetails(at: now).isEmpty)
    }
    func testCreditPaceUsesEarliestExpiryAndCurrentRemaining() throws {
        let credits = try creditDetails(count: 2, entries: [("later", "available", "codexRateLimits", 20),
                                                           ("earlier", "available", "codexRateLimits", 10)])
        let window = UsageWindow(usedPercent: 40, windowDurationMins: 10080,
                                 resetsAt: now.addingTimeInterval(6 * 86400).timeIntervalSince1970)
        let pace = try require(ResetCreditPace.evaluate(window: window, credits: credits, stale: false, now: now))
        try expect(pace.creditID == "earlier" && abs(pace.allowance - 6) < 0.001)
        try expect(!pace.isFinalHour && pace.countdown == "10 小时 0 分钟")
        let later = now.addingTimeInterval(2 * 3600)
        let consumed = UsageWindow(usedPercent: 52, windowDurationMins: 10080, resetsAt: window.resetsAt)
        let updated = try require(ResetCreditPace.evaluate(window: consumed, credits: credits, stale: false, now: later))
        try expect(abs(updated.allowance - 6) < 0.001)
        let final = try require(ResetCreditPace.evaluate(window: consumed, credits: credits, stale: false,
                                                        now: now.addingTimeInterval(9.5 * 3600)))
        try expect(final.isFinalHour && final.allowance == 48 && final.countdown == "30 分钟")
    }

    func testCreditPaceRejectsUncertainOrInapplicableData() throws {
        let window = UsageWindow(usedPercent: 40, windowDurationMins: 10080,
                                 resetsAt: now.addingTimeInterval(20 * 3600).timeIntervalSince1970)
        let good = try creditDetails(count: 1, entries: [("good", "available", "codexRateLimits", 10)])
        func evaluate(_ credits: ResetCredits?, _ selected: UsageWindow? = nil, stale: Bool = false, at time: Date? = nil) -> ResetCreditPace? {
            ResetCreditPace.evaluate(window: selected ?? window, credits: credits, stale: stale, now: time ?? now)
        }
        try expect(evaluate(good, stale: true) == nil)
        try expect(evaluate(nil) == nil)
        try expect(evaluate(try creditDetails(count: 0, entries: [("good", "available", "codexRateLimits", 10)])) == nil)
        try expect(evaluate(try creditDetails(count: 1, entries: [("unknown", "available", "codexRateLimits", nil)])) == nil)
        try expect(evaluate(try creditDetails(count: 1, entries: [("wrong", "available", "other", 10)])) == nil)
        try expect(evaluate(try creditDetails(count: 1, entries: [("spent", "used", "codexRateLimits", 10)])) == nil)
        try expect(evaluate(try creditDetails(count: 1, entries: [("same", "available", "codexRateLimits", 20)])) == nil)
        try expect(evaluate(try creditDetails(count: 1, entries: [("after", "available", "codexRateLimits", 21)])) == nil)
        try expect(evaluate(good, at: now.addingTimeInterval(10 * 3600)) == nil)
        try expect(evaluate(try creditDetails(count: 2, entries: [("expired", "available", "codexRateLimits", -1), ("future", "available", "codexRateLimits", 10)])) == nil)
        try expect(evaluate(good, UsageWindow(usedPercent: nil, windowDurationMins: 10080, resetsAt: window.resetsAt)) == nil)
        try expect(evaluate(good, UsageWindow(usedPercent: 40, windowDurationMins: nil, resetsAt: window.resetsAt)) == nil)
        try expect(evaluate(good, UsageWindow(usedPercent: 40, windowDurationMins: 10080, resetsAt: nil)) == nil)
        try expect(evaluate(good, UsageWindow(usedPercent: 40, windowDurationMins: 10080, resetsAt: now.timeIntervalSince1970)) == nil)
        let empty = try require(evaluate(good, UsageWindow(usedPercent: 100, windowDurationMins: 10080, resetsAt: window.resetsAt)))
        try expect(empty.allowance == 0)
    }

    private func creditDetails(count: Int, entries: [(String, String, String, Double?)]) throws -> ResetCredits {
        let values: [[String: Any]] = entries.map { id, status, type, hours in
            var value: [String: Any] = ["id": id, "status": status, "resetType": type]
            if let hours { value["expiresAt"] = now.addingTimeInterval(hours * 3600).timeIntervalSince1970 }
            return value
        }
        let data = try JSONSerialization.data(withJSONObject: ["availableCount": count, "credits": values])
        return try JSONDecoder().decode(ResetCredits.self, from: data)
    }
    func testActivityPersistenceAndAccountIsolation() throws {
        var history = ProviderHistory()
        history.ingest(UsageSnapshot(response: response(used: 20), accountKey: "a", fetchedAt: now, activity: activity()))
        history.ingest(UsageSnapshot(response: response(used: 25), accountKey: "a", fetchedAt: now.addingTimeInterval(300)))
        try expect(history.activity?.dailyUsageBuckets?.count == 30)
        try expect(history.activityFetchedAt == now)
        let saved = try JSONDecoder().decode(ProviderHistory.self, from: JSONEncoder().encode(history))
        try expect(saved.activity?.dailyUsageBuckets?.count == 30)
        history.ingest(UsageSnapshot(response: response(used: 30), accountKey: "b", fetchedAt: now))
        try expect(history.activity == nil && history.activityFetchedAt == nil)
        let legacy = try JSONDecoder().decode(ProviderHistory.self, from: Data(#"{"budgets":{},"selectedID":""}"#.utf8))
        try expect(legacy.activity == nil)
    }
}
