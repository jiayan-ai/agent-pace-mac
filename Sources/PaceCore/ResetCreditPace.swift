import Foundation

/// A planning horizon, not an automatic redemption or a promised reset.
public struct ResetCreditPace {
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

        // An expired entry still reported as available makes the count uncertain.
        // Wait for a fresh account response instead of assuming another credit exists.
        guard !(credits.credits ?? []).contains(where: {
            $0.status == "available" && $0.resetType == "codexRateLimits" &&
            $0.expiryDate.map { $0 <= now } == true
        }) else { return nil }
        guard let credit = credits.usableDetails(at: now).first(where: { $0.expiryDate != nil }),
              let expiry = credit.expiryDate, expiry.timeIntervalSince1970 < naturalReset else { return nil }
        return ResetCreditPace(remaining: remaining, expiryDate: expiry,
                               secondsRemaining: expiry.timeIntervalSince(now), creditID: credit.id)
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
