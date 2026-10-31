import Foundation
import PaceCore

struct ResetPlanTests {
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return value
    }
    func date(_ day: Int, month: Int = 11, hour: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }
    var now: Date { date(1) }
    var expiry: Date { date(6, hour: 23) }
    func window(_ used: Double = 0, reset: Date? = nil) -> UsageWindow {
        UsageWindow(usedPercent: used, windowDurationMins: 10080,
                    resetsAt: (reset ?? date(8)).timeIntervalSince1970)
    }
    func row(_ id: String = "one", expiry: Date? = nil, status: String = "available", type: String = "codexRateLimits") -> [String: Any] {
        ["id": id, "status": status, "resetType": type,
         "expiresAt": (expiry ?? self.expiry).timeIntervalSince1970]
    }
    func credits(_ rows: [[String: Any]]? = nil, count: Int? = nil) throws -> ResetCredits {
        let rows = rows ?? [row()]
        let data = try JSONSerialization.data(withJSONObject: ["availableCount": count ?? rows.count, "credits": rows])
        return try JSONDecoder().decode(ResetCredits.self, from: data)
    }
    func plan(_ used: Double = 0, previous: ResetPlanBudget? = nil,
              credits value: ResetCredits? = nil, at time: Date? = nil,
              reset: Date? = nil) throws -> ResetPlanBudget {
        try require(ResetPlanBudget.reconcile(previous: previous, window: window(used, reset: reset),
                                             credits: value ?? credits(), now: time ?? now, calendar: calendar))
    }
    func testInclusiveDatesActualRemainingAndBatch() throws {
        let first = try plan()
        try expect(first.planningDays == 6 && first.startingTotal == 200)
        try expect(abs(first.allowance - 200.0 / 6) < 0.00001)
        try expect(first.actualRemaining == 100 && first.availableCount == 1)
        let partial = try plan(75)
        try expect(partial.startingTotal == 125 && abs(partial.allowance - 125.0 / 6) < 0.00001)
        let grouped = try plan(100, credits: credits([row("b"), row("a"), row("later", expiry: date(7))]))
        try expect(grouped.creditIDs == ["a", "b"] && grouped.startingTotal == 200)
        try expect(grouped.allowance == first.allowance)
        let sameDeadline = try plan(reset: expiry)
        try expect(sameDeadline.startingTotal == 200 && sameDeadline.planningDays == 6)
        let earlierNaturalReset = try plan(reset: date(5))
        try expect(earlierNaturalReset.startingTotal == 200 && earlierNaturalReset.planningDays == 6)
        try expect(abs(earlierNaturalReset.allowance - 200.0 / 6) < 0.00001)
    }
    func testUnverifiedDetailsNeverCreateCapacity() throws {
        let unknownExpiry: [String: Any] = ["id": "unknown", "status": "available", "resetType": "codexRateLimits"]
        let invalid: [ResetCredits?] = [nil, ResetCredits(availableCount: 4),
            try credits([], count: 2), try credits([row()], count: 0),
            try credits([row()], count: -1), try credits([row(" ")]),
            try credits([unknownExpiry]), try credits([row(status: "used")]),
            try credits([row(status: "unknown")]), try credits([row(type: "other")]),
            try credits([row(expiry: now)]), try credits([row(), row()]),
            try credits([row("a"), row("b")], count: 1),
            try credits([["id": "extreme", "status": "available", "resetType": "codexRateLimits", "expiresAt": 1e300]])]
        for value in invalid {
            try expect(ResetPlanBudget.reconcile(previous: nil, window: window(), credits: value,
                                                 now: now, calendar: calendar) == nil)
        }
        let subset = try plan(credits: credits([row(), unknownExpiry, row("used", status: "used")], count: 5))
        try expect(subset.availableCount == 1 && subset.startingTotal == 200)
        let conflict = try plan(credits: credits([row("duplicate"), row("duplicate", status: "used"), row("good")]))
        try expect(conflict.creditIDs == ["good"])
    }
    func testFrozenBudgetRedemptionAndObservedSpending() throws {
        let first = try plan()
        let spent = try plan(20, previous: first, at: now.addingTimeInterval(300))
        try expect(spent.allowance == first.allowance && spent.consumed == 20)
        try expect(abs(spent.leftToday - (first.allowance - 20)) < 0.00001)
        let redeemed = try plan(0, previous: spent, credits: ResetCredits(availableCount: 0),
                                at: now.addingTimeInterval(600), reset: date(9))
        try expect(redeemed.consumed == 20 && redeemed.allowance == first.allowance)
        try expect(redeemed.expiryAt == first.expiryAt && redeemed.startedAt == first.startedAt)
        try expect(redeemed.availableCount == 0 && redeemed.liveCapacity == 100)
        let continued = try plan(10, previous: redeemed, credits: ResetCredits(availableCount: 0),
                                 at: now.addingTimeInterval(900), reset: date(9))
        try expect(continued.consumed == 30 && abs(continued.leftToday - (first.allowance - 30)) < 0.00001)
        let overspent = try plan(30, previous: continued, credits: ResetCredits(availableCount: 0),
                                 at: now.addingTimeInterval(1200), reset: date(9))
        try expect(overspent.consumed == 50 && overspent.leftToday < 0)
        // A service correction cannot refund already observed daily spending.
        let corrected = try plan(25, previous: overspent, credits: ResetCredits(availableCount: 0),
                                 at: now.addingTimeInterval(1500), reset: date(9))
        try expect(corrected.consumed == 50 && corrected.allowance == first.allowance)
        let old = try plan(99, previous: corrected, at: now)
        try expect(old == corrected)
        // A reset with nonzero usage exposes real consumption in the new cycle.
        let spentAgain = try plan(80, previous: first, at: now.addingTimeInterval(300))
        let nonzeroReset = try plan(20, previous: spentAgain, credits: ResetCredits(availableCount: 0),
                                    at: now.addingTimeInterval(600), reset: date(9))
        try expect(nonzeroReset.consumed == 100)
        let jitter = try plan(20, previous: spentAgain,
                             at: now.addingTimeInterval(600), reset: date(8).addingTimeInterval(1))
        try expect(jitter.consumed == 80)
        // A natural reset before the credit deadline contributes no predicted
        // 100%. Once confirmed, its actual balance changes without clearing use.
        let noon = date(1, hour: 12)
        let beforeNatural = try plan(reset: noon)
        let spentBeforeNatural = try plan(20, previous: beforeNatural,
                                          at: now.addingTimeInterval(3600), reset: noon)
        let afterNatural = try plan(0, previous: spentBeforeNatural,
                                    at: noon.addingTimeInterval(60), reset: date(8, hour: 12))
        try expect(afterNatural.consumed == 20 && afterNatural.allowance == beforeNatural.allowance)
        try expect(afterNatural.startingTotal == 200 && afterNatural.liveCapacity == 200)
        try expect(afterNatural.actualRemaining == 100 && afterNatural.availableCount == 1)
        try expect(afterNatural.expiryAt == beforeNatural.expiryAt)
    }
    func testDayChangesNewCreditsExpiryAndRevocation() throws {
        let first = try plan(80)
        let other = try credits([row(), row("new", expiry: date(5)), row("later", expiry: date(7))])
        let unchanged = try plan(85, previous: first, credits: other, at: now.addingTimeInterval(300))
        try expect(unchanged.creditIDs == ["one"] && unchanged.allowance == first.allowance)
        let next = try plan(85, previous: unchanged, credits: other, at: date(2))
        try expect(next.creditIDs == ["new"] && next.planningDays == 4 && next.consumed == 0)
        try expect(next.startingTotal == 115 && next.allowance == 28.75)
        let revoked = try plan(85, previous: unchanged, credits: ResetCredits(availableCount: 0),
                               at: now.addingTimeInterval(600))
        try expect(revoked.liveCapacity == 15 && revoked.leftToday == 15 && revoked.consumed == 5)
        let reappeared = try plan(85, previous: revoked, at: now.addingTimeInterval(900))
        try expect(reappeared.availableCount == 0 && reappeared.liveCapacity == 15)
        let earlierNaturalReset = try plan(85, previous: unchanged,
                                          at: now.addingTimeInterval(900), reset: date(4))
        try expect(earlierNaturalReset.availableCount == 1 && earlierNaturalReset.liveCapacity == 115)
        let expiring = try plan(80, credits: credits([row(expiry: now.addingTimeInterval(1800))]))
        let after = expiring.adjustedForExpiry(at: now.addingTimeInterval(1800))
        try expect(after.availableCount == 0 && after.liveCapacity == 20 && after.leftToday == 20)
        let freshExpired = try plan(85, previous: expiring,
                                    credits: credits([row(expiry: now.addingTimeInterval(1800), status: "expired")]),
                                    at: now.addingTimeInterval(1801))
        try expect(freshExpired.consumed == 5 && freshExpired.liveCapacity == 15)
        try expect(ResetPlanBudget.reconcile(previous: revoked, window: window(85),
                                             credits: ResetCredits(availableCount: 0), now: date(2), calendar: calendar) == nil)
    }
    func testPersistenceAccountIsolationAndMissingSnapshots() throws {
        func snapshot(_ used: Double, account: String = "a", at time: Date,
                      hasWindow: Bool = true) throws -> UsageSnapshot {
            try UsageSnapshot(response: UsageResponse(rateLimits: hasWindow ? UsageBucket(limitId: "codex", limitName: "Codex", primary: window(used)) : nil,
                                                   rateLimitResetCredits: credits()),
                          accountKey: account, fetchedAt: time)
        }
        var history = ProviderHistory()
        history.ingest(try snapshot(0, at: now), calendar: calendar)
        history.ingest(try snapshot(20, at: now.addingTimeInterval(300)), calendar: calendar)
        let key = "a/codex/primary"
        let baseline = try require(history.resetPlanBudgets?[key])
        let restored = try JSONDecoder().decode(ProviderHistory.self, from: JSONEncoder().encode(history))
        try expect(restored.resetPlanBudgets?[key] == baseline)
        history.ingest(try snapshot(20, at: now.addingTimeInterval(600), hasWindow: false), calendar: calendar)
        let missing = try require(history.resetPlanBudgets?[key])
        try expect(missing == baseline && !missing.isCurrent(now: now.addingTimeInterval(600),
                                                             snapshotAt: now.addingTimeInterval(600), stale: false, calendar: calendar))
        history.ingest(try snapshot(30, at: now.addingTimeInterval(900)), calendar: calendar)
        try expect(history.resetPlanBudgets?[key]?.consumed == 30)
        history.ingest(try snapshot(50, account: "b", at: now.addingTimeInterval(1200)), calendar: calendar)
        try expect(history.resetPlanBudgets?[key] == nil)
        try expect(history.resetPlanBudgets?["b/codex/primary"]?.consumed == 0)
        let legacy = try JSONDecoder().decode(ProviderHistory.self, from: Data(#"{"budgets":{},"selectedID":""}"#.utf8))
        try expect(legacy.resetPlanBudgets == nil)
    }
    func testStaleDSTTimezoneAndHourlyPrecedence() throws {
        let first = try plan()
        try expect(first.isCurrent(now: now, snapshotAt: now, stale: false, calendar: calendar))
        try expect(!first.isCurrent(now: now, snapshotAt: now, stale: true, calendar: calendar))
        try expect(!first.isCurrent(now: now, snapshotAt: now.addingTimeInterval(1), stale: false, calendar: calendar))
        try expect(!first.isCurrent(now: date(2), snapshotAt: now, stale: false, calendar: calendar))
        var utc = calendar
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        try expect(!first.isCurrent(now: now, snapshotAt: now, stale: false, calendar: utc))
        let start = date(30, month: 10)
        let acrossDST = try require(ResetPlanBudget.reconcile(previous: nil, window: window(),
                                                               credits: credits([row(expiry: date(4))]), now: start, calendar: calendar))
        try expect(acrossDST.planningDays == 6 && acrossDST.startingTotal == 200)
        try expect(date(4).timeIntervalSince(start) == 121 * 3600)
        let soon = try credits([row(expiry: now.addingTimeInterval(72 * 3600))])
        let hourly = try require(ResetCreditPace.evaluate(window: window(40), credits: soon, stale: false, now: now))
        let planned = try plan(40, credits: soon)
        try expect(abs(hourly.allowance - 60.0 / 72) < 0.00001)
        try expect(planned.startingTotal == 160 && planned.allowance == 40)
        try expect(AutoResetPolicy.candidate(credits: soon, now: now) == nil)
    }
}
