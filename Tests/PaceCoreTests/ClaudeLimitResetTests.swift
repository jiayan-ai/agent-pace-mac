import Foundation
@testable import PaceCore

struct ClaudeLimitResetTests {
    func testFullAndFableOffers() throws {
        let inventory = try require(ClaudeLimitResets.parse(sectionText: """
        Limit resets
        3 available
        Full reset
        Full reset
        About full resets
        Expires Apr 20, 2:00 PM PDT
        Reset for free
        Fable reset
        Expires May 12, 2028, 9:15 AM PDT Refills your 5-hour limit and your Fable allowance.
        Reset for free
        Usage credits
        10 available
        """, hasEnabledResetButton: true))
        try expect(inventory.availableCount == 3 && inventory.offers.map(\.kind) == [.full, .fable])
        try expect(inventory.offers.map(\.expiryText) == ["Expires Apr 20, 2:00 PM PDT", "Expires May 12, 2028, 9:15 AM PDT"])
        try expect(inventory.offers.allSatisfy { $0.availableCount == nil })
        try expect(try JSONDecoder().decode(ClaudeLimitResets.self, from: JSONEncoder().encode(inventory)) == inventory)
    }

    func testUnknownZeroAndConflictingResets() throws {
        try expect(ClaudeLimitResets.parse(sectionText: "Weekly limits\nResets in 3 days") == nil)
        try expect(ClaudeLimitResets.parse(sectionText: "Limit resets\nReset for free") == nil)
        try expect(ClaudeLimitResets.parse(sectionText: "Limit resets\n0 available")?.availableCount == 0)
        try expect(ClaudeLimitResets.parse(sectionText: "Limit resets\n0 available", hasEnabledResetButton: true) == nil)
        try expect(ClaudeLimitResets.parse(sectionText: "Limit resets\n1 available\n3 available") == nil)
        try expect(ClaudeLimitResets.parse(sectionText: "Limit resets\n2 available\nWeekly reset\n3 available") == nil)
        let one = try require(ClaudeLimitResets.parse(sectionText: "Limit resets\nFable reset\nReset for free",
                                                      hasEnabledResetButton: true))
        try expect(one.availableCount == nil && one.offers.map(\.kind) == [.fable])
        try expect(one.offers.first?.availableCount == nil && one.offers.first?.expiryText == nil)
    }

    func testScopedLocalizedResetCounts() throws {
        let snapshot = try require(ClaudeLimitResets.parse(sectionText: """
        限额重置
        5 小时重置
        可用 2 次
        到期时间：2028 年 3 月 15 日 17:59
        每周限额重置
        剩余 1 次
        """))
        try expect(snapshot.availableCount == 3 && snapshot.offers.map(\.kind) == [.session, .weekly])
        try expect(snapshot.offers.map(\.availableCount) == [2, 1])
        try expect(snapshot.offers.first?.expiryText == "到期时间：2028 年 3 月 15 日 17:59")
        try expect(snapshot.offers.last?.expiryText == nil)
        try expect(ClaudeLimitResets.parse(sectionText: "Limit resets\nUp to 3 available\nPlan-dependent") == nil)
    }

    func testLatestObservationAndAccountChanges() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func snapshot(_ account: String, minutes: Int, count: Int?) -> UsageSnapshot {
            let window = UsageWindow(usedPercent: 20, windowDurationMins: 10080,
                                     resetsAt: start.addingTimeInterval(86400 * 6).timeIntervalSince1970)
            var response = UsageResponse(rateLimits: UsageBucket(limitId: "claude", limitName: "Claude", primary: window))
            response.claudeLimitResets = count.flatMap {
                ClaudeLimitResets.parse(sectionText: "Limit resets\n\($0) available" + ($0 > 0 ? "\nFull reset" : ""))
            }
            return UsageSnapshot(response: response, accountKey: account,
                                 fetchedAt: start.addingTimeInterval(Double(minutes) * 60))
        }
        var history = ProviderHistory()
        history.ingest(snapshot("A", minutes: 0, count: 2))
        let first = try require(history.claudeResetObservation)
        history.ingest(snapshot("A", minutes: 5, count: nil))
        history.ingest(snapshot("A", minutes: 10, count: nil))
        try expect(history.snapshot?.response.claudeLimitResets == nil && history.claudeResetObservation == first)
        try expect(first.accountKey == "A" && first.observedAt == start && first.inventory.availableCount == 2)
        var restored = try JSONDecoder().decode(ProviderHistory.self, from: JSONEncoder().encode(history))
        try expect(restored.claudeResetObservation == first)
        restored.ingest(snapshot("A", minutes: 15, count: 0))
        let zero = try require(restored.claudeResetObservation)
        try expect(zero.inventory.availableCount == 0 && zero.inventory.offers.isEmpty && zero.observedAt != start)
        restored.ingest(snapshot("A", minutes: 20, count: nil))
        try expect(restored.claudeResetObservation == zero)
        restored.ingest(snapshot("B", minutes: 25, count: nil))
        try expect(restored.claudeResetObservation == nil)
        restored.ingest(snapshot("A", minutes: 30, count: nil))
        try expect(restored.claudeResetObservation == nil)
        // Disconnect removes both direct and fallback observations but preserves
        // quota windows, the selected window and frozen daily baseline.
        for value in [1, 2] {
            history.ingest(snapshot("A", minutes: 35, count: value))
            if value == 2 { history.ingest(snapshot("A", minutes: 40, count: nil)) }
            let before = history.snapshot?.response.windows
            let budgets = history.budgets
            let selected = history.selectedID
            history.clearClaudeResetObservation()
            try expect(history.claudeResetObservation == nil && history.snapshot?.response.claudeLimitResets == nil)
            try expect(history.snapshot?.response.windows == before && history.budgets == budgets && history.selectedID == selected)
        }
    }
}
