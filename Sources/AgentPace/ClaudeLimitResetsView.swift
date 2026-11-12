import SwiftUI
import PaceCore

struct ClaudeLimitResetsView: View {
    let inventory: ClaudeLimitResets?
    let stale: Bool
    let observedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(L("Claude Reset 券"), systemImage: "ticket")
                    .font(.callout.weight(.medium))
                Spacer()
                if let inventory {
                    Text(inventory.availableCount.map { stale ? L("上次记录 \($0) 次") : L("\($0) 次可用") }
                         ?? (stale ? L("上次记录") : L("有可用券，数量未注明")))
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if let inventory {
                ForEach(Array(inventory.offers.enumerated()), id: \.offset) { _, offer in
                    HStack(alignment: .firstTextBaseline) {
                        Text(claudeResetTitle(offer.kind)).font(.callout)
                        if let count = offer.availableCount {
                            Text("×\(count)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        if let expiry = offer.expiryText {
                            Text(expiry).font(.caption).foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if stale, let observedAt {
                    Text(L("记录时间 \(resetTime(observedAt))")).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(stale ? L("等待同步 Claude Reset 券") : L("暂未从 Claude 用量页确认券数"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Link(L("在 Claude 用量页查看"), destination: URL(string: "https://claude.ai/settings/usage")!)
                .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }
}

func claudeResetTitle(_ kind: ClaudeLimitResets.Kind) -> String {
    switch kind {
    case .full: return L("完整重置")
    case .fable: return L("Fable 重置")
    case .weekly: return L("每周额度重置")
    case .session: return L("五小时额度重置")
    case .unspecified: return L("额度重置券")
    }
}
