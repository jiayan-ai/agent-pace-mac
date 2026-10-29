import SwiftUI
import PaceCore

struct ResetInsightsView: View {
    @ObservedObject var store: PaceStore
    @State private var expanded = false
    private var credits: ResetCredits? { store.snapshot?.response.rateLimitResetCredits }
    private var pattern: UsagePattern { store.usagePattern }
    private var advice: ResetAdvice { store.resetAdvice }
    private var countLabel: String {
        guard let count = credits?.availableCount, count >= 0 else { return L("数量未知") }
        return L("\(store.stale ? L("上次 ") : "")\(count) 次可用")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(L("Reset 助手"), systemImage: "arrow.counterclockwise.circle")
                    .font(.callout.weight(.medium))
                Spacer()
                Text(countLabel)
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            Toggle(L("到期前 5 分钟自动使用 Reset"), isOn: Binding(get: { store.autoResetEnabled }, set: store.setAutoResetEnabled))
                .font(.caption)
            Text(L("需保持 Agent Pace 运行且电脑唤醒并联网。重置不会累加额度，可能重新开始周期；操作受账户资格限制，无法保证成功。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if store.autoResetUnconfirmed {
                Text(L("上次自动 Reset 的结果尚未确认。请先在 Codex 检查券和额度，再解除暂停；确认前不会使用其他券。"))
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                Button(L("已在 Codex 核实，解除暂停")) { store.clearUnconfirmedAutoReset() }.font(.caption)
            }
            if let message = store.autoResetMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(advice.title).font(.callout.weight(.semibold))
                .foregroundStyle(advice.kind == .consider ? Color.orange : Color.primary)
            Text(advice.reason).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup(L("近 30 天模式与 Reset 明细"), isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("近 30 天 · \(pattern.observedDays) 天有记录 · \(pattern.activeDays) 天活跃"))
                        .font(.caption.weight(.medium))
                    activityChart
                    if let weekday = pattern.busyWeekday {
                        Text(L("\(UsagePattern.weekdayName(weekday)) 通常用量较高；只比较有记录的日期。"))
                    } else {
                        Text(pattern.sufficient ? L("暂未发现稳定的星期偏好。") : L("记录不足，暂不判断星期偏好。"))
                    }
                    if let ratio = pattern.recentRatio {
                        Text(L("近 7 天的日均 Token 活跃度为此前的 \(String(format: "%.1f", ratio)) 倍。"))
                    }
                    Text(L("按接口日期统计，排除当天；灰色表示缺失记录，不按零用量计算。Token 活跃度不等同于额度百分比。"))
                        .foregroundStyle(.tertiary)
                    if let updated = store.activityUpdatedAt {
                        Text(L("历史同步：\(resetTime(updated))"))
                    } else {
                        Text(L("历史接口尚未返回可用数据，基础额度仍可同步。"))
                    }
                    Divider()
                    resetDetails
                    Text(L("根据历史模式与当前窗口给出规则建议。可选择到期前自动使用，也可以在 Codex 中手动使用。"))
                        .foregroundStyle(.tertiary)
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }.font(.caption)
        }
        .padding(16)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }

    private var activityChart: some View {
        let calendar = AccountActivity.calendar
        let today = calendar.startOfDay(for: store.now)
        let maximum = max(1, pattern.days.map(\.tokens).max() ?? 1)
        let values = Dictionary(uniqueKeysWithValues: pattern.days.map { ($0.startDate, $0.tokens) })
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<30) { index in
                let date = calendar.date(byAdding: .day, value: index - 30, to: today)!
                let key = AccountActivity.dayLabel(date)
                let tokens = values[key]
                RoundedRectangle(cornerRadius: 2)
                    .fill(tokens == nil ? Color.secondary.opacity(0.2) : Color.accentColor.opacity(0.8))
                    .frame(height: tokens.map { max(2, 40 * $0 / maximum) } ?? 4)
                    .help(L("\(key)：\(tokens.map { String(format: "%.0f Token", $0) } ?? L("未返回记录"))"))
                    .accessibilityLabel(L("\(key)：\(tokens.map { String(format: "%.0f Token", $0) } ?? L("未返回记录"))"))
            }
        }.frame(height: 40, alignment: .bottom)
    }

    @ViewBuilder private var resetDetails: some View {
        if let credits {
            if let details = credits.credits {
                let available = details.filter { $0.status == "available" }
                if available.isEmpty && credits.availableCount > 0 {
                    Text(L("服务端返回了数量，但没有可显示的券明细。"))
                }
                ForEach(available.sorted { ($0.expiryDate ?? .distantFuture) < ($1.expiryDate ?? .distantFuture) }) { credit in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(credit.title ?? "Codex Reset").fontWeight(.medium)
                        if let expiry = credit.expiryDate {
                            Text("\(expiry <= store.now ? L("已于") : L("有效期至")) \(resetTime(expiry))")
                        } else {
                            Text(L("服务端未提供到期时间"))
                        }
                        if credit.id == advice.preferredCreditID { Text(L("需要使用时优先考虑此券")).foregroundStyle(.orange) }
                    }
                }
                if credits.availableCount > available.count {
                    Text(L("仅展示 \(available.count) 条明细；可用总数以服务端为准。"))
                }
            } else {
                Text(L("服务端仅提供数量，未提供有效期明细。"))
            }
        } else {
            Text(L("当前版本或账户未提供 reset 券信息。"))
        }
    }
}
