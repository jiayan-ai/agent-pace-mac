import Foundation
import PaceCore

struct ResetPlanTests {
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return value
    }
    func date(_ day: Int, month: Int = 11, hour: Int = 10, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }
    var now: Date { date(1) }
    var expiry: Date { date(6, hour: 23) }
    var noCredits: ResetCredits { ResetCredits(availableCount: 0) }
    func window(_ used: Double = 0, reset: Date? = nil, duration: Int = 10080) -> UsageWindow {
        UsageWindow(usedPercent: used, windowDurationMins: duration,
                    resetsAt: (reset ?? date(8)).timeIntervalSince1970)
    }
    func row(_ id: String = "one", expiry: Date? = nil, status: String = "available", type: String = "codexRateLimits") -> [String: Any] {
        ["id": id, "status": status, "resetType": type,
         "expiresAt": (expiry ?? self.expiry).timeIntervalSince1970]
    }
    func credits(_ rows: [[String: Any]]? = nil, count: Int? = nil) throws -> ResetCredits {
        let rows = rows ?? [row()]
        return try JSONDecoder().decode(ResetCredits.self, from: JSONSerialization.data(
            withJSONObject: ["availableCount": count ?? rows.count, "credits": rows]))
    }
    func plan(_ used: Double = 0, previous: ResetPlanBudget? = nil,
              credits value: ResetCredits? = nil, at time: Date? = nil,
              reset: Date? = nil, confirmedReset: Bool = false,
              excludedCreditIDs: Set<String> = []) throws -> ResetPlanBudget {
        try require(ResetPlanBudget.reconcile(previous: previous, window: window(used, reset: reset),
                                             credits: value ?? credits(), now: time ?? now,
                                             confirmedReset: confirmedReset, excludedCreditIDs: excludedCreditIDs,
                                             calendar: calendar))
    }
    func near(_ actual: Double, _ expected: Double) throws {
        try expect(abs(actual - expected) < 0.00001)
    }
    func equations(_ value: ResetPlanBudget) throws {
        try near(value.startingTotal, value.startingRemaining + Double(value.creditIDs.count) * 100)
        try near(value.allowance, value.startingTotal / value.planningDays)
        try near(value.periodConsumed, value.consumed - (value.consumedBeforeBaseline ?? 0))
        try near(value.leftToday, value.allowance - value.periodConsumed)
        try near(value.overBudget, max(0, -value.leftToday))
    }

    func testInclusiveDatesActualRemainingAndBatch() throws {
        let first = try plan()
        try expect(first.planningDays == 6 && first.startingTotal == 200 && first.includesReset)
        try near(first.allowance, 200.0 / 6)
        try expect(first.actualRemaining == 100 && first.availableCount == 1)
        let partial = try plan(75)
        try expect(partial.startingTotal == 125)
        try near(partial.allowance, 125.0 / 6)
        let grouped = try plan(100, credits: credits([row("b"), row("a"), row("later", expiry: date(7))]))
        try expect(grouped.creditIDs == ["a", "b"] && grouped.startingTotal == 200)
        let sameDeadline = try plan(reset: expiry)
        try expect(sameDeadline.includesReset && sameDeadline.planningDays == 6)
        let earlierNaturalReset = try plan(reset: date(5))
        try expect(!earlierNaturalReset.includesReset && earlierNaturalReset.startingTotal == 100)
        try expect(earlierNaturalReset.planningDays == 4 && earlierNaturalReset.allowance == 25)
        let fractional = try plan(10, credits: noCredits, reset: now.addingTimeInterval(4.5 * 86400))
        try expect(fractional.planningDays == 4.5 && fractional.allowance == 20)
        let finalHours = try plan(75, credits: noCredits, reset: now.addingTimeInterval(3600))
        try expect(finalHours.planningDays == 1 && finalHours.allowance == 25)
        for value in [first, partial, grouped, sameDeadline, earlierNaturalReset, fractional, finalHours] {
            try equations(value)
        }
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
            let actualOnly = try require(ResetPlanBudget.reconcile(previous: nil, window: window(12),
                                                                   credits: value, now: now, calendar: calendar))
            try expect(!actualOnly.includesReset && actualOnly.startingTotal == 88 && actualOnly.availableCount == 0)
            try equations(actualOnly)
        }
        let subset = try plan(credits: credits([row(), unknownExpiry, row("used", status: "used")], count: 5))
        try expect(subset.availableCount == 1 && subset.startingTotal == 200)
        let conflict = try plan(credits: credits([row("duplicate"), row("duplicate", status: "used"), row("good")]))
        try expect(conflict.creditIDs == ["good"])
    }

    func testFrozenBudgetRedemptionAndObservedSpending() throws {
        let first = try plan()
        let spent = try plan(20, previous: first, at: now.addingTimeInterval(300))
        try expect(spent.allowance == first.allowance && spent.consumed == 20 && spent.periodConsumed == 20)
        try near(spent.leftToday, first.allowance - 20)
        let redeemed = try plan(0, previous: spent, credits: noCredits,
                                at: now.addingTimeInterval(600), reset: date(9), confirmedReset: true)
        try expect(redeemed.consumed == 20 && redeemed.periodConsumed == 0)
        try expect(!redeemed.includesReset && redeemed.recalculationReason == .quotaReset)
        try expect(redeemed.startedAt == now.addingTimeInterval(600) && redeemed.dayObservedAt == first.startedAt)
        try expect(redeemed.startingTotal == 100 && redeemed.liveCapacity == 100)
        let continued = try plan(10, previous: redeemed, credits: noCredits,
                                 at: now.addingTimeInterval(900), reset: date(9))
        try expect(continued.consumed == 30 && continued.periodConsumed == 10)
        try near(continued.leftToday, redeemed.allowance - 10)
        let overspent = try plan(30, previous: continued, credits: noCredits,
                                 at: now.addingTimeInterval(1200), reset: date(9))
        try expect(overspent.consumed == 50 && overspent.periodConsumed == 30 && overspent.leftToday < 0)
        try expect(overspent.startedAt == redeemed.startedAt)
        let old = try plan(99, previous: overspent, at: now)
        try expect(old == overspent)
        let spentAgain = try plan(80, previous: first, at: now.addingTimeInterval(300))
        let nonzeroReset = try plan(20, previous: spentAgain, credits: noCredits,
                                    at: now.addingTimeInterval(600), reset: date(9), confirmedReset: true)
        try expect(nonzeroReset.consumed == 100 && nonzeroReset.periodConsumed == 0)
        try expect(nonzeroReset.startingTotal == 80)
        for value in [first, spent, redeemed, continued, overspent, nonzeroReset] { try equations(value) }
    }

    func testDayChangesNewCreditsExpiryAndRevocation() throws {
        let first = try plan(80)
        let other = try credits([row(), row("new", expiry: date(5)), row("later", expiry: date(7))])
        let changed = try plan(85, previous: first, credits: other, at: now.addingTimeInterval(300))
        try expect(changed.creditIDs == ["new"] && changed.recalculationReason == .creditsChanged)
        try expect(changed.consumed == 5 && changed.periodConsumed == 0 && changed.planningDays == 5)
        try expect(changed.startingTotal == 115 && changed.allowance == 23)
        let next = try plan(85, previous: changed, credits: other, at: date(2))
        try expect(next.creditIDs == ["new"] && next.planningDays == 4 && next.consumed == 0)
        try expect(next.allowance == 28.75 && next.recalculationReason == .dayChanged)
        let revoked = try plan(85, previous: changed, credits: noCredits, at: now.addingTimeInterval(600))
        try expect(!revoked.includesReset && revoked.startingTotal == 15 && revoked.consumed == 5)
        try expect(revoked.periodConsumed == 0 && revoked.recalculationReason == .creditsChanged)
        let reappeared = try plan(85, previous: revoked, at: now.addingTimeInterval(900))
        try expect(reappeared.availableCount == 1 && reappeared.startingTotal == 115)
        try expect(reappeared.consumed == 5 && reappeared.periodConsumed == 0)
        let earlierNaturalReset = try plan(85, previous: reappeared,
                                          at: now.addingTimeInterval(1200), reset: date(4))
        try expect(!earlierNaturalReset.includesReset && earlierNaturalReset.startingTotal == 15)
        for value in [changed, next, revoked, reappeared, earlierNaturalReset] { try equations(value) }
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
        let moved = try require(ResetPlanBudget.reconcile(previous: first, window: window(), credits: credits(),
                                                         now: now, calendar: utc))
        try expect(moved.timeZoneID == utc.timeZone.identifier && moved.consumed == 0)
        let start = date(30, month: 10)
        let acrossDST = try require(ResetPlanBudget.reconcile(previous: nil, window: window(),
                                                              credits: credits([row(expiry: date(4))]), now: start, calendar: calendar))
        try expect(acrossDST.planningDays == 6 && acrossDST.startingTotal == 200)
        try expect(date(4).timeIntervalSince(start) == 121 * 3600)
        let soon = try credits([row(expiry: now.addingTimeInterval(72 * 3600))])
        let hourly = try require(ResetCreditPace.evaluate(window: window(40), credits: soon, stale: false, now: now))
        let planned = try plan(40, credits: soon)
        try near(hourly.allowance, 60.0 / 72)
        try expect(planned.startingTotal == 160 && planned.allowance == 40)
        try expect(AutoResetPolicy.candidate(credits: soon, now: now) == nil)
    }

    func testExpirySwitchesToNaturalWithFarFutureCredits() throws {
        let start = date(6, hour: 9)
        let deadline = date(6, hour: 15, minute: 40)
        let natural = date(12, hour: 10)
        let coupons = try credits([row("today", expiry: deadline), row("nov30", expiry: date(30)),
                                   row("dec1", expiry: date(1, month: 12))])
        let first = try plan(5, credits: coupons, at: start, reset: natural)
        let spent = try plan(12, previous: first, credits: coupons, at: deadline.addingTimeInterval(-1), reset: natural)
        try expect(spent.startingTotal == 195 && spent.consumed == 7 && spent.actualRemaining == 88)
        try expect(!spent.isCurrent(now: deadline, snapshotAt: spent.observedAt, stale: false, calendar: calendar))
        // A server row still marked available cannot keep an expired plan alive.
        let expired = try plan(12, previous: spent, credits: coupons, at: deadline, reset: natural)
        try expect(!expired.includesReset && expired.availableCount == 0 && expired.startingTotal == 88)
        try expect(expired.consumed == 7 && expired.periodConsumed == 0 && expired.dayObservedAt == start)
        try expect(expired.recalculationReason == .creditExpired && expired.targetDate == natural)
        try near(expired.leftToday, 88 / ((natural.timeIntervalSince(deadline)) / 86400))
        let continued = try plan(15, previous: expired, credits: coupons, at: deadline.addingTimeInterval(300), reset: natural)
        try expect(continued.consumed == 10 && continued.periodConsumed == 3 && continued.startedAt == deadline)
        try near(continued.leftToday, expired.allowance - 3)
        let reloaded = try JSONDecoder().decode(ResetPlanBudget.self, from: JSONEncoder().encode(continued))
        try expect(reloaded == continued)
        let again = try plan(15, previous: reloaded, credits: coupons, at: deadline.addingTimeInterval(600), reset: natural)
        try expect(!again.includesReset && again.allowance == expired.allowance && again.consumed == 10)
        for value in [expired, continued, again] { try equations(value) }
    }

    func testLegacyMigrationAndDailyBudgetSeed() throws {
        let time = date(6, hour: 9)
        let deadline = date(6, hour: 15, minute: 40)
        let natural = date(12)
        let first = try plan(5, credits: credits([row(expiry: deadline)]), at: time, reset: natural)
        let spent = try plan(12, previous: first, credits: credits([row(expiry: deadline)]), at: time.addingTimeInterval(600), reset: natural)
        var json = try require(JSONSerialization.jsonObject(with: JSONEncoder().encode(spent)) as? [String: Any])
        for key in ["basis", "schemaVersion", "consumedBeforeBaseline", "dayObservedAt", "recalculationReason", "highWaterUsed"] {
            json.removeValue(forKey: key)
        }
        let legacy = try JSONDecoder().decode(ResetPlanBudget.self, from: JSONSerialization.data(withJSONObject: json))
        try expect(legacy.startingTotal == 195 && legacy.consumed == 7)
        try expect(!legacy.isCurrent(now: time.addingTimeInterval(600), snapshotAt: legacy.observedAt,
                                    stale: false, calendar: calendar))
        let migrated = try plan(12, previous: legacy, credits: noCredits, at: deadline.addingTimeInterval(1), reset: natural)
        try expect(migrated.recalculationReason == .migrated && migrated.consumed == 7 && migrated.periodConsumed == 0)
        try expect(migrated.startingTotal == 88 && migrated.dayObservedAt == time && !migrated.includesReset)
        var daily = try require(DailyBudget.reconcile(previous: nil, window: window(5, reset: natural), now: time, calendar: calendar))
        daily = try require(DailyBudget.reconcile(previous: daily, window: window(10, reset: natural), now: time.addingTimeInterval(300), calendar: calendar))
        let seeded = try require(ResetPlanBudget.reconcile(previous: nil, window: window(12, reset: natural), credits: noCredits,
                                                          now: time.addingTimeInterval(600), calendar: calendar, priorDailyBudget: daily))
        try expect(seeded.consumed == 7 && seeded.periodConsumed == 0 && seeded.dayObservedAt == time)
        try expect(seeded.startingTotal == 88 && seeded.recalculationReason == .migrated)
        try equations(migrated)
        try equations(seeded)
    }

    func testHighWaterCorrectionsAndNaturalResets() throws {
        let first = try plan(0, credits: noCredits)
        let spent = try plan(50, previous: first, credits: noCredits, at: now.addingTimeInterval(60))
        let corrected = try plan(45, previous: spent, credits: noCredits, at: now.addingTimeInterval(120))
        try expect(corrected.consumed == 50 && corrected.highWaterUsed == 50 && corrected.periodConsumed == 0)
        try expect(corrected.recalculationReason == .balanceAdjusted)
        let rebound = try plan(50, previous: corrected, credits: noCredits, at: now.addingTimeInterval(180))
        try expect(rebound.consumed == 50 && rebound.periodConsumed == 0 && rebound.startingRemaining == 50)
        let beyond = try plan(55, previous: rebound, credits: noCredits, at: now.addingTimeInterval(240))
        try expect(beyond.consumed == 55 && beyond.periodConsumed == 5)
        let jitter = try plan(55, previous: beyond, credits: noCredits, at: now.addingTimeInterval(300),
                              reset: date(8).addingTimeInterval(1))
        try expect(jitter.consumed == 55 && jitter.startedAt == beyond.startedAt && jitter.allowance == beyond.allowance)
        let noon = date(1, hour: 12)
        let before = try plan(0, credits: noCredits, reset: noon)
        let beforeSpent = try plan(20, previous: before, credits: noCredits, at: now.addingTimeInterval(3600), reset: noon)
        try expect(!beforeSpent.isCurrent(now: noon, snapshotAt: beforeSpent.observedAt, stale: false, calendar: calendar))
        let after = try plan(5, previous: beforeSpent, credits: noCredits, at: noon.addingTimeInterval(60), reset: date(8, hour: 12))
        try expect(after.consumed == 25 && after.highWaterUsed == 5 && after.periodConsumed == 0)
        try expect(after.recalculationReason == .quotaReset && after.startingTotal == 95)
        let further = try plan(10, previous: after, credits: noCredits, at: noon.addingTimeInterval(120), reset: date(8, hour: 12))
        try expect(further.consumed == 30 && further.periodConsumed == 5)
        for value in [corrected, rebound, beyond, jitter, after, further] { try equations(value) }
    }

    func testConfirmedAndUnconfirmedRedemptionAndCapacity() throws {
        let first = try plan(5)
        let before = try plan(12, previous: first, at: now.addingTimeInterval(60))
        let noOp = try plan(12, previous: before, at: now.addingTimeInterval(120))
        try expect(noOp.startingTotal == 195 && noOp.consumed == 7 && noOp.startedAt == first.startedAt)
        // A disappearance alone does not create 100% or establish a new cycle.
        let disappeared = try plan(12, previous: before, credits: noCredits, at: now.addingTimeInterval(120))
        try expect(disappeared.startingTotal == 88 && disappeared.consumed == 7)
        try expect(disappeared.recalculationReason == .creditsChanged)
        // An observed increase without reset evidence is a correction, not redemption.
        let unknown = try plan(2, previous: before, credits: noCredits, at: now.addingTimeInterval(120))
        try expect(unknown.consumed == 7 && unknown.highWaterUsed == 12 && unknown.startingTotal == 98)
        try expect(unknown.recalculationReason != .quotaReset)
        // Explicit success permits a new cycle even when resetsAt is unchanged.
        let redeemed = try plan(2, previous: before, credits: noCredits, at: now.addingTimeInterval(120), confirmedReset: true)
        try expect(redeemed.consumed == 9 && redeemed.highWaterUsed == 2 && redeemed.periodConsumed == 0)
        try expect(redeemed.startingTotal == 98 && redeemed.recalculationReason == .quotaReset)
        let duplicate = try plan(2, previous: redeemed, credits: noCredits, at: redeemed.observedAt, confirmedReset: true)
        try expect(duplicate == redeemed)
        let continued = try plan(5, previous: redeemed, credits: noCredits, at: now.addingTimeInterval(180))
        try expect(continued.consumed == 12 && continued.periodConsumed == 3)
        let exhausted = try plan(100, previous: before, at: now.addingTimeInterval(120))
        let full = try plan(0, previous: exhausted, credits: noCredits, at: now.addingTimeInterval(180), confirmedReset: true)
        try expect(full.consumed == 95 && full.startingTotal == 100 && full.periodConsumed == 0)
        // Confirmed journal IDs override delayed server rows, including after reload.
        let delayed = try plan(0, previous: before, at: now.addingTimeInterval(120), confirmedReset: true,
                               excludedCreditIDs: ["one"])
        try expect(delayed.startingTotal == 100 && delayed.availableCount == 0 && !delayed.includesReset)
        let restored = try JSONDecoder().decode(ResetPlanBudget.self, from: JSONEncoder().encode(delayed))
        let next = try plan(3, previous: restored, at: now.addingTimeInterval(180), excludedCreditIDs: ["one"])
        try expect(next.startingTotal == 100 && next.consumed == 10 && next.periodConsumed == 3 && !next.includesReset)
        // The count may update before detail rows; exclude confirmed use before
        // checking count consistency so the other verified credit survives.
        let laggingRows = try credits([row("one"), row("two", expiry: date(7))], count: 1)
        let other = try plan(0, previous: before, credits: laggingRows, at: now.addingTimeInterval(120),
                             confirmedReset: true, excludedCreditIDs: ["one"])
        try expect(other.creditIDs == ["two"] && other.startingTotal == 200 && other.actualRemaining == 100)
        for value in [noOp, disappeared, unknown, redeemed, duplicate, continued, exhausted, full, delayed, next, other] { try equations(value) }
    }

    func testInvalidWindowPreservesLedgerAndDurationChanges() throws {
        let first = try plan(5, credits: noCredits)
        let spent = try plan(12, previous: first, credits: noCredits, at: now.addingTimeInterval(60))
        for invalid in [UsageWindow(usedPercent: nil, windowDurationMins: 10080, resetsAt: date(8).timeIntervalSince1970),
                        UsageWindow(usedPercent: 12, windowDurationMins: nil, resetsAt: date(8).timeIntervalSince1970),
                        UsageWindow(usedPercent: 12, windowDurationMins: 10080, resetsAt: now.timeIntervalSince1970)] {
            try expect(ResetPlanBudget.reconcile(previous: spent, window: invalid, credits: noCredits,
                                                 now: now.addingTimeInterval(120), calendar: calendar) == nil)
        }
        let shorter = try require(ResetPlanBudget.reconcile(previous: spent,
            window: window(20, reset: now.addingTimeInterval(5 * 3600), duration: 300), credits: noCredits,
            now: now.addingTimeInterval(120), calendar: calendar))
        try expect(shorter.consumed == 7 && shorter.highWaterUsed == 20 && shorter.periodConsumed == 0)
        try expect(shorter.startingTotal == 80 && shorter.allowance == 80 && shorter.recalculationReason == .balanceAdjusted)
        try equations(shorter)
        var history = ProviderHistory()
        func snapshot(_ used: Double, at time: Date) -> UsageSnapshot {
            UsageSnapshot(response: UsageResponse(rateLimits: UsageBucket(limitId: "codex", limitName: "Codex", primary: window(used)),
                                                   rateLimitResetCredits: noCredits), accountKey: "a", fetchedAt: time)
        }
        history.ingest(snapshot(50, at: now), calendar: calendar)
        history.ingest(snapshot(60, at: now.addingTimeInterval(60)), calendar: calendar)
        history.ingest(snapshot(3, at: now.addingTimeInterval(120)), confirmedReset: true, calendar: calendar)
        let renewed = try require(history.resetPlanBudgets?["a/codex/primary"])
        try expect(renewed.consumed == 13 && renewed.highWaterUsed == 3 && renewed.recalculationReason == .quotaReset)
    }

    func testResetReceiptWaitsForEachMissingWindow() throws {
        let hourlyReset = now.addingTimeInterval(5 * 3600)
        func snapshot(_ hourlyUsed: Double, weeklyUsed: Double?, at time: Date) -> UsageSnapshot {
            UsageSnapshot(response: UsageResponse(rateLimits: UsageBucket(limitId: "codex", limitName: "Codex",
                primary: window(hourlyUsed, reset: hourlyReset, duration: 300),
                secondary: weeklyUsed.map { window($0) }), rateLimitResetCredits: noCredits),
                accountKey: "a", fetchedAt: time)
        }
        var history = ProviderHistory()
        history.ingest(snapshot(20, weeklyUsed: 40, at: now), calendar: calendar)
        history.ingest(snapshot(30, weeklyUsed: 50, at: now.addingTimeInterval(60)), calendar: calendar)
        let receipt = now.addingTimeInterval(90)
        let hourlyKey = "a/codex/primary"
        let weeklyKey = "a/codex/secondary"
        history.ingest(snapshot(3, weeklyUsed: nil, at: now.addingTimeInterval(120)),
                       confirmedResetAt: receipt, calendar: calendar)
        let firstHourly = try require(history.resetPlanBudgets?[hourlyKey])
        let missingWeekly = try require(history.resetPlanBudgets?[weeklyKey])
        try expect(firstHourly.consumed == 13 && firstHourly.highWaterUsed == 3 && firstHourly.periodConsumed == 0)
        try expect(missingWeekly.consumed == 10 && missingWeekly.highWaterUsed == 50)
        try expect(missingWeekly.observedAt == now.addingTimeInterval(60))
        try expect(!missingWeekly.isCurrent(now: now.addingTimeInterval(120),
                                            snapshotAt: now.addingTimeInterval(120), stale: false, calendar: calendar))
        // The hourly window has applied this receipt; the returning weekly
        // window still needs it even though the provider snapshot was newer.
        history.ingest(snapshot(5, weeklyUsed: 7, at: now.addingTimeInterval(180)),
                       confirmedResetAt: receipt, calendar: calendar)
        let nextHourly = try require(history.resetPlanBudgets?[hourlyKey])
        let returnedWeekly = try require(history.resetPlanBudgets?[weeklyKey])
        try expect(nextHourly.consumed == 15 && nextHourly.periodConsumed == 2)
        try expect(returnedWeekly.consumed == 17 && returnedWeekly.highWaterUsed == 7 && returnedWeekly.periodConsumed == 0)
        try expect(returnedWeekly.recalculationReason == .quotaReset)
        let lastSnapshot = snapshot(8, weeklyUsed: 10, at: now.addingTimeInterval(240))
        history.ingest(lastSnapshot, confirmedResetAt: receipt, calendar: calendar)
        let lastHourly = try require(history.resetPlanBudgets?[hourlyKey])
        let lastWeekly = try require(history.resetPlanBudgets?[weeklyKey])
        try expect(lastHourly.consumed == 18 && lastHourly.periodConsumed == 5)
        try expect(lastWeekly.consumed == 20 && lastWeekly.periodConsumed == 3)
        history.ingest(lastSnapshot, confirmedResetAt: receipt, calendar: calendar)
        try expect(history.resetPlanBudgets?[hourlyKey] == lastHourly)
        try expect(history.resetPlanBudgets?[weeklyKey] == lastWeekly)
        for value in [firstHourly, missingWeekly, nextHourly, returnedWeekly, lastHourly, lastWeekly] {
            try equations(value)
        }
    }
}
