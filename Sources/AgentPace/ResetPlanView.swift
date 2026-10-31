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
                    Text(plan.overBudget > 0 ? L("今日预算已超额") : L("今日计划剩余"))
                        .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    Text(L("含 Reset 计划"))
                        .font(.caption.weight(.medium)).foregroundStyle(accent)
                }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(number(plan.leftToday))
                        .font(.system(size: 62, weight: .medium, design: .rounded)).monospacedDigit()
                    Text("%").font(.system(size: 28, weight: .regular, design: .rounded))
                }.foregroundStyle(color).accessibilityElement(children: .combine)
                Text(L("按单轮额度的百分点计算，包含待兑换额度。"))
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
                    Text(L("今日计划预算")).font(.callout.weight(.medium))
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
                    Text(L("已用 \(number(plan.consumed))%"))
                    Spacer()
                    Text(L("从 \(localTime(plan.startedAt)) 首次同步起"))
                }.font(.caption).foregroundStyle(.secondary)
                if plan.overBudget > 0 {
                    Text(L("今日已超出均摊预算 \(number(plan.overBudget)) 个百分点。"))
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
            Label(L("含 Reset 计划"), systemImage: "calendar.badge.clock")
                .font(.callout.weight(.medium))
            Text(L("当前计划总量 \(number(plan.liveCapacity))% = 实际 \(number(plan.actualRemaining))% + \(plan.availableCount) 张 × 100%。"))
                .font(.caption).monospacedDigit()
            Text(L("今日初始 \(number(plan.startingTotal))% ÷ \(plan.planningDays) 天 = \(number(plan.allowance))% / 天；含今天与 \(resetTime(plan.expiryDate)) 所在日。"))
                .font(.caption).foregroundStyle(.secondary)
            Text(L("当前实际额度用完后，需先使用 Reset 才能继续。自动使用仍只在到期前最后 5 分钟尝试。"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }
}
