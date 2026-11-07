import SwiftUI
import PaceCore

struct ResetPlanDailyView: View {
    let plan: ResetPlanBudget
    let accent: Color
    private var color: Color { plan.overBudget > 0 ? .red : accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(plan.overBudget > 0 ? L("本次预算已超额") : L("今日建议剩余"))
                        .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    Text(plan.includesReset ? L("含 Reset 计划") : L("按自然重置规划"))
                        .font(.caption.weight(.medium)).foregroundStyle(accent)
                }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(number(plan.leftToday))
                        .font(.system(size: 62, weight: .medium, design: .rounded)).monospacedDigit()
                    Text("%").font(.system(size: 28, weight: .regular, design: .rounded))
                }.foregroundStyle(color).accessibilityElement(children: .combine)
                Text(plan.includesReset ? L("包含待兑换的潜在额度；当前实际余额见下方。") : L("按当前实际额度规划，不包含尚未使用的 Reset。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 19)
                    .fill(LinearGradient(colors: [color.opacity(0.10), color.opacity(0.035)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L("本次预算")).font(.callout.weight(.medium))
                    Spacer()
                    Text("\(number(plan.allowance))%").font(.callout.weight(.semibold)).monospacedDigit()
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(accent.opacity(0.10))
                        Capsule().fill(color).frame(width: max(0, proxy.size.width * plan.progress))
                    }
                }.frame(height: 7)
                HStack {
                    Text(L("本次已用 \(number(plan.periodConsumed))%"))
                    Spacer()
                    Text(L("自 \(localTime(plan.startedAt)) 起"))
                }.font(.caption).foregroundStyle(.secondary)
                if plan.overBudget > 0 {
                    Text(L("本次已超出建议 \(number(plan.overBudget)) 个百分点。"))
                        .font(.caption).foregroundStyle(.red)
                }
            }
            .padding(16)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

struct ResetPlanSummaryView: View {
    let plan: ResetPlanBudget

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(L("当前规划"), systemImage: "calendar.badge.clock")
                .font(.callout.weight(.medium))
            Text(reason).font(.caption).foregroundStyle(.secondary)
            Text(L("今日累计已记录 \(number(plan.consumed))% · 自 \(localTime(plan.dayObservedAt ?? plan.startedAt)) 起"))
                .font(.caption).foregroundStyle(.secondary)
            if plan.includesReset {
                Text(L("规划基数：\(number(plan.startingRemaining))% + \(plan.creditIDs.count) 张 × 100% = \(number(plan.startingTotal))%。"))
                    .font(.caption).monospacedDigit()
            }
            Text(L("\(number(plan.startingTotal))% ÷ \(daysText) 天 = \(number(plan.allowance))% / 天"))
                .font(.caption).monospacedDigit()
            Text(plan.includesReset ? L("规划至 Reset 券到期：\(resetTime(plan.targetDate))，含今天与到期日。") : L("规划至自然重置：\(resetTime(plan.targetDate))。"))
                .font(.caption).foregroundStyle(.secondary)
            Text(plan.includesReset ? L("待兑换额度只有成功使用 Reset 后才可用；未用完的实际余额不会累加。") : L("晚于本轮自然重置到期的券暂不计入预算，仍保留在 Reset 助手中。"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }

    private var daysText: String {
        String(format: plan.includesReset ? "%.0f" : "%.2f", plan.planningDays)
    }

    private var reason: String {
        switch plan.recalculationReason {
        case .creditExpired: return L("原 Reset 已到期，已按最新余额重新计算。")
        case .creditsChanged: return L("Reset 券状态已变化，已重新计算。")
        case .quotaReset: return L("已同步重置后的额度，已重新计算。")
        case .balanceAdjusted: return L("额度数据已调整，已重新计算。")
        case .migrated: return L("已根据当前账户状态更新预算。")
        case .dayChanged: return L("新的一天，已重新分配预算。")
        case .initial, .none: return L("按本次首次同步的余额计算。")
        }
    }
}
