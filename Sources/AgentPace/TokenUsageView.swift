import SwiftUI
import PaceCore

struct TokenUsageView: View {
    @ObservedObject var store: PaceStore
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L("Token 用量"), systemImage: "number.circle")
                    .font(.callout.weight(.medium))
                Spacer()
                Text(store.provider == .codex ? L("账户 · UTC") : L("本机 · 当地日期"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if store.provider == .codex { codex } else { claude }
            Text(L("Token 数与额度百分比是两种统计，不能直接换算。"))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }

    private var codex: some View {
        let tokens = store.codexTokens
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 15) {
                metric(L("今日 · UTC"), value: tokens.today)
                metric(L("近 30 天已记录"), value: tokens.last30Days)
            }
            HStack {
                Text(L("账户累计"))
                Spacer()
                Text(tokenNumber(tokens.lifetime)).monospacedDigit()
                    .help(exactTokens(tokens.lifetime))
            }.font(.caption)
            Text(L("服务端返回 \(tokens.recordedDays)/30 天记录；未返回的日期不按零计算。"))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let date = store.codexTokensUpdatedAt {
                Text(L("\(store.codexTokensStale ? L("上次记录") : L("已同步")) · \(resetTime(date))"))
                    .font(.caption2).foregroundStyle(store.codexTokensStale ? Color.orange : .secondary)
            } else {
                Text(L("接口尚未返回 Token 数据。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var claude: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 15) {
                localMetric(L("今日已记录"), value: store.claudeTokensDayChanged ? nil : store.claudeTokens?.today?.total)
                localMetric(L("近 30 天已记录"), value: store.claudeTokens?.last30Days?.total)
            }
            Text(L("来自本机 Claude Code（含桌面 Code）记录，可能包含多个登录账户；不代表当前账户或跨设备总量。"))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let snapshot = store.claudeTokens {
                if snapshot.last30Days != nil {
                    Text(L("\(snapshot.recordedDays) 天有记录 · \(snapshot.requests) 次去重请求"))
                        .font(.caption2).foregroundStyle(.secondary)
                    DisclosureGroup(L("近 30 天 Token 明细"), isExpanded: $expanded) {
                        if let counts = snapshot.last30Days {
                            VStack(spacing: 6) {
                                detail(L("输入（不含缓存）"), value: counts.inputTokens)
                                detail(L("输出"), value: counts.outputTokens)
                                detail(L("缓存写入"), value: counts.cacheCreationInputTokens)
                                detail(L("缓存读取"), value: counts.cacheReadInputTokens)
                            }.padding(.top, 6)
                        }
                    }.font(.caption)
                    Text(L("合计含输入、输出、缓存写入和读取；重复日志仅计一次。"))
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(snapshot.hasFiles ? L("最近 30 天没有可统计的 Token 记录。") : L("尚未发现本机 Claude Code 用量记录。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if snapshot.partial {
                    Text(L("部分记录未能读取或计数不完整，当前仅显示已确认的部分。"))
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Text(L("本机读取：\(resetTime(snapshot.fetchedAt))"))
                    .font(.caption2).foregroundStyle(.secondary)
                if store.claudeTokensStale {
                    Text(L("上次记录")).font(.caption2).foregroundStyle(.orange)
                }
            }
            if store.claudeTokensRefreshing {
                Text(L("正在读取本机 Token 记录…")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func metric(_ title: String, value: Double?, exact: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(tokenNumber(value)).font(.system(size: 23, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7).help(exact ?? exactTokens(value))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func localMetric(_ title: String, value: Int64?) -> some View {
        metric(title, value: value.map(Double.init), exact: value.map(exactTokenInteger) ?? "—")
    }

    private func detail(_ title: String, value: Int64) -> some View {
        HStack { Text(title); Spacer(); Text(exactTokenInteger(value)).monospacedDigit() }
    }
}

private func exactTokenInteger(_ value: Int64) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Localization.locale
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 0
    return formatter.string(from: NSNumber(value: value)) ?? String(value)
}

private func tokenNumber(_ value: Double?) -> String {
    guard let value, value.isFinite, value >= 0 else { return "—" }
    if value >= 1_000_000_000 { return String(format: "%.2fB", value / 1_000_000_000) }
    if value >= 1_000_000 { return String(format: "%.2fM", value / 1_000_000) }
    if value >= 10_000 { return String(format: "%.1fK", value / 1_000) }
    return String(format: "%.0f", value)
}

private func exactTokens(_ value: Double?) -> String {
    guard let value, value.isFinite, value >= 0 else { return "—" }
    let formatter = NumberFormatter()
    formatter.locale = Localization.locale
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 0
    return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value)
}
