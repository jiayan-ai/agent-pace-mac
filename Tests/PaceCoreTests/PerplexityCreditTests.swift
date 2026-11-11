import Foundation
import PaceCore

struct PerplexityCreditTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }
    private var now: Date { date(2, day: 11, hour: 10, minute: 0) }
    private func date(_ month: Int, day: Int, hour: Int, minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }
    private func read(_ text: String) -> PerplexityCredits? {
        PerplexityCredits.parse(visibleText: text, fetchedAt: now, calendar: calendar)
    }

    func testAccountUsagePage() throws {
        // Visible account page; the upgrade offer and auto-refill are controls.
        let snapshot = try require(read("""
        Usage and credits
        Learn more about how credits work. Upgrade to Max for more usage.
        Included in Pro
        Weekly limit
        0.0% left
        Resets Tue at 8:15 AM.
        Credits
        325 credits left
        Add more
        Turn on auto-refill
        More details
        Get 45,000 credits with your first upgrade to Max.
        """))
        try expect(snapshot.weeklyRemainingPercent == 0 && snapshot.total == 325)
        try expect(snapshot.weeklyResetAt == date(2, day: 17, hour: 8, minute: 15))
        try expect(snapshot.plan == nil && snapshot.bonus == nil && snapshot.purchased == nil)
        try expect(snapshot.dailyPlanCredits == nil && snapshot.daysUntilRefresh == nil)
        try expect(try JSONDecoder().decode(PerplexityCredits.self, from: JSONEncoder().encode(snapshot)) == snapshot)
        // A missing weekly figure is distinct from zero in the credit-only layout.
        let balance = try require(read("Credits\n−19 credits left\nAdd more"))
        try expect(balance.total == -19 && balance.weeklyRemainingPercent == nil)
    }

    func testExplicitBalancesAndMonthlyHorizon() throws {
        let snapshot = try require(read("""
        Credit balances
        Plan
        1,500
        Purchased credits: 40
        Bonus credits 0
        Plan credits refresh in 15 days
        Usage by thread
        Plan 10000
        Bonus credits: 481
        """))
        try expect(snapshot.plan == 1500 && snapshot.bonus == 0 && snapshot.purchased == 40 && snapshot.total == 1540)
        try expect(snapshot.daysUntilRefresh == 15 && snapshot.dailyPlanCredits == 100)
        try expect(snapshot.dailyPlanCredits(asOf: now.addingTimeInterval(60), calendar: calendar) == 100)
        try expect(snapshot.dailyPlanCredits(asOf: now.addingTimeInterval(-1), calendar: calendar) == nil)
        try expect(snapshot.dailyPlanCredits(asOf: now.addingTimeInterval(86400), calendar: calendar) == nil)
        let missing = try require(read("Credit balances\nPlan 120\nPurchased credits —\nRefreshes in 0 days"))
        try expect(missing.total == nil && missing.purchased == nil && missing.dailyPlanCredits == nil)
        try expect(read("积分余额\n套餐积分 300\n5 天")?.daysUntilRefresh == nil)
        let exhausted = try require(read("Credit balances\nPlan 100\nTotal 0\nRefreshes in 2 days"))
        try expect(exhausted.total == 0 && exhausted.dailyPlanCredits == nil)
    }

    func testLocalizedAndWeeklyOnly() throws {
        let snapshot = try require(read("""
        Pro 套餐已包含
        每周限额
        剩余 75％
        下次重置：周六 下午 1:30。
        积分余额
        套餐积分：1,000
        奖励积分 250
        已购积分 100
        距下次月度刷新还有 20 天
        """))
        try expect(snapshot.weeklyRemainingPercent == 75 && snapshot.weeklyResetAt == date(2, day: 14, hour: 13, minute: 30))
        try expect(snapshot.total == 1350 && snapshot.dailyPlanCredits == 50)
        let weekly = try require(read("Included in Pro\nWeekly limit\n30%\nused\nResets Fri at 12 AM."))
        try expect(weekly.weeklyRemainingPercent == 70 && weekly.weeklyResetAt == date(2, day: 13, hour: 0, minute: 0))
        try expect(weekly.total == nil && weekly.daysUntilRefresh == nil)
        let iso = try require(read("Included in Pro\nWeekly limit: 50% remaining\nResets 2026-02-13T08:00:00Z"))
        try expect(iso.weeklyResetAt == weekly.weeklyResetAt)
        try expect(read("Included in Pro\nWeekly limit\nUsed\n25%")?.weeklyRemainingPercent == 75)
    }

    func testProviderHistoryRoundTrip() throws {
        let window = UsageWindow(usedPercent: 30, windowDurationMins: 10_080,
                                 resetsAt: now.addingTimeInterval(4 * 86_400).timeIntervalSince1970)
        let codex = UsageSnapshot(response: UsageResponse(rateLimits: UsageBucket(limitId: "codex", limitName: "Codex",
                                                                                 primary: window)),
                                  accountKey: "fixture", fetchedAt: now)
        var history = PaceHistory()
        history[.codex].ingest(codex, calendar: calendar)
        let oldBudgets = history[.codex].budgets
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        let legacy = try decoder.decode(PaceHistory.self, from: encoder.encode(history[.codex]))
        try expect(legacy.selectedProvider == .codex && legacy[.codex].budgets == oldBudgets)
        try expect(legacy.perplexityCredits == nil && legacy.perplexityImported == nil)
        history.perplexityCredits = try require(read("Credits\n72 credits left"))
        history.perplexityImported = true
        history.selectedProvider = .perplexity
        let restored = try decoder.decode(PaceHistory.self, from: encoder.encode(history))
        try expect(restored.selectedProvider == .perplexity && restored.perplexityImported == true)
        try expect(restored.perplexityCredits == history.perplexityCredits && restored[.codex].budgets == oldBudgets)
        try expect(restored[.claude].snapshot == nil)
    }

    func testUnsupportedOrAmbiguousPage() throws {
        try expect(read("Weekly limit\n100% left\nPlan 2000\n325 credits left") == nil)
        try expect(read("Credits\n4,00 credits left\nTurn on auto-refill\n$100\nUsage by session\n325 credits left") == nil)
        try expect(read("Credits\n50 credits left\n51 credits left") == nil)
        try expect(read("Included in Pro\nWeekly limit\n101% left") == nil)
        try expect(read("Included in Pro\nWeekly limit\n61% left\n60% left") == nil)
        try expect(read("Credit balances\nPlan 100\nPlan —") == nil)
        try expect(read("Plan 0\nUsage history\nBonus credits 9\nPurchased credits 0") == nil)
        try expect(read("Usage by thread\nCredits\n800 credits left") == nil)
        try expect(read("Credits\nPlan credits 1000\nBonus credits 1500") == nil)
        try expect(read("Included in Pro\nWeekly limit\n90% left\nResets soon")?.weeklyResetAt == nil)
        try expect(read("Included in Pro\nWeekly limit\n90% left\nResets Fri at 40:99 PM")?.weeklyResetAt == nil)
        try expect(read("Included in Pro\nWeekly limit\n90% left\nResets 2026-02-26T18:00:00Z")?.weeklyResetAt == nil)
        try expect(read("Credits\n0 credits left")?.total == 0)
        let realTotal = try require(read("Credits\nPlan credits 0\nBonus credits 10,000\nTotal available credits\n6,156 / 10,000"))
        try expect(realTotal.total == 6156 && realTotal.bonus == nil && realTotal.plan == nil)
        let conflicting = try require(read("Credit balances\nPlan 0\nBonus 10000\nPurchased 0\nTotal available credits 6,156"))
        try expect(conflicting.total == 6156 && conflicting.bonus == nil && conflicting.plan == nil)
    }
}
