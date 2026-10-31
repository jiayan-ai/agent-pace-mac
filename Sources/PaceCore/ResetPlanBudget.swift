import Foundation

/// A daily spending plan backed by explicitly verified reset credits. Its total
/// is potential capacity, never an account balance or a redemption instruction.
public struct ResetPlanBudget: Codable, Equatable {
    private static let latestSupportedTimestamp: Double = 253_402_300_799
    public let dayStart: Date
    public let timeZoneID: String
    public let startedAt: Date
    public let expiryAt: Double
    public let naturalResetAt: Double
    public let windowDurationMins: Int
    public let creditIDs: [String]
    public let startingRemaining: Double
    public let startingTotal: Double
    public let planningDays: Int
    public let allowance: Double
    public private(set) var consumed: Double
    public private(set) var lastUsed: Double
    public private(set) var lastResetAt: Double
    public private(set) var observedAt: Date
    public private(set) var actualRemaining: Double
    public private(set) var availableCreditIDs: [String]

    public var expiryDate: Date { Date(timeIntervalSince1970: expiryAt) }
    public var availableCount: Int { availableCreditIDs.count }
    public var liveCapacity: Double { actualRemaining + 100 * Double(availableCount) }
    public var leftToday: Double { min(allowance - consumed, liveCapacity) }
    public var overBudget: Double { max(0, consumed - allowance) }
    public var progress: Double { allowance > 0 ? min(1, consumed / allowance) : 1 }

    /// Unknown or conflicting rows cannot add capacity. A partial list can only
    /// contribute its verified subset, never the server's unexplained count.
    public static func verifiedCredits(_ credits: ResetCredits?, at now: Date) -> [ResetCredit] {
        guard now.timeIntervalSince1970.isFinite, let credits, credits.availableCount > 0,
              let details = credits.credits else { return [] }
        let grouped = Dictionary(grouping: details, by: \.id)
        let valid = grouped.values.compactMap { rows -> ResetCredit? in
            guard rows.count == 1, let credit = rows.first,
                  !credit.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  credit.status == "available", credit.resetType == "codexRateLimits",
                  let timestamp = credit.expiresAt, timestamp <= latestSupportedTimestamp,
                  let expiry = credit.expiryDate, expiry > now else { return nil }
            return credit
        }
        // A lower authoritative count conflicts with the supposedly usable rows.
        guard valid.count <= credits.availableCount else { return [] }
        return valid.sorted {
            $0.expiresAt == $1.expiresAt ? $0.id < $1.id : $0.expiresAt! < $1.expiresAt!
        }
    }

    /// Freeze the first plan each local day, then deduct observed usage. When a
    /// confirmed new cycle starts, its current usage is observable; usage in the
    /// unseen tail of the old cycle is not. Corrections never refund the ledger.
    public static func reconcile(previous: ResetPlanBudget?, window: UsageWindow,
                                 credits: ResetCredits?, now: Date,
                                 calendar: Calendar = .current) -> ResetPlanBudget? {
        guard now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 >= 0,
              now.timeIntervalSince1970 <= latestSupportedTimestamp, let remaining = window.remaining,
              let reset = window.resetsAt, reset.isFinite, reset <= latestSupportedTimestamp,
              reset > now.timeIntervalSince1970,
              let duration = window.windowDurationMins, duration > 0 else { return nil }
        let used = 100 - remaining
        let day = calendar.startOfDay(for: now)
        let verified = verifiedCredits(credits, at: now)
        if var old = previous, old.dayStart == day,
           old.timeZoneID == calendar.timeZone.identifier, old.windowDurationMins == duration {
            guard now >= old.observedAt else { return old }
            let resetAdvanced = reset - old.lastResetAt >= min(60, Double(duration) * 0.6)
            let confirmedNewCycle = resetAdvanced &&
                (old.lastResetAt <= now.timeIntervalSince1970 || used + 0.001 < old.lastUsed)
            old.consumed += confirmedNewCycle ? used : max(0, used - old.lastUsed)
            old.lastUsed = used
            old.lastResetAt = reset
            old.observedAt = now
            old.actualRemaining = remaining
            let stillAvailable = Set(old.availableCreditIDs)
            // Do not replenish today's frozen plan with newly granted or later
            // batches. A redeemed/expired credit disappears from live capacity.
            old.availableCreditIDs = verified.filter {
                stillAvailable.contains($0.id) && $0.expiresAt == old.expiryAt
            }.map(\.id)
            return old
        }
        guard let earliest = verified.first, let expiry = earliest.expiryDate else { return nil }
        // Use the credit deadline even when a natural reset is due sooner. Only
        // actual remaining quota is counted; future natural resets add nothing
        // until the server confirms a new balance. Different credit deadlines
        // remain separate so later credits cannot inflate this earliest plan.
        let cohort = verified.filter { $0.expiresAt == earliest.expiresAt }.map(\.id)
        let expiryDay = calendar.startOfDay(for: expiry)
        guard let difference = calendar.dateComponents([.day], from: day, to: expiryDay).day,
              difference >= 0 else { return nil }
        let days = difference + 1
        let total = remaining + 100 * Double(cohort.count)
        return ResetPlanBudget(dayStart: day, timeZoneID: calendar.timeZone.identifier,
                               startedAt: now, expiryAt: expiry.timeIntervalSince1970,
                               naturalResetAt: reset, windowDurationMins: duration,
                               creditIDs: cohort, startingRemaining: remaining,
                               startingTotal: total, planningDays: days,
                               allowance: total / Double(days), consumed: 0,
                               lastUsed: used, lastResetAt: reset, observedAt: now,
                               actualRemaining: remaining, availableCreditIDs: cohort)
    }

    /// A persisted ledger remains useful for the next sync, but is never shown
    /// as a current plan while its account snapshot is stale or in the future.
    public func isCurrent(now: Date, snapshotAt: Date, stale: Bool,
                          calendar: Calendar = .current) -> Bool {
        !stale && now.timeIntervalSince1970.isFinite && now.timeIntervalSince1970 >= 0 &&
            now.timeIntervalSince1970 <= Self.latestSupportedTimestamp && snapshotAt <= now &&
            observedAt == snapshotAt && calendar.startOfDay(for: now) == dayStart &&
            calendar.timeZone.identifier == timeZoneID && lastResetAt > now.timeIntervalSince1970
    }

    /// Re-evaluate expiration between polls without mutating the saved daily
    /// ledger. Only a fresh account response may establish a new day's plan.
    public func adjustedForExpiry(at now: Date) -> ResetPlanBudget {
        var value = self
        if expiryAt <= now.timeIntervalSince1970 { value.availableCreditIDs = [] }
        return value
    }
}
