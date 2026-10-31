import Foundation

public struct ResetCredit: Codable, Identifiable {
    public let id: String
    public let resetType: String
    public let status: String
    public let grantedAt: Double?
    public let expiresAt: Double?
    public let title: String?
    public let description: String?

    public var expiryDate: Date? {
        guard let expiresAt, expiresAt.isFinite else { return nil }
        return Date(timeIntervalSince1970: expiresAt)
    }
}

public struct ResetCredits: Codable {
    public let availableCount: Int
    public let credits: [ResetCredit]?

    public init(availableCount: Int, credits: [ResetCredit]? = nil) {
        self.availableCount = availableCount
        self.credits = credits
    }

    public func usableDetails(at now: Date) -> [ResetCredit] {
        (credits ?? []).filter {
            $0.status == "available" && $0.resetType == "codexRateLimits" &&
            ($0.expiresAt == nil || ($0.expiryDate.map { $0 > now } ?? false))
        }.sorted { ($0.expiryDate ?? .distantFuture) < ($1.expiryDate ?? .distantFuture) }
    }
}

public struct DailyActivity: Codable, Equatable, Identifiable {
    public let startDate: String
    public let tokens: Double
    public var id: String { startDate }
    public init(startDate: String, tokens: Double) { self.startDate = startDate; self.tokens = tokens }
}

public struct AccountActivity: Codable {
    public let dailyUsageBuckets: [DailyActivity]?
    public let summary: AccountTokenSummary?
    public init(dailyUsageBuckets: [DailyActivity]?, summary: AccountTokenSummary? = nil) {
        self.dailyUsageBuckets = dailyUsageBuckets
        self.summary = summary
    }

    // API date labels are retained verbatim. UTC provides a stable date axis,
    // independent of the viewer's time zone. Missing days remain unknown.
    public static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    public static func date(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return date
    }
    public static func dayLabel(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    public func recent(now: Date) -> AccountActivity {
        guard let dailyUsageBuckets else { return self }
        let today = Self.calendar.startOfDay(for: now)
        let start = Self.calendar.date(byAdding: .day, value: -30, to: today)!
        var days: [String: DailyActivity] = [:]
        for item in dailyUsageBuckets {
            guard item.tokens.isFinite, item.tokens >= 0, let date = Self.date(item.startDate),
                  date >= start, date < today else { continue }
            // Repeated buckets represent the same day, never add them together.
            if item.tokens >= (days[item.startDate]?.tokens ?? -1) { days[item.startDate] = item }
        }
        return AccountActivity(dailyUsageBuckets: days.values.sorted { $0.startDate < $1.startDate }, summary: summary)
    }
}

public struct UsagePattern {
    public let days: [DailyActivity]
    public let recentRatio: Double?
    public let busyWeekday: Int?
    public let nextBusyDate: Date?
    public let highDemandSoon: Bool
    public var observedDays: Int { days.count }
    public var sufficient: Bool { observedDays >= 14 }
    public var activeDays: Int { days.filter { $0.tokens > 0 }.count }

    public init(activity: AccountActivity?, now: Date) {
        days = activity?.recent(now: now).dailyUsageBuckets ?? []
        let calendar = AccountActivity.calendar
        let today = calendar.startOfDay(for: now)
        let recentStart = calendar.date(byAdding: .day, value: -7, to: today)!
        let recent = days.filter { AccountActivity.date($0.startDate)! >= recentStart }
        let earlier = days.filter { AccountActivity.date($0.startDate)! < recentStart }
        let earlierMean = earlier.isEmpty ? 0 : earlier.reduce(0) { $0 + $1.tokens } / Double(earlier.count)
        recentRatio = recent.count >= 4 && earlier.count >= 7 && earlierMean > 0
            ? (recent.reduce(0) { $0 + $1.tokens } / Double(recent.count)) / earlierMean : nil
        let mean = days.isEmpty ? 0 : days.reduce(0) { $0 + $1.tokens } / Double(days.count)
        let grouped = Dictionary(grouping: days) { calendar.component(.weekday, from: AccountActivity.date($0.startDate)!) }
        let ranked = grouped.compactMap { weekday, samples -> (Int, Double)? in
            guard samples.count >= 3 else { return nil }
            // Shrink sparse weekday averages toward the overall average.
            let score = (samples.reduce(0) { $0 + $1.tokens } + mean * 2) / Double(samples.count + 2)
            return score > mean * 1.2 ? (weekday, score) : nil
        }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        busyWeekday = days.count >= 14 ? ranked.first?.0 : nil
        if let busyWeekday {
            let offset = (busyWeekday - calendar.component(.weekday, from: today) + 7) % 7
            nextBusyDate = calendar.date(byAdding: .day, value: offset, to: today)
            highDemandSoon = offset <= 1 || (recentRatio ?? 0) >= 1.35
        } else {
            nextBusyDate = nil
            highDemandSoon = days.count >= 14 && (recentRatio ?? 0) >= 1.35
        }
    }
    public static func weekdayName(_ value: Int) -> String {
        [L("周日"), L("周一"), L("周二"), L("周三"), L("周四"), L("周五"), L("周六")][max(0, min(6, value - 1))]
    }
}

public struct ResetAdvice {
    public enum Kind: String { case refresh, unavailable, noCredits, wait, consider, reserve, learning }
    public let kind: Kind
    public let title: String
    public let reason: String
    public let preferredCreditID: String?

