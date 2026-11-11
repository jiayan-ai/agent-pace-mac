import Foundation

/// Values observed on the signed-in Computer Usage page. Credit pools and the
/// separately metered Pro weekly allowance have different units and lifetimes.
public struct PerplexityCredits: Codable, Equatable {
    public let plan: Double?
    public let bonus: Double?
    public let purchased: Double?
    public let total: Double?
    public let daysUntilRefresh: Int?
    public let weeklyRemainingPercent: Double?
    public let weeklyResetAt: Date?
    public let fetchedAt: Date

    public var dailyPlanCredits: Double? {
        guard let plan, let daysUntilRefresh, daysUntilRefresh > 0 else { return nil }
        if let total, total <= 0, plan > 0 { return nil }
        return max(0, plan) / Double(daysUntilRefresh)
    }

    public func dailyPlanCredits(asOf now: Date, calendar: Calendar = .current) -> Double? {
        // A displayed number of days cannot be extrapolated into a reset timestamp.
        guard now >= fetchedAt, calendar.isDate(now, inSameDayAs: fetchedAt) else { return nil }
        return dailyPlanCredits
    }

    public static func parse(visibleText: String, fetchedAt: Date = Date(),
                             calendar: Calendar = .current) -> PerplexityCredits? {
        guard visibleText.utf8.count <= 64 * 1024, fetchedAt.timeIntervalSince1970.isFinite else { return nil }
        let lines = visibleText.split(whereSeparator: \.isNewline).map {
            String($0).precomposedStringWithCompatibilityMapping.lowercased()
                .replacingOccurrences(of: "−", with: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard lines.count <= 500 else { return nil }

        var creditLines: [String] = []
        var weeklyLines: [String] = []
        enum Section { case outside, credits, includedPro }
        var section = Section.outside
        for line in lines {
            // Everything beneath a usage table can be user-created task text.
            // Stop before its column headings or task titles can open a new card.
            if Page.historyStart.firstMatch(line) != nil { break }
            if Page.proHeaders.contains(line) {
                section = .includedPro
            } else if Page.creditHeaders.contains(line) || Page.balanceHeaders.contains(line) {
                section = .credits
            } else if Page.sectionEnd.firstMatch(line) != nil || line.count > 512 {
                section = .outside
            }
            switch section {
            case .credits: creditLines.append(line)
            case .includedPro: weeklyLines.append(line)
            case .outside: break
            }
            if section == .outside || Page.proHeaders.contains(line) {
                // Never associate a label in one card with a bare number in another.
                if creditLines.last != "" { creditLines.append("") }
            }
            if section != .includedPro, weeklyLines.last != "" { weeklyLines.append("") }
        }

        var balances: [String: Reading<Double>] = [:]
        var refreshDays = Reading<Int>()
        var inBalanceBreakdown = false
        for (i, line) in creditLines.enumerated() {
            if line.isEmpty || Page.creditHeaders.contains(line) { inBalanceBreakdown = false }
            if Page.balanceHeaders.contains(line) { inBalanceBreakdown = true }
            let next = i + 1 < creditLines.count ? creditLines[i + 1] : ""
            if let match = Page.refreshDays.firstMatch(line) {
                refreshDays.record(match.dropFirst().compactMap(Int.init).first)
                continue
            }
            if Page.refreshLabels.contains(line), let match = Page.dayCount.firstMatch(next) {
                refreshDays.record(Int(match[1]))
                continue
            }
            if let match = Page.balanceRow.firstMatch(line), let key = Page.balanceKey[match[1]] {
                let inline = match[2]
                let text = inline.isEmpty ? next : inline
                // Outside a balance breakdown, unqualified category numbers
                // may be grants. Only read explicitly remaining amounts.
                let explicit = Page.remainingAmount.firstMatch(text) != nil
                guard key == "total" || inBalanceBreakdown || explicit else { continue }
                let amount: Double?
                if match[1] == "total available credits", let pair = Page.availableOfTotal.firstMatch(text) {
                    amount = Page.amount(pair[1])
                } else {
                    amount = Page.amount(text)
                }
                // A standalone balance heading sometimes introduces a card of
                // component rows, with no separate numeric total.
                if key != "total" || !inline.isEmpty || amount != nil {
                    balances[key, default: Reading()].record(amount)
                }
            } else if let match = Page.explicitTotal.firstMatch(line) {
                balances["total", default: Reading()].record(Page.amount(match[1].isEmpty ? match[2] : match[1]))
            }
        }
        var plan = balances["plan"]?.value
        var bonus = balances["bonus"]?.value
        var purchased = balances["purchased"]?.value
        var total = balances["total"]?.value
        if let planValue = plan, let bonusValue = bonus, let purchasedValue = purchased {
            let sum = planValue + bonusValue + purchasedValue
            if let explicit = total, abs(explicit - sum) > max(0.000_001, sum.ulp * 4) {
                // The total explicitly marked available remains meaningful
                // even if category values are actually allocations.
                plan = nil
                bonus = nil
                purchased = nil
            } else if balances["total"] == nil, abs(sum) <= Page.largestExactInteger {
                total = sum
            }
        }

        var weekly = Reading<Double>()
        var reset = Reading<Date>()
        var inLimit = false
        for (i, line) in weeklyLines.enumerated() {
            if line.isEmpty || Page.proHeaders.contains(line) { inLimit = false; continue }
            var text = line
            if let match = Page.weeklyLabel.firstMatch(line) { inLimit = true; text = match[1] }
            guard inLimit else { continue }
            let next = i + 1 < weeklyLines.count ? weeklyLines[i + 1] : ""
            if let bare = Page.weeklyAmount.firstMatch(text), bare[1].isEmpty, bare[3].isEmpty {
                if Page.directionOnly.contains(next) {
                    text += " " + next
                } else if i > 0, Page.directionOnly.contains(weeklyLines[i - 1]) {
                    text = weeklyLines[i - 1] + " " + text
                }
            }
            if let match = Page.weeklyAmount.firstMatch(text) {
                let value = Double(match[2])
                let direction = match[1].isEmpty ? match[3] : match[1]
                if let value, value <= 100, match[1].isEmpty || match[3].isEmpty {
                    weekly.record(Page.usedLabels.contains(direction) ? 100 - value : value)
                } else {
                    weekly.record(nil)
                }
            }
            if let match = Page.weeklyReset.firstMatch(text) {
                let source = match.dropFirst().first { !$0.isEmpty } ?? next
                reset.record(Page.nextReset(source, after: fetchedAt, calendar: calendar))
            }
        }
        let percent = weekly.value
        guard plan != nil || bonus != nil || purchased != nil || total != nil || percent != nil else { return nil }
        return PerplexityCredits(plan: plan, bonus: bonus, purchased: purchased, total: total,
                                 daysUntilRefresh: refreshDays.value, weeklyRemainingPercent: percent,
                                 weeklyResetAt: percent != nil ? reset.value : nil, fetchedAt: fetchedAt)
    }
}

/// Multiple visible values must agree, and a placeholder never represents zero.
private struct Reading<Value: Equatable> {
    private var first: Value?
    private var conflicting = false
    mutating func record(_ candidate: Value?) {
        guard let candidate, first == nil || first == candidate else { conflicting = true; return }
        first = candidate
    }
    var value: Value? { conflicting ? nil : first }
}

private enum Page {
    static let largestExactInteger = 9_007_199_254_740_991.0
    static let proHeaders: Set<String> = ["included in pro", "pro 套餐已包含", "pro 套餐包含", "pro 已包含", "pro 包含的用量", "pro 中包含"]
    static let creditHeaders: Set<String> = ["credits", "computer credits", "your credits", "积分", "点数", "额度"]
    static let balanceHeaders: Set<String> = ["credit balance", "credit balances", "available credits", "remaining credits", "current balances", "积分余额", "余额明细", "可用积分", "剩余积分"]
    static let historyStart = Pattern(#"^(?:usage (?:by|breakdown|history)|credit history|transaction history|recent (?:tasks|activity|usage)|thread history|用量明细|用量记录|交易记录|最近活动|任务记录|使用明细|使用记录)"#)
    static let sectionEnd = Pattern(#"^(?:usage (?:by|breakdown|history|details|activity)|recent (?:usage|activity|tasks)|usage$|add more|(?:turn on )?auto[- ]?refill|auto[- ]?recharge|more details|spending limit|purchase credits|buy credits|payment|transaction|credit history|tasks$|activity$|thread history|history$|使用明细|使用记录|用量明细|用量记录|最近|(?:开启)?自动充值|支出限额|消费上限|交易|购买积分|付款|任务记录|添加更多|更多详情)"#)

    static let balanceKey: [String: String] = {
        var result: [String: String] = [:]
        for (key, labels) in [
            ("plan", ["plan", "plan credits", "monthly plan credits", "monthly credits", "套餐", "计划", "套餐积分", "计划积分", "月度积分", "每月积分"]),
            ("bonus", ["bonus", "bonus credits", "奖励", "奖励积分", "赠送积分"]),
            ("purchased", ["purchased", "purchased credits", "已购买", "已购", "已购积分", "已购买积分"]),
            ("total", ["credit balance", "credits balance", "available credits", "credits available", "remaining credits", "credits remaining", "total available credits", "total credits", "total balance", "current balance", "balance", "total", "积分余额", "剩余积分", "可用积分", "总余额", "总积分", "余额", "合计"])
        ] {
            for label in labels { result[label] = key }
        }
        return result
    }()
    static let balanceRow = Pattern("^(\(balanceKey.keys.sorted { $0.count > $1.count }.joined(separator: "|")))(?:(?:\\s*:\\s*|\\s+|(?=[+0-9-]))(.*))?$")
    static let numeric = #"[+-]?(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?"#
    static let amountPattern = Pattern("^(\(numeric))\\s*(?:credits?|积分|点数)?(?:\\s*(?:left|remaining|available|可用|剩余))?$")
    static let remainingAmount = Pattern("^(\(numeric))\\s*(?:credits?|积分|点数)?\\s*(?:left|remaining|available|可用|剩余)$")
    static let availableOfTotal = Pattern("^(\(numeric))\\s*/\\s*\(numeric)$")
    static let explicitTotal = Pattern("^(\(numeric))\\s*credits?\\s+(?:left|remaining|available)$|^(?:还剩|剩余|可用)\\s*(\(numeric))\\s*(?:积分|点数)$")
    static let refreshLabels: Set<String> = ["days until next monthly refresh", "days until your next monthly refresh", "下次月度刷新", "距离下次月度刷新"]
    static let refreshDays = Pattern(#"^(?:(?:plan credits? |monthly credits? )?(?:refresh(?:es)?|renew(?:s)?|reset(?:s)?) in |(?:next (?:monthly )?(?:refresh|reset|renewal)|(?:days until (?:your |the )?next monthly refresh))[: ]+)([0-9]{1,3})(?: days?)?\.?$|^距(?:离)?(?:下次|下一次)(?:月度|每月|套餐|计划)?(?:刷新|重置|续期)(?:还剩|还有)?\s*:?\s*([0-9]{1,3})\s*天$|^([0-9]{1,3})\s*天后(?:刷新|重置|续期)$"#)
    static let dayCount = Pattern(#"^([0-9]{1,3})\s*(?:days?|天)?$"#)

    static let weeklyLabel = Pattern(#"^(?:weekly limit|每周限额|每周上限|每周额度|每周限制|周限额|周额度)(?:(?:\s*:\s*|\s+)(.*))?$"#)
    static let weeklyAmount = Pattern(#"^(?:(left|remaining|available|used|剩余|可用|已用|已使用)\s*:?\s*)?([0-9]+(?:\.[0-9]+)?)\s*%\s*(left|remaining|available|used|剩余|可用|已用|已使用)?$"#)
    static let directionOnly: Set<String> = ["left", "remaining", "available", "used", "剩余", "可用", "已用", "已使用"]
    static let usedLabels: Set<String> = ["used", "已用", "已使用"]
    static let weeklyReset = Pattern(#"^(?:reset(?:s)?(?: (?:on|at))?|next reset|下次重置(?:时间)?|重置(?:于|时间)?)[ :]*(.*)$|^(?:将于|于)?((?:星期|周|礼拜).+?)\s*重置[。.]?$"#)
    static let weekdayTime = Pattern(#"^(monday|mon|tuesday|tues?|wednesday|wed|thursday|thu(?:rs?)?|friday|fri|saturday|sat|sunday|sun|(?:星期|周|礼拜)[一二三四五六天日])\.?[, ]*(?:at\s*)?(上午|下午)?\s*([0-9]{1,2})(?::([0-9]{2}))?\s*(am|pm)?$"#)
    static let weekdayGroups = [
        ["sunday", "sun", "日", "天"], ["monday", "mon", "一"], ["tuesday", "tue", "tues", "二"],
        ["wednesday", "wed", "三"], ["thursday", "thu", "thur", "thurs", "四"],
        ["friday", "fri", "五"], ["saturday", "sat", "六"]
    ]

    static func amount(_ text: String) -> Double? {
        guard let match = amountPattern.firstMatch(text),
              let value = Double(match[1].replacingOccurrences(of: ",", with: "")),
              abs(value) <= largestExactInteger else { return nil }
        return value
    }

    static func nextReset(_ text: String, after now: Date, calendar: Calendar) -> Date? {
        guard let end = calendar.date(byAdding: .day, value: 7, to: now) else { return nil }
        let text = text.trimmingCharacters(in: CharacterSet(charactersIn: ".。"))
        if let exact = ISO8601DateFormatter().date(from: text.uppercased()) {
            return exact > now && exact <= end ? exact : nil
        }
        guard let parts = weekdayTime.firstMatch(text), var hour = Int(parts[3]) else { return nil }
        let weekday = parts[1]
        guard let weekdayIndex = weekdayGroups.firstIndex(where: {
            $0.contains(weekday) || $0.contains(String(weekday.suffix(1)))
        }) else { return nil }
        let meridiem = parts[2].isEmpty ? parts[5] : parts[2]
        let minutes = Int(parts[4]) ?? 0
        if !meridiem.isEmpty {
            guard parts[2].isEmpty || parts[5].isEmpty, (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (meridiem == "pm" || meridiem == "下午" ? 12 : 0)
        } else if parts[4].isEmpty { return nil }
        guard hour < 24, minutes < 60 else { return nil }
        let components = DateComponents(hour: hour, minute: minutes, second: 0, weekday: weekdayIndex + 1)
        guard let date = calendar.nextDate(after: now, matching: components, matchingPolicy: .strict,
                                           repeatedTimePolicy: .first), date <= end else { return nil }
        // A local clock label alone cannot select between both instants during
        // the fall DST transition.
        let last = calendar.nextDate(after: now, matching: components, matchingPolicy: .strict,
                                     repeatedTimePolicy: .last)
        return last == date ? date : nil
    }
}

/// Captures unmatched optional groups as empty strings.
private struct Pattern {
    private let expression: NSRegularExpression
    init(_ pattern: String) { expression = try! NSRegularExpression(pattern: pattern) }
    func firstMatch(_ text: String) -> [String]? {
        let source = text as NSString
        guard let match = expression.firstMatch(in: text, range: NSRange(location: 0, length: source.length)) else { return nil }
        return (0..<match.numberOfRanges).map {
            let range = match.range(at: $0)
            return range.location == NSNotFound ? "" : source.substring(with: range)
        }
    }
}
