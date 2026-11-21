import AppKit
import SwiftUI
import TickerCore

@MainActor
struct AlertPanel: View {
    @ObservedObject var monitor: AlertMonitor
    var onEnable: () -> Bool
    var onBack: () -> Void
    @State private var draft: AlertConfiguration
    @State private var oneMinuteText: String
    @State private var threeMinuteText: String
    @State private var confirmationText: String
    @State private var cooldownText: String
    @State private var adaptive: Bool
    @State private var keepAwakeDraft: Bool
    @State private var inputError: String?
    @State private var showingMethod = false

    init(monitor: AlertMonitor, onEnable: @escaping () -> Bool = { true }, onBack: @escaping () -> Void) {
        self.monitor = monitor
        self.onEnable = onEnable
        self.onBack = onBack
        let configuration = monitor.configuration
        _draft = State(initialValue: configuration)
        _oneMinuteText = State(initialValue: Self.number(configuration.oneMinutePercent))
        _threeMinuteText = State(initialValue: Self.number(configuration.threeMinutePercent))
        _confirmationText = State(initialValue: String(configuration.confirmationSeconds))
        _cooldownText = State(initialValue: Self.number(Double(configuration.cooldownSeconds) / 60))
        _adaptive = State(initialValue: configuration.volatilityMultiplier > 0)
        _keepAwakeDraft = State(initialValue: monitor.keepAwake)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .medium))
                }.buttonStyle(MarketIconButtonStyle()).help("返回")
                VStack(alignment: .leading, spacing: 3) {
                    Text("SOXLUSDT 盯盘").font(.system(size: 19, weight: .semibold))
                    Text("OKX 永续 · 异动提醒试运行").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                phaseBadge
                Button { showingMethod.toggle() } label: { Image(systemName: "info.circle") }
                    .buttonStyle(MarketIconButtonStyle()).help("触发规则")
                    .popover(isPresented: $showingMethod) { methodInfo }
            }
            Rectangle().fill(MarketTheme.separator).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let pending = monitor.pendingAlert { pendingCard(pending) }
                    HStack(alignment: .top, spacing: 16) {
                        settings.frame(maxWidth: .infinity, alignment: .topLeading)
                        status.frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    recentAlerts
                }.padding(.bottom, 4)
            }

            Text("基于行情，不是强平预警；减少提醒可能延后或漏报。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 680, height: 560)
        .background(MarketTheme.surface)
        .task { await monitor.refreshNotificationStatus() }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("提醒条件").font(.system(size: 12, weight: .semibold))
            Picker("监测方向", selection: $draft.direction) {
                Text("防上涨（空单）").tag(AlertDirection.up)
                Text("防下跌（多单）").tag(AlertDirection.down)
                Text("双向").tag(AlertDirection.both)
            }.font(.system(size: 11))

            HStack(spacing: 12) {
                numberField("1 分钟下限", text: $oneMinuteText, unit: "%")
                numberField("3 分钟下限", text: $threeMinuteText, unit: "%")
            }
            HStack(spacing: 12) {
                numberField("持续确认", text: $confirmationText, unit: "秒")
                numberField("提醒冷却", text: $cooldownText, unit: "分钟")
            }
            Toggle("自适应波动过滤", isOn: $adaptive)
                .font(.system(size: 11)).toggleStyle(.switch).controlSize(.small)
            Text(adaptive ? "波动较大时提高阈值，最低仍为上述下限。" : "仅使用固定下限，行情活跃时提醒可能增多。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("启用时保持 Mac 唤醒", isOn: $keepAwakeDraft)
                .font(.system(size: 11)).toggleStyle(.switch).controlSize(.small)
            Text("仅防自动睡眠；合盖或手动睡眠仍可能中断。")
                .font(.system(size: 10)).foregroundStyle(.secondary)

            if let inputError {
                Text(inputError).font(.system(size: 10)).foregroundStyle(MarketTheme.negative)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if monitor.isEnabled {
                    Button("暂停提醒", action: disable).buttonStyle(.bordered).controlSize(.small)
                }
                Spacer(minLength: 4)
                Button(monitor.isEnabled ? "保存设置" : "启用提醒") { apply() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
            Text("修改后点击保存生效。")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .padding(13)
        .background(MarketTheme.subtleSurface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("当前监测").font(.system(size: 12, weight: .semibold))
            Text(monitor.evaluation.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            thresholdRow("1 分钟", change: monitor.evaluation.oneMinuteChange,
                         threshold: monitor.evaluation.oneMinuteThreshold,
                         floor: monitor.configuration.oneMinutePercent)
            thresholdRow("3 分钟", change: monitor.evaluation.threeMinuteChange,
                         threshold: monitor.evaluation.threeMinuteThreshold,
                         floor: monitor.configuration.threeMinutePercent)
            Divider()
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "bell.slash").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("静音通知").font(.system(size: 11, weight: .medium))
                    Text(monitor.notificationStatus).font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    Task { await monitor.refreshNotificationStatus() }
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("刷新通知权限状态")
            }
            if let error = monitor.storageError {
                Text(error).font(.system(size: 10)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("在 OKX 查看", action: openOKX).buttonStyle(.borderless)
                .font(.system(size: 11)).help("打开 SOXL-USDT-SWAP 官方行情页")
        }
        .padding(13)
        .background(MarketTheme.subtleSurface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var phaseBadge: some View {
        HStack(spacing: 5) {
            Circle().fill(phaseColor).frame(width: 6, height: 6)
            Text(phaseLabel).font(.system(size: 10, weight: .medium)).foregroundStyle(phaseColor)
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(phaseColor.opacity(0.08), in: Capsule())
        .help(monitor.evaluation.detail)
    }

    private var phaseLabel: String {
        switch monitor.evaluation.phase {
        case .off: return "已暂停"
        case .warming: return "预热中"
        case .watching: return "监测中"
        case .confirming: return "持续确认中"
        case .stale: return "行情过期"
        case .wideSpread: return "价差过大"
        case .sparse: return "成交样本不足"
        }
    }

    private var phaseColor: Color {
        switch monitor.evaluation.phase {
        case .off: return .secondary
        case .watching: return MarketTheme.accent
        case .warming, .confirming, .stale, .wideSpread, .sparse: return .orange
        }
    }

    private func thresholdRow(_ title: String, change: Double?, threshold: Double?, floor: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium))
                Spacer()
                Text(change.map { String(format: "%+.2f%%", $0) } ?? "—")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
            }
            HStack {
                Text("实际阈值 " + (threshold.map { Self.number($0) + "%" } ?? "—"))
                Spacer()
                Text("下限 \(Self.number(floor))%")
            }.font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func pendingCard(_ alert: MarketAlert) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(MarketTheme.negative)
            VStack(alignment: .leading, spacing: 5) {
                Text("待查看 · \(alertTitle(alert))").font(.system(size: 12, weight: .semibold))
                Text("\(windowLabel(alert.windowSeconds)) \(signedPercent(alert.changePercent)) · \(Self.number(alert.price)) USDT")
                    .font(.system(size: 11)).monospacedDigit()
                Text(Self.timeFormatter.string(from: alert.timestamp) + " 本地")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("已查看") { monitor.acknowledge() }.buttonStyle(.bordered).controlSize(.small)
        }
        .padding(12)
        .background(MarketTheme.negative.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }

    private var recentAlerts: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("最近提醒").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("本地时间").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if monitor.history.isEmpty {
                Text("暂无提醒记录").font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.vertical, 10)
            } else {
                ForEach(Array(monitor.history.sorted { $0.timestamp > $1.timestamp }.prefix(12))) { alert in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(alertTitle(alert)).font(.system(size: 11, weight: .medium))
                            if alert.escalated {
                                Text("幅度扩大").font(.system(size: 9)).foregroundStyle(.orange)
                            }
                            Spacer()
                            Text(Self.timeFormatter.string(from: alert.timestamp))
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Text("\(windowLabel(alert.windowSeconds)) \(signedPercent(alert.changePercent)) · 阈值 \(Self.number(alert.thresholdPercent))% · 确认 \(alert.confirmedSeconds) 秒")
                            .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                        Text("\(Self.number(alert.referencePrice)) → \(Self.number(alert.price)) USDT")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    .padding(11)
                    .background(MarketTheme.subtleSurface, in: RoundedRectangle(cornerRadius: 9))
                }
            }
        }
    }

    private var methodInfo: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("触发规则").font(.headline)
            Text("比较真实成交样本在 1 分钟和 3 分钟窗口内的变动；超过阈值后持续确认，再发出静音提醒。")
            Text("自适应过滤以最近已完成分钟的波动为基准，阈值取固定下限与波动阈值中较高的一项。行情过期、价差过大或成交稀疏时暂停触发。")
            Text("冷却减少重复提醒，明显扩大的同向波动可能再次提醒。菜单栏警告会保留到手动标为已查看。")
        }.font(.system(size: 12)).padding(18).frame(width: 320)
    }

    private func numberField(_ title: String, text: Binding<String>, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            HStack(spacing: 5) {
                TextField("", text: text).textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced)).accessibilityLabel(title)
                Text(unit).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private func apply() {
        guard let one = Double(oneMinuteText.trimmingCharacters(in: .whitespaces)),
              let three = Double(threeMinuteText.trimmingCharacters(in: .whitespaces)),
              let confirmation = Int(confirmationText.trimmingCharacters(in: .whitespaces)),
              let minutes = Double(cooldownText.trimmingCharacters(in: .whitespaces)),
              minutes.isFinite, (0.5...1440).contains(minutes) else {
            inputError = "请输入有效数字；确认时间用整数秒，冷却时间为 0.5 至 1440 分钟。"
            return
        }
        var value = draft
        value.enabled = true
        value.oneMinutePercent = one
        value.threeMinutePercent = three
        value.confirmationSeconds = confirmation
        value.cooldownSeconds = Int((minutes * 60).rounded())
        value.volatilityMultiplier = adaptive ? 3.5 : 0
        if let error = value.validationError { inputError = error; return }
        guard onEnable() else {
            inputError = "自选已满，请先为 SOXLUSDT 留出一个位置。"
            return
        }
        guard monitor.updateConfiguration(value) else {
            inputError = monitor.storageError ?? "设置未保存，请稍后重试。"
            return
        }
        monitor.setKeepAwake(keepAwakeDraft)
        draft = value
        inputError = nil
    }

    private func disable() {
        var value = monitor.configuration
        value.enabled = false
        if monitor.updateConfiguration(value) { draft.enabled = false; inputError = nil }
        else { inputError = monitor.storageError ?? "暂时无法保存暂停状态。" }
    }

    private func openOKX() {
        NSWorkspace.shared.open(URL(string: "https://www.okx.com/trade-swap/soxl-usdt-swap")!)
    }

    private func alertTitle(_ alert: MarketAlert) -> String {
        switch alert.direction {
        case .up: return "上涨提醒"
        case .down: return "下跌提醒"
        case .both: return "价格异动"
        }
    }

    private func windowLabel(_ seconds: Int) -> String { "\(seconds / 60) 分钟" }
    private func signedPercent(_ value: Double) -> String { String(format: "%+.2f%%", value) }
    private static func number(_ value: Double) -> String { String(format: "%.2f", value) }
    private static let timeFormatter: DateFormatter = {
        let value = DateFormatter()
        value.locale = Locale(identifier: "en_US_POSIX")
        value.timeZone = .autoupdatingCurrent
        value.dateFormat = "MM-dd HH:mm:ss"
        return value
    }()
}

/// Observes the monitor directly; publishing a change inside MarketStore's
/// nested monitor does not by itself refresh a view observing only the store.
@MainActor
struct AlertToolbarButton: View {
    @ObservedObject var monitor: AlertMonitor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: monitor.pendingAlert == nil ? "bell" : "bell.badge.fill")
                .foregroundStyle(monitor.pendingAlert == nil ? Color.secondary : MarketTheme.negative)
        }
        .buttonStyle(MarketIconButtonStyle(selected: monitor.isEnabled))
        .help(monitor.pendingAlert == nil ? "SOXLUSDT 盯盘提醒" : "有已确认的价格异动，点击查看")
        .accessibilityLabel(monitor.pendingAlert == nil ? "打开盯盘提醒" : "查看待处理的盯盘提醒")
    }
}
