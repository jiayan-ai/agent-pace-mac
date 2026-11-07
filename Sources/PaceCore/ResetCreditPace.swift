import Foundation

/// A planning horizon, not an automatic redemption or a promised reset.
public struct ResetCreditPace {
    public static let planningHorizon: TimeInterval = 72 * 3600
    public let remaining: Double
    public let expiryDate: Date
    public let secondsRemaining: TimeInterval
    public let creditID: String

    public static func evaluate(window: UsageWindow, credits: ResetCredits?, stale: Bool,
                                now: Date) -> ResetCreditPace? {
        guard !stale, now.timeIntervalSince1970.isFinite,
              let remaining = window.remaining,
              let duration = window.windowDurationMins, duration > 0,
              let naturalReset = window.resetsAt, naturalReset.isFinite,
              naturalReset > now.timeIntervalSince1970,
              let credits, credits.availableCount > 0 else { return nil }

        // Local expiry removes a credit from planning even if the service has
        // not yet removed its row. Only verified, still-valid details can count.
        guard let credit = ResetPlanBudget.verifiedCredits(credits, at: now).first,
              let expiry = credit.expiryDate, expiry.timeIntervalSince1970 < naturalReset,
              expiry.timeIntervalSince(now) <= planningHorizon else { return nil }
        return ResetCreditPace(remaining: remaining, expiryDate: expiry,
                               secondsRemaining: expiry.timeIntervalSince(now), creditID: credit.id)
    }

    /// Only replace the daily view with a synchronization prompt when an
    /// approaching (or recently expired) credit could affect the current plan.
    public static func needsConfirmation(window: UsageWindow, credits: ResetCredits?, stale: Bool,
                                         snapshotInFuture: Bool, now: Date) -> Bool {
        guard now.timeIntervalSince1970.isFinite, window.remaining != nil,
              let duration = window.windowDurationMins, duration > 0,
              let naturalReset = window.resetsAt, naturalReset.isFinite,
              naturalReset > now.timeIntervalSince1970,
              let credits, credits.availableCount > 0 else { return false }

        let approaching = ResetPlanBudget.verifiedCredits(credits, at: now).contains {
            $0.expiryDate.map { $0.timeIntervalSince(now) <= planningHorizon && $0.timeIntervalSince1970 < naturalReset } == true
        }
        return (stale || snapshotInFuture) &&
            (approaching || expiredDetailsNeedRefresh(credits: credits, now: now, before: naturalReset))
    }

    /// A very old expired entry alone should not cause 60-second polling forever.
    /// Continue polling for recent expirations or when another imminent credit
    /// makes that old entry relevant to the next planning horizon.
    public static func expiredDetailsNeedRefresh(credits: ResetCredits?, now: Date,
                                                 before naturalReset: TimeInterval? = nil) -> Bool {
        guard now.timeIntervalSince1970.isFinite, let credits, credits.availableCount > 0 else { return false }
        func relevant(_ date: Date) -> Bool {
            naturalReset.map { date.timeIntervalSince1970 < $0 } ?? true
        }
        let expired = (credits.credits ?? []).compactMap { credit -> Date? in
            guard credit.status == "available", credit.resetType == "codexRateLimits",
                  let expiry = credit.expiryDate, expiry <= now, relevant(expiry) else { return nil }
            return expiry
        }
        guard !expired.isEmpty else { return false }
        if expired.contains(where: { now.timeIntervalSince($0) <= planningHorizon }) { return true }
        return credits.usableDetails(at: now).contains {
            $0.expiryDate.map { relevant($0) && $0.timeIntervalSince(now) <= planningHorizon } == true
        }
    }

    public var isFinalHour: Bool { secondsRemaining < 3600 }
    /// In the final partial hour show the actual remaining quota, not an extrapolated rate.
    public var allowance: Double { remaining / max(1, secondsRemaining / 3600) }
    public var countdown: String {
        if secondsRemaining < 60 { return L("不足 1 分钟") }
        let minutes = ceil(secondsRemaining / 60)
        let hours = floor(minutes / 60)
        let rest = minutes.truncatingRemainder(dividingBy: 60)
        return hours > 0 ? String(format: L("%.0f 小时 %.0f 分钟"), hours, rest)
            : String(format: L("%.0f 分钟"), minutes)
    }
}
