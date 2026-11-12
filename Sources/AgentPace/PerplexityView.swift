import SwiftUI
import AppKit
import PaceCore

func creditNumber(_ value: Double) -> String {
    value.formatted(.number.locale(Localization.locale).precision(.fractionLength(0...2)))
}

struct PerplexityView: View {
    @ObservedObject var store: PaceStore
    @State private var showImport = false
    @State private var importFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let balance = store.perplexityCredits {
                if let weekly = balance.weeklyRemainingPercent {
                    weeklyCard(balance, remaining: weekly)
                }
                if balance.total != nil || balance.bonus != nil || balance.plan != nil || balance.purchased != nil {
                    creditsCard(balance, primary: balance.weeklyRemainingPercent == nil)
                }
                Text(store.perplexityImported ? L("手动导入于 \(resetTime(balance.fetchedAt))") :
                     L("同步于 \(resetTime(balance.fetchedAt))"))
                    .font(.caption).foregroundStyle(.secondary)
                if store.stale {
                    Text(L("显示上次记录，尚未确认最新额度")).font(.caption).foregroundStyle(.orange)
                }
            } else {
                Text(L("连接 Perplexity 以查看 Computer 用量")).font(.headline)
                Text(L("在 Perplexity 用量页登录后点「同步额度」。"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.orange) }
            if let error = store.persistenceError { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                if !store.perplexityEnabled || store.perplexityNeedsLogin || store.error != nil {
                    Button(L("连接 Perplexity"), action: store.connectPerplexity)
                        .buttonStyle(.borderedProminent).disabled(store.disconnectingPerplexity || store.isRefreshing)
                }
                if store.perplexityEnabled || store.perplexityConnecting {
                    Button(L("断开连接"), action: store.disconnectPerplexity).disabled(store.disconnectingPerplexity)
                } else if store.perplexityImported {
                    Button(L("清除导入记录"), action: store.clearPerplexityRecord)
                }
            }
            if !PerplexityWebSession.persistsLogin {
                Text(L("在 macOS 13 上，重新启动应用后需要再次登录 Perplexity。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !store.perplexityEnabled {
                DisclosureGroup(L("从浏览器导入用量"), isExpanded: $showImport) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("在浏览器打开官方用量页，复制「Usage and credits」中的周额度和积分摘要，再点下方按钮。下次更新时重复此操作。"))
                            .fixedSize(horizontal: false, vertical: true)
                        Link(L("打开官方用量页"), destination: PerplexityWebSession.usageURL)
                        Button(L("粘贴用量摘要")) {
                            let text = NSPasteboard.general.string(forType: .string) ?? ""
                            importFailed = !store.importPerplexity(text)
                            if !importFailed { showImport = false }
                        }.disabled(store.isRefreshing || store.disconnectingPerplexity)
                        if importFailed {
                            Text(L("未识别到额度，请连同「Included in Pro」或「Credits」标题一起复制。"))
                                .foregroundStyle(.orange)
                        }
                    }.padding(.top, 6)
                }.font(.caption)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func weeklyCard(_ balance: PerplexityCredits, remaining: Double) -> some View {
        let expired = balance.weeklyResetAt.map { $0 <= store.now } ?? false
        return VStack(alignment: .leading, spacing: 8) {
            Text(L("Pro 每周额度剩余")).font(.callout.weight(.medium)).foregroundStyle(.secondary)
            if expired {
                Text(L("周额度等待刷新")).font(.title2.weight(.semibold))
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(creditNumber(remaining))
                        .font(.system(size: 62, weight: .medium, design: .rounded)).monospacedDigit()
                    Text("%").font(.system(size: 28, weight: .regular, design: .rounded))
                }.foregroundStyle(.teal).accessibilityElement(children: .combine)
            }
            if let reset = balance.weeklyResetAt {
                Label(L("周额度重置于 \(resetTime(reset))"), systemImage: "arrow.clockwise")
                    .font(.callout)
            }
            if !expired && remaining == 0 && (balance.total ?? 0) > 0 {
                Text(L("本周包含的用量已用完，继续使用 Computer 会消耗积分。"))
                    .font(.caption).foregroundStyle(.secondary)
            } else if let pace = store.perplexityWeeklyPace, remaining > 0 {
                Text(L("按剩余时间均摊：每天约 \(creditNumber(pace)) 个百分点。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .background(Color.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 19))
    }

    private func creditsCard(_ balance: PerplexityCredits, primary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Computer 积分")).font(.callout.weight(.medium)).foregroundStyle(.secondary)
            if let total = balance.total {
                Text(L("\(creditNumber(total)) 积分"))
                    .font(.system(size: primary ? 48 : 27, weight: primary ? .medium : .semibold, design: .rounded))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.55)
                    .foregroundStyle(total < 0 ? Color.red : (primary ? Color.teal : Color.primary))
            }
            if let bonus = balance.bonus { creditRow(L("奖励积分"), bonus) }
            if let plan = balance.plan { creditRow(L("方案积分"), plan) }
            if let purchased = balance.purchased { creditRow(L("已购积分"), purchased) }
            if let days = balance.daysUntilRefresh {
                Text(L("记录时距月度刷新 \(days) 天")).font(.caption).foregroundStyle(.secondary)
            }
            if let pace = store.perplexityPlanPace {
                Text(L("方案积分日均建议 \(creditNumber(pace)) 积分"))
                    .font(.callout.weight(.medium)).foregroundStyle(.teal)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(primary ? 20 : 16)
            .background(primary ? Color.teal.opacity(0.08) : Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: primary ? 19 : 14))
    }

    private func creditRow(_ label: String, _ value: Double) -> some View {
        HStack { Text(label); Spacer(); Text(creditNumber(value)).monospacedDigit() }.font(.caption)
    }
}