    public static func evaluate(response: UsageResponse?, pattern: UsagePattern, historyFresh: Bool,
                                stale: Bool, now: Date) -> ResetAdvice {
        func advice(_ kind: Kind, _ title: String, _ reason: String, credit: String? = nil) -> ResetAdvice {
            ResetAdvice(kind: kind, title: title, reason: reason, preferredCreditID: credit)
        }
        guard !stale, let response else {
            return advice(.refresh, L("先同步最新额度"), L("上次记录不能用于决定是否消耗 reset。"))
        }
        guard let credits = response.rateLimitResetCredits, credits.availableCount >= 0 else {
            return advice(.unavailable, L("Reset 数量暂不可用"), L("当前接口未返回可用数量，不代表账户没有 reset。"))
        }
        guard credits.availableCount > 0 else {
            return advice(.noCredits, L("目前没有可用 Reset"), L("等待自然重置，或在 Codex 中查看账户额度。"))
        }
        if (credits.credits ?? []).contains(where: { $0.status == "available" && $0.expiryDate.map { $0 <= now } == true }) {
            return advice(.refresh, L("Reset 有效期已变化"), L("有记录中的 reset 已到期，请刷新确认可用数量。"))
        }
        let windows = response.windows.filter { $0.bucketID == "codex" }
        let valid = windows.filter { $0.window.remaining != nil && $0.window.resetDate.map { $0 > now } == true }
        guard !valid.isEmpty, valid.count == windows.count else {
            return advice(.refresh, L("等待有效的重置时间"), L("额度窗口已到期或信息不完整，先刷新后再判断。"))
        }
        let firstCredit = credits.usableDetails(at: now).first
        // Assess each window separately. A nearly empty short window matters
        // only if its own natural reset is not close.
        let pressured = valid.filter { ($0.window.remaining ?? 100) <= 10 }
        let lastingPressure = pressured.filter { $0.window.resetDate!.timeIntervalSince(now) > 6 * 3600 }
        if !pressured.isEmpty && lastingPressure.isEmpty {
            return advice(.wait, L("优先等自然重置"), L("接近耗尽的窗口将在 6 小时内恢复；若工作可以等，先保留 reset。"))
        }
        if let empty = lastingPressure.first(where: { $0.window.remaining == 0 }) {
            return advice(.consider, L("继续工作时可考虑 Reset"), L("\(empty.label) 已耗尽，自然重置仍超过 6 小时。若现在要继续工作，优先用最早到期的 reset。"), credit: firstCredit?.id)
        }
        guard historyFresh, pattern.sufficient else {
            return advice(.learning, L("先保留，历史仍需补足"), L("近 30 天有 \(pattern.observedDays) 个有效日记录；至少需要 14 天且历史同步正常，才给出模式建议。额度耗尽时仍会单独提示。"))
        }
        if !lastingPressure.isEmpty && pattern.highDemandSoon {
            return advice(.consider, L("下一段集中工作前考虑 Reset"), L("有窗口剩余不超过 10%，且近月模式显示近期可能较忙；等真正需要继续工作时再使用，优先选最早到期的一次。"), credit: firstCredit?.id)
        }
        if let credit = firstCredit, let expiry = credit.expiryDate,
           expiry.timeIntervalSince(now) <= 3 * 86400 {
            return advice(.reserve, L("优先安排快到期的 Reset"), L("有 reset 将在 3 天内到期。若到期前额度接近耗尽且仍有工作，优先用这一张；无需为用券刻意消耗额度。"), credit: credit.id)
        }
        if pattern.highDemandSoon {
            return advice(.reserve, L("留给接下来的高用量时段"), L("近月模式显示近期可能较忙，但当前没有需要立即重置的窗口。等实际额度接近耗尽，再评估 reset。"), credit: firstCredit?.id)
        }
        return advice(.wait, L("暂时保留 Reset"), L("当前额度和近月模式没有显示立即重置的必要。额度减少、券临近到期或模式变化时会重新建议。"))
    }
}
