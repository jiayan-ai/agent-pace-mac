import SwiftUI
import ServiceManagement
import PaceCore

struct PaceView: View {
    @ObservedObject var store: PaceStore
    var openWindow: (() -> Void)?
    @State private var showExplanation = false
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginFailed = false
    private var accent: Color { store.provider == .codex ? Color(red: 0.32, green: 0.35, blue: 0.87) : Color(red: 0.77, green: 0.42, blue: 0.29) }
    private var overBudget: Bool { (store.validBudget?.overBudget ?? 0) > 0 }
    private var balanceColor: Color { overBudget ? .red : accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            Picker(L("额度来源"), selection: Binding(get: { store.provider }, set: store.selectProvider)) {
                ForEach(UsageProvider.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().accessibilityLabel(L("切换 Codex 或 Claude Code"))
            if let selected = store.selected {
                if store.windows.count > 1 {
                    Picker(L("额度窗口"), selection: Binding(get: { store.selectedID }, set: store.choose)) {
                        ForEach(store.windows) { Text($0.label).tag($0.id) }
                    }
                    .labelsHidden()
                    .accessibilityLabel(L("选择额度窗口"))
                    .id(store.language)
                }
                if let pace = store.sessionPace {
                    ClaudeSessionView(pace: pace, stale: store.stale, accent: accent)
                        .id(store.language)
                } else if let pace = store.creditPace {
                    creditPacing(pace)
                    metrics(selected)
                } else if store.creditPlanNeedsConfirmation {
                    Label(L("Reset 券状态待同步确认，请刷新额度。"), systemImage: "clock.arrow.circlepath")
                        .font(.callout).foregroundStyle(.orange)
                    metrics(selected)
                } else {
                    hero
                    metrics(selected)
                    if let budget = store.validBudget { todayProgress(budget) }
                    else {
                        Label(L("等待最新额度，确认今天的预算"), systemImage: "clock.arrow.circlepath")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if store.provider == .codex {
                    ResetRadarView(store: store)
                    ResetInsightsView(store: store)
                }
                if store.stale {
                    Label(L("显示上次记录，尚未确认最新额度"), systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let error = store.error { errorMessage(error) }
                if store.provider == .claude, !store.claudeEnabled || store.error != nil { claudeConnection }

                if let error = store.persistenceError { errorMessage(error) }
                explanation
            } else {
                VStack(spacing: 14) {
                    Image(systemName: store.isRefreshing ? "arrow.triangle.2.circlepath.circle" : "gauge.with.dots.needle.0percent")
                        .font(.system(size: 46, weight: .light)).foregroundStyle(accent)
                    Text(store.isRefreshing ? L("正在读取你的额度") : L("等待额度数据"))
                        .font(.title3.weight(.semibold))
                    Text(store.error ?? (store.provider == .codex ? L("使用这台 Mac 已登录的 ChatGPT / Codex 账户。") : L("登录 Claude 后，自动同步与桌面 Code 共享的订阅额度。")))
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if !store.isRefreshing {
                        if store.provider == .claude { claudeConnection }
                        else { Button(L("重新同步")) { store.refresh() }.buttonStyle(.borderedProminent).tint(accent) }
                    }
                }.frame(maxWidth: .infinity).padding(.vertical, 45)
                if store.provider == .codex { ResetRadarView(store: store) }
            }
            footer
        }
        .padding(24)
        .frame(width: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "chart.pie.fill")
                .font(.system(size: 20, weight: .semibold)).foregroundStyle(accent)
                .frame(width: 38, height: 38)
                .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text("Agent Pace").font(.system(size: 16, weight: .semibold))
                Text(store.sessionPace == nil && store.creditPace == nil ? L("每日额度节奏") : L("每小时额度节奏")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Menu {
                Picker("Language / 语言", selection: Binding(get: { store.language }, set: store.selectLanguage)) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
            } label: { Image(systemName: "globe") }
                .menuStyle(.borderlessButton).frame(width: 22)
                .accessibilityLabel("Language / 语言")
                .id(store.language)
            if let selected = store.selected {
                Text(selected.label.replacingOccurrences(of: "\(store.provider.shortTitle) · ", with: ""))
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.quaternary.opacity(0.5), in: Capsule())
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text((overBudget ? L("今日预算已超额") : L("今天还可以用")) + (store.stale ? L(" · 上次记录") : ""))
                    .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: overBudget ? "exclamationmark.circle.fill" : "sparkle")
                    .foregroundStyle(balanceColor.opacity(0.75))
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(store.validBudget.map { number($0.leftToday) } ?? "—")
                    .font(.system(size: 62, weight: .medium, design: .rounded)).monospacedDigit()
                Text("%").font(.system(size: 28, weight: .regular, design: .rounded))
            }.foregroundStyle(balanceColor).accessibilityElement(children: .combine)
            Text(store.selected?.bucketID == "claude_fable" ? L("占 Fable 周额度的百分比") : L("占这个周期总额度的百分比"))
                .font(.caption).foregroundStyle(.secondary)
            if store.selected?.bucketID == "claude_fable" {
                Text(L("Fable 使用也计入总周额度，仍受总周额度和 5 小时额度限制。"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 19)
                .fill(LinearGradient(colors: [balanceColor.opacity(0.10), balanceColor.opacity(0.035)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }

    private func metrics(_ selected: MeteredWindow) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Label(L("周期剩余"), systemImage: "circle.dotted").font(.caption).foregroundStyle(.secondary)
                Text(selected.window.remaining.map { "\(number($0))%" } ?? L("未知"))
                    .font(.system(size: 25, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(L("已用 \(selected.window.usedPercent.map(number) ?? "—")%"))
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(.quaternary).frame(width: 1, height: 66).padding(.trailing, 22)
            VStack(alignment: .leading, spacing: 7) {
                Label(store.creditPace == nil ? L("距离重置") : L("距离自然重置"), systemImage: "arrow.clockwise").font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(store.daysLeft.map { String(format: "%.2f", $0) } ?? "—")
                        .font(.system(size: 25, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(L("天")).font(.caption).foregroundStyle(.secondary)
                }
                Text(selected.window.resetDate.map(resetTime) ?? L("时间未知"))
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.horizontal, 3)
    }

    private func creditPacing(_ pace: ResetCreditPace) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L("Reset 券到期倒计时"), systemImage: "timer")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text(pace.countdown).font(.callout.weight(.semibold)).monospacedDigit()
            }
            Text(L("有效期至 \(resetTime(pace.expiryDate))"))
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text(pace.isFinalHour ? L("到期前还可以用") : L("接下来每小时建议可用"))
                .font(.callout.weight(.medium)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(number(pace.allowance)).font(.system(size: 52, weight: .medium, design: .rounded)).monospacedDigit()
                Text(pace.isFinalHour ? "%" : L("% / 小时")).font(.system(size: 18, weight: .medium))
            }.foregroundStyle(accent).accessibilityElement(children: .combine)
            Text(pace.isFinalHour ? L("不足 1 小时，显示到期前的实际剩余额度。") : L("按当前剩余额度和到期前的小时数动态均摊。"))
                .font(.caption).foregroundStyle(.secondary)
            Text(store.autoResetEnabled ? L("已开启到期前自动使用；电脑需保持唤醒并联网。") : L("到期不会自动恢复额度；如需使用 Reset，请在 Codex 中手动操作。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 17))
    }

    private func todayProgress(_ budget: DailyBudget) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("今日预算")).font(.callout.weight(.medium))
                Spacer()
                Text("\(number(budget.allowance))%")
                    .font(.callout.weight(.semibold)).monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(accent.opacity(0.10))
                    Capsule().fill(budget.overBudget > 0 ? Color.red : accent)
                        .frame(width: max(0, proxy.size.width * budget.progress))
                }
            }.frame(height: 7)
            HStack {
                Text(L("已用 \(number(budget.consumed))%"))
                Spacer()
                Text(L("从 \(localTime(budget.startedAt)) 首次同步起"))
            }.font(.caption).foregroundStyle(.secondary)
            if budget.overBudget > 0 {
                Text(L("今日已超出均摊预算 \(number(budget.overBudget)) 个百分点。"))
                    .font(.caption).foregroundStyle(.red)
            } else if budget.leftToday <= 0 {
                Text(L("今天的均摊预算已用完。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }

    private var explanation: some View {
        DisclosureGroup(L("怎么算出来的"), isExpanded: $showExplanation) {
            VStack(alignment: .leading, spacing: 8) {
                if let pace = store.creditPace {
                    if !pace.isFinalHour {
                        Text(L("\(number(pace.remaining))% ÷ \(String(format: "%.2f", pace.secondsRemaining / 3600)) 小时 = \(number(pace.allowance))% / 小时"))
                            .font(.callout.weight(.medium)).monospacedDigit()
                    }
                    Text(L("仅当可用 Reset 券在 72 小时内到期且早于自然重置时，按最早到期券规划；不足 1 小时显示实际剩余额度。"))
                    Text(L("这是用量建议，券到期不会自动重置，实际使用仍受其他额度窗口限制。"))
                } else if store.creditPlanNeedsConfirmation {
                    Text(L("Reset 券状态待同步确认，请刷新额度。"))
                } else if let pace = store.sessionPace {
                    if let remaining = pace.remaining, let seconds = pace.secondsRemaining,
                       seconds >= 3600, let allowance = pace.allowance {
                        Text(L("\(number(remaining))% ÷ \(String(format: "%.2f", seconds / 3600)) 小时 = \(number(allowance))% / 小时"))
                            .font(.callout.weight(.medium)).monospacedDigit()
                    }
                    Text(L("剩余额度 ÷ 距重置的小时数，给出接下来每小时的均摊建议；随时间和同步到的用量更新，不使用今日预算。"))
                    Text(L("不足 1 小时时显示重置前的全部剩余额度。倒计时结束后等待服务端确认，不自动假设额度已恢复。"))
                    Text(L("额度无法准确换算成使用分钟数，实际消耗取决于模型和任务；总周额度和模型限额也可能先用完。"))
                } else {
                    if let budget = store.validBudget {
                        Text(L("\(number(budget.startingRemaining))% ÷ \(String(format: "%.2f", budget.planningDays)) 天 = \(number(budget.allowance))% / 天"))
                            .font(.callout.weight(.medium)).monospacedDigit()
                    }
                    Text(L("每天首次同步时，将剩余额度除以距重置的天数；不足 1 天按 1 天算。当天预算固定，再扣除首次同步之后用掉的额度。"))
                    Text(L("跨天、切换账户或额度重置后重新计算。百分比指总额度的百分点；这是均摊建议，实际使用仍受其他额度窗口限制。"))
                }
                if store.provider == .claude {
                    Text(L("Claude 各入口共享订阅额度。在工具内登录一次后自动同步；登录失效时重新连接即可，无需 Mac 钥匙串密码。"))
                    Text(L("当前 Claude 接口未提供 reset 券或账户月度历史，因此不推测券数，也不生成月度 reset 建议。"))
                    if store.claudeEnabled {
                        Button(L("断开 Claude 连接")) { store.disconnectClaude() }
                            .disabled(store.isRefreshing)
                    }
                }
                Toggle(L("登录 Mac 时启动"), isOn: $loginEnabled)
                    .onChange(of: loginEnabled) { enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                            loginFailed = false
                        } catch { loginFailed = true }
                    }
                if loginFailed { Text(L("请在系统设置 → 通用 → 登录项中检查启动权限。")).foregroundStyle(.orange) }
            }.font(.caption).foregroundStyle(.secondary).padding(.top, 9)
        }.font(.caption).foregroundStyle(.secondary)
    }

    private func errorMessage(_ message: String) -> some View {
        Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
    }

    private var claudeConnection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !store.claudeEnabled {
                Text(L("首次在工具的 Claude 网页窗口登录，之后自动同步。无需 Mac 钥匙串密码。"))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Button(store.disconnectingClaude ? L("正在断开…") : L("连接 Claude")) { store.connectClaude() }
                    .buttonStyle(.borderedProminent).disabled(store.disconnectingClaude)
                Button(L("打开 Claude")) { store.openClaude() }.buttonStyle(.link)
            }
        }.font(.caption)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button { store.refresh() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                    Text(store.isRefreshing ? L("同步中…") : L("刷新"))
                }
            }.disabled(store.isRefreshing || (store.provider == .claude && (!store.claudeEnabled || store.claudeNeedsLogin))).buttonStyle(.plain)
            Text(store.provider == .claude && (!store.claudeEnabled || store.claudeNeedsLogin)
                 ? L("等待连接 Claude")
                 : store.snapshot.map { L("\(localTime($0.fetchedAt)) 更新 · 每 5 分钟同步") } ?? L("自动同步"))
                .foregroundStyle(.tertiary).font(.system(size: 10))
            Spacer(minLength: 0)
            Menu {
                if let openWindow { Button(L("打开独立窗口"), action: openWindow) }
                Button(L("退出 Agent Pace")) { NSApp.terminate(nil) }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).frame(width: 20)
                .accessibilityLabel(L("更多选项"))
                .id(store.language)
        }.font(.caption).foregroundStyle(.secondary)
    }
}
