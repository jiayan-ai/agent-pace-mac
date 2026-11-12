import Foundation

/// Redeemable offers on Claude's Settings → Usage page, separate from the
/// scheduled reset times in the quota API. A missing count is not zero.
public struct ClaudeLimitResets: Codable, Equatable {
    public enum Kind: String, Codable { case fable, weekly, session, full, unspecified }
    public struct Offer: Codable, Equatable {
        public let kind: Kind
        public let availableCount: Int?
        /// The page's expiry label, preserving its calendar date, precision and zone.
        public let expiryText: String?
    }
    public let availableCount: Int?
    public let offers: [Offer]

    /// The bridge supplies only the visible Limit resets section and the state
    /// of its redemption button. Text from an instructional button alone does
    /// not prove an offer is available.
    public static func parse(sectionText: String, hasEnabledResetButton: Bool = false) -> Self? {
        guard sectionText.utf8.count <= 8192 else { return nil }
        let lines = sectionText.split(whereSeparator: \.isNewline).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard let heading = lines.first, headings.contains(heading.lowercased()), lines.count <= 80 else { return nil }

        var total: Int?
        var rows: [Offer] = []
        var kind: Kind?
        var count: Int?
        var expiry: String?
        func finishRow() {
            if let kind { rows.append(Offer(kind: kind, availableCount: count, expiryText: expiry)) }
            kind = nil
            count = nil
            expiry = nil
        }

        for original in lines.dropFirst() {
            let line = original.precomposedStringWithCompatibilityMapping.lowercased()
            if otherSectionHeadings.contains(line) { break }
            if let type = titleKind(line) {
                // The accessible group name and the visible card title can
                // describe the same row. Never infer an extra use from either.
                if type == kind && count == nil && expiry == nil { continue }
                finishRow()
                kind = type
            } else if let amount = explicitCount(line) {
                if kind == nil {
                    guard total == nil || total == amount else { return nil }
                    total = amount
                } else {
                    guard count == nil || count == amount else { return nil }
                    count = amount
                }
            } else if let dateLabel = expiryLabel(in: original) {
                if kind == nil { kind = .unspecified }
                guard expiry == nil || expiry == dateLabel else { return nil }
                expiry = dateLabel
            }
        }
        finishRow()
        let counted = rows.compactMap(\.availableCount)
        let sum = counted.reduce(0, +)
        if let total, sum > total { return nil }
        if counted.count == rows.count, !counted.isEmpty {
            guard total == nil || total == sum else { return nil }
            total = sum
        }
        if total == 0 {
            guard !hasEnabledResetButton, counted.allSatisfy({ $0 == 0 }) else { return nil }
            return Self(availableCount: 0, offers: [])
        }
        // Page headings and marketing descriptions can name an offer without
        // actually granting one. Require a count or an enabled redemption action.
        guard total != nil || counted.contains(where: { $0 > 0 }) || hasEnabledResetButton else { return nil }
        return Self(availableCount: total, offers: rows.filter { $0.availableCount != 0 })
    }

    private static let headings: Set<String> = ["limit resets", "limit reset", "限额重置", "额度重置", "限制重置", "用量限制重置", "用量重置"]
    private static let otherSectionHeadings: Set<String> = [
        "usage credits", "extra usage", "weekly limits", "plan usage limits", "current session",
        "用量积分", "使用积分", "额外用量", "每周限额", "当前会话"
    ]
    private static let titleGroups: [(Kind, Set<String>)] = [
        (.full, ["full reset", "full resets", "full limit reset", "完全重置", "全部重置", "全额重置", "完整重置"]),
        (.fable, ["fable reset", "fable resets", "fable limit reset", "fable limit resets", "fable 重置", "fable 限额重置", "fable 额度重置"]),
        (.weekly, ["weekly reset", "weekly resets", "weekly limit reset", "weekly limit resets", "每周重置", "周额度重置", "每周限额重置"]),
        (.session, ["five-hour reset", "five-hour limit reset", "5-hour reset", "5-hour limit reset", "session reset", "5 小时重置", "5 小时限额重置", "会话重置"])
    ]
    private static func titleKind(_ line: String) -> Kind? { titleGroups.first(where: { $0.1.contains(line) })?.0 }

    private static let numericCount = try! NSRegularExpression(pattern:
        #"^(?:(?:you have |you have a total of )?([0-9]{1,3}) (?:free )?(?:(?:limit )?resets?(?: (?:available|left|remaining))?|available|remaining|left)|(?:available|remaining)(?: (?:limit )?resets?)?\s*:\s*([0-9]{1,3})|(?:剩余|可用)\s*([0-9]{1,3})\s*(?:次|张)(?:(?:限额|额度|限制)?重置)?|([0-9]{1,3})\s*(?:次|张)(?:(?:限额|额度|限制)?重置)?(?:可用|剩余))[.!。]?$"#)
    private static let noResets: Set<String> = [
        "no resets available", "no limit resets available", "no resets remaining", "no resets left",
        "you have no resets available", "you have no limit resets available", "暂无可用重置", "没有可用的限额重置"
    ]
    private static func explicitCount(_ line: String) -> Int? {
        if noResets.contains(line.trimmingCharacters(in: CharacterSet(charactersIn: ".。"))) { return 0 }
        let source = line as NSString
        guard let match = numericCount.firstMatch(in: line, range: NSRange(location: 0, length: source.length)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { group -> Int? in
            let range = match.range(at: group)
            return range.location == NSNotFound ? nil : Int(source.substring(with: range))
        }.first
    }
    private static let expiryPattern = try! NSRegularExpression(pattern:
        #"^(?:expires?(?: on| at| in)?\s*[:：]?\s+|(?:expiry(?: date)?|expiration(?: date)?|valid until)\s*[:：]?\s+|(?:到期(?:时间|日期)?|有效期至|截止(?:日期|时间)?)\s*[:：]?\s*).+$"#,
        options: [.caseInsensitive])
    private static func expiryLabel(in line: String) -> String? {
        // Adjacent description text may be flattened into one line by the
        // browser. Keep the date label independently of the offer's terms.
        guard expiryPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil else { return nil }
        let end = [" Refills ", " Restores ", " Reset for free", " 补充", " 恢复"].compactMap {
            line.range(of: $0, options: .caseInsensitive)?.lowerBound
        }.min() ?? line.endIndex
        let label = String(line[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return label.count <= 120 && label.rangeOfCharacter(from: .decimalDigits) != nil ? label : nil
    }
}
