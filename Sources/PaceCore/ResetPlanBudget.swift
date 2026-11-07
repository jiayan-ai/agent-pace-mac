import Foundation

/// One observed daily ledger, with a new planning segment whenever its capacity
/// or deadline changes. A credit's potential capacity is never account balance.
public struct ResetPlanBudget: Codable, Equatable {
    public enum Basis: String, Codable { case natural, resetCredit }
    public enum RecalculationReason: String, Codable {
        case initial, dayChanged, creditExpired, creditsChanged, quotaReset, balanceAdjusted, migrated
    }
    public static let currentSchemaVersion = 2
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
    public let planningDays: Double
    public let allowance: Double
    public private(set) var consumed: Double
    public private(set) var lastUsed: Double
    public private(set) var lastResetAt: Double
    public private(set) var observedAt: Date
    public private(set) var actualRemaining: Double
    public private(set) var availableCreditIDs: [String]
    // Optional so version 1 histories remain decodable. They must be reconciled
    // with a fresh account snapshot before being presented as a current plan.
    public let basis: Basis?
    public let schemaVersion: Int?
    public let consumedBeforeBaseline: Double?
    public let dayObservedAt: Date?
    public let recalculationReason: RecalculationReason?
    public private(set) var highWaterUsed: Double?

    public var expiryDate: Date { Date(timeIntervalSince1970: expiryAt) }
    public var targetDate: Date { expiryDate }
    public var recalculateAt: Date { startedAt }
    public var effectiveBasis: Basis { basis ?? (creditIDs.isEmpty ? .natural : .resetCredit) }
    public var includesReset: Bool { effectiveBasis == .resetCredit }
    public var periodConsumed: Double { max(0, consumed - (consumedBeforeBaseline ?? 0)) }
    public var availableCount: Int { availableCreditIDs.count }
    public var liveCapacity: Double { actualRemaining + 100 * Double(availableCount) }
    public var leftToday: Double { allowance - periodConsumed }
    public var overBudget: Double { max(0, periodConsumed - allowance) }
    public var progress: Double { allowance > 0 ? min(1, periodConsumed / allowance) : 1 }

    /// Unknown or conflicting rows cannot add capacity. A partial list can only
    /// contribute its verified subset, never the server's unexplained count.
    public static func verifiedCredits(_ credits: ResetCredits?, at now: Date,
                                       excluding excludedCreditIDs: Set<String> = []) -> [ResetCredit] {
        guard now.timeIntervalSince1970.isFinite, let credits, credits.availableCount > 0,
              let details = credits.credits else { return [] }
        let grouped = Dictionary(grouping: details.filter { !excludedCreditIDs.contains($0.id) }, by: \.id)
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

    /// Ordinary observations deduct usage once. Lifecycle changes start a new
    /// budget segment while retaining the day's observed consumption. Neither
    /// an expired/absent credit nor a balance correction proves redemption.
    public static func reconcile(previous: ResetPlanBudget?, window: UsageWindow,
                                 credits: ResetCredits?, now: Date,
                                 confirmedReset: Bool = false,
                                 excludedCreditIDs: Set<String> = [],
                                 calendar: Calendar = .current,
                                 priorDailyBudget: DailyBudget? = nil) -> ResetPlanBudget? {
        guard now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 >= 0,
              now.timeIntervalSince1970 <= latestSupportedTimestamp, let remaining = window.remaining,
              let reset = window.resetsAt, reset.isFinite, reset <= latestSupportedTimestamp,
              reset > now.timeIntervalSince1970,
              let duration = window.windowDurationMins, duration > 0 else { return nil }
        let used = 100 - remaining
        let day = calendar.startOfDay(for: now)
        if let previous, now < previous.observedAt { return previous }
        let verified = verifiedCredits(credits, at: now, excluding: excludedCreditIDs).filter { $0.expiresAt! <= reset }
        let earliest = verified.first
        let target = earliest?.expiresAt ?? reset
        let newBasis: Basis = earliest == nil ? .natural : .resetCredit
        let cohort = verified.filter { $0.expiresAt == earliest?.expiresAt }.map(\.id)
        let tolerance = min(60, Double(duration) * 0.6)
        var consumed = 0.0
        var highWater = used
        var dayObserved = now
        var reason: RecalculationReason = previous == nil ? .initial : .dayChanged

        if var old = previous, old.dayStart == day, old.timeZoneID == calendar.timeZone.identifier {
            dayObserved = old.dayObservedAt ?? old.startedAt
            consumed = old.consumed
            let sameDuration = old.windowDurationMins == duration
            let resetChanged = abs(reset - old.lastResetAt) >= tolerance
            let confirmedNewCycle = (confirmedReset && now > old.observedAt) ||
                (sameDuration && reset - old.lastResetAt >= tolerance &&
                 (old.lastResetAt <= now.timeIntervalSince1970 || used + 0.001 < old.lastUsed))
            let priorHighWater = old.highWaterUsed ?? old.lastUsed
            let additionalUse = confirmedNewCycle ? used : (sameDuration ? max(0, used - priorHighWater) : 0)
            consumed += additionalUse
            highWater = confirmedNewCycle || !sameDuration ? used : max(priorHighWater, used)
            let creditsChanged = old.effectiveBasis != newBasis || old.creditIDs != cohort ||
                (newBasis == .resetCredit && old.expiryAt != target)
            // A correction and its subsequent rebound are not fresh usage. A
            // fresh segment keeps the recommendation within observed capacity.
            let balanceAdjusted = abs(remaining - (old.actualRemaining - additionalUse)) > 0.001
            if old.schemaVersion != currentSchemaVersion {
                reason = .migrated
            } else if confirmedNewCycle {
                reason = .quotaReset
            } else if old.includesReset && old.expiryAt <= now.timeIntervalSince1970 {
                reason = .creditExpired
            } else if creditsChanged {
                reason = .creditsChanged
            } else if !sameDuration || resetChanged || balanceAdjusted {
                reason = .balanceAdjusted
            } else {
                old.consumed = consumed
                old.highWaterUsed = highWater
                old.lastUsed = used
                old.observedAt = now
                old.actualRemaining = remaining
                // Keep the cycle identity through insignificant clock jitter.
                return old
            }
        } else if previous == nil, let prior = priorDailyBudget,
                  prior.dayStart == day, prior.timeZoneID == calendar.timeZone.identifier,
                  prior.windowDurationMins == duration, prior.startedAt <= now {
            dayObserved = prior.startedAt
            consumed = prior.consumed
            let newCycle = confirmedReset || (reset - prior.resetAt >= tolerance &&
                (prior.resetAt <= now.timeIntervalSince1970 || used + 0.001 < prior.lastUsed))
            consumed += newCycle ? used : max(0, used - prior.lastUsed)
            highWater = newCycle ? used : max(prior.lastUsed, used)
            reason = .migrated
        }

        let days: Double
        if newBasis == .resetCredit {
            let expiryDay = calendar.startOfDay(for: Date(timeIntervalSince1970: target))
            guard let difference = calendar.dateComponents([.day], from: day, to: expiryDay).day,
                  difference >= 0 else { return nil }
            days = Double(difference + 1)
        } else {
            days = max(1, (reset - now.timeIntervalSince1970) / 86400)
        }
        let total = remaining + 100 * Double(cohort.count)
        return ResetPlanBudget(dayStart: day, timeZoneID: calendar.timeZone.identifier,
                               startedAt: now, expiryAt: target,
                               naturalResetAt: reset, windowDurationMins: duration,
                               creditIDs: cohort, startingRemaining: remaining,
                               startingTotal: total, planningDays: days,
                               allowance: total / days, consumed: consumed,
                               lastUsed: used, lastResetAt: reset, observedAt: now,
                               actualRemaining: remaining, availableCreditIDs: cohort,
                               basis: newBasis, schemaVersion: currentSchemaVersion,
                               consumedBeforeBaseline: consumed, dayObservedAt: dayObserved,
                               recalculationReason: reason, highWaterUsed: highWater)
    }

    /// A persisted ledger remains useful for the next sync, but is never shown
    /// as a current plan while its account snapshot is stale or in the future.
    public func isCurrent(now: Date, snapshotAt: Date, stale: Bool,
                          calendar: Calendar = .current) -> Bool {
        schemaVersion == Self.currentSchemaVersion && !stale &&
            now.timeIntervalSince1970.isFinite && now.timeIntervalSince1970 >= 0 &&
            now.timeIntervalSince1970 <= Self.latestSupportedTimestamp && snapshotAt <= now &&
            observedAt == snapshotAt && calendar.startOfDay(for: now) == dayStart &&
            calendar.timeZone.identifier == timeZoneID && lastResetAt > now.timeIntervalSince1970 &&
            naturalResetAt > now.timeIntervalSince1970 && expiryAt > now.timeIntervalSince1970
    }
}
