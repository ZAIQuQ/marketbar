import AppKit
import SwiftUI
import Combine
import TickerCore
import Darwin

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let store = MarketStore()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var timer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var terminationSignal: DispatchSourceSignal?
    private var alertOpenObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 410, height: 520)
        popover.contentViewController = NSHostingController(rootView: TickerPanel(store: store) { [weak self] showing in
            self?.popover.contentSize = NSSize(width: showing ? 680 : 410, height: showing ? 560 : 520)
        })
        timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateTitle() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.store.stop() }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.store.reconnect() }
        })
        alertOpenObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("MarketBar.openSymbol"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.showPopover() }
        }
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            // terminateLater runs a nested AppKit loop. Enter it outside a
            // dispatch/Swift task so pending archive tasks can finish.
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated { NSApplication.shared.terminate(nil) }
            }
        }
        terminationSignal = source
        signal(SIGTERM, SIG_IGN)
        source.resume()
        store.start()
        updateTitle()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.monitor.shutdown()
        store.stop()
        timer?.invalidate()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        if let alertOpenObserver { NotificationCenter.default.removeObserver(alertOpenObserver) }
        alertOpenObserver = nil
        terminationSignal?.cancel()
        terminationSignal = nil
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        store.stop()
        store.monitor.shutdown()
        Task { @MainActor in
            await store.finishHistory()
            await store.monitor.flushEvents()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil); return }
        if store.monitor.pendingAlert != nil {
            NotificationCenter.default.post(name: Notification.Name("MarketBar.openSymbol"),
                                            object: nil, userInfo: ["symbol": store.monitor.symbol])
            return
        }
        showPopover()
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        popover.contentViewController?.view.window?.makeKey()
    }

    private func updateTitle() {
        let configured = UserDefaults.standard.integer(forKey: "menuSymbolCount")
        let count = configured == 0 ? 2 : min(3, max(1, configured))
        let now = Date()
        let menuSymbols = store.menuSymbols(at: now)
        let hiddenCount = max(0, store.symbols.count - menuSymbols.count)
        let parts = menuSymbols.prefix(count).map { symbol -> String in
            let name = Instrument.displaySymbol(symbol)
            let connection = store.isConnected(symbol: symbol) ? "" : "◌ "
            guard let quote = store.quotes[symbol] else { return "\(connection)\(name) —" }
            let old = now.timeIntervalSince(quote.timestamp) > 60
            let marker = old ? "·旧" : quote.source == .snapshot ? "≈" : shortSession(quote.session)
            return "\(connection)\(name) \(quote.price.formatted(.number.precision(.fractionLength(2))))\(marker)"
        }
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let pending = store.monitor.pendingAlert != nil
        statusItem.button?.title = (pending ? "⚠ " : "") + (parts.isEmpty ? "MarketBar" : parts.joined(separator: "  "))
        statusItem.button?.toolTip = (pending ? "SOXLUSDT 有已确认的异动，点击查看提醒。\n" : "")
            + (hiddenCount > 0 ? "\(hiddenCount) 只休市股票已隐藏，仍可在列表查看。\n" : "")
            + "MarketBar · \(store.connectionText)\n前 / 中 / 后：报价时段 · 永：OKX 永续 · ≈：快照 · 旧：超过 60 秒未更新"
    }
}

private func shortSession(_ session: TradingSession) -> String {
    switch session {
    case .pre: return "前"
    case .regular: return "中"
    case .post: return "后"
    case .perpetual: return "永"
    case .closed: return "闭"
    case .unknown: return "?"
    }
}

struct TickerPanel: View {
    @ObservedObject var store: MarketStore
    var previewDate: Date? = nil
    var onChartVisibility: (Bool) -> Void = { _ in }
    @AppStorage("menuSymbolCount") private var menuSymbolCount = 2
    @AppStorage("hideClosedStocks") private var hideClosedStocks = true
    @State private var editing = false
    @State private var draft = ""
    @State private var inputError: String?
    @State private var selectedSymbol: String?
    @State private var showingMonitor = false
    private let names = ["AMD": "超威半导体", "NVDA": "英伟达", "AAPL": "苹果", "MSFT": "微软", "TSLA": "特斯拉", "AMZN": "亚马逊", "GOOGL": "Alphabet", "META": "Meta"]
    private var hasOKX: Bool { store.symbols.contains { Instrument.isOKX($0) } }
    private var hasStocks: Bool { store.symbols.contains { !Instrument.isOKX($0) } }
    private var sourcesLabel: String {
        hasOKX ? (hasStocks ? "Yahoo Finance · OKX" : "OKX") : "Yahoo Finance"
    }

    var body: some View {
        Group {
            if showingMonitor {
                AlertPanel(monitor: store.monitor, onEnable: { store.ensureMonitoringTarget() }) {
                    showingMonitor = false
                    onChartVisibility(selectedSymbol != nil)
                }
            } else if let symbol = selectedSymbol {
                VStack(alignment: .leading, spacing: 12) {
                    chartNavigation(symbol)
                    Rectangle().fill(MarketTheme.separator).frame(height: 1)
                    IntradayChartView(symbol: symbol, candles: store.candles[symbol] ?? [],
                                      loading: store.historyLoading, error: store.historyErrors[symbol],
                                      references: store.chartReferences[symbol] ?? [:]) {
                        store.refreshSnapshots()
                    }
                }
                .padding(18).frame(width: 680)
            } else {
                watchlistPanel
            }
        }
        .tint(MarketTheme.accent)
        .background(MarketTheme.surface)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("MarketBar.openSymbol"))
            .receive(on: RunLoop.main)) { _ in
                selectedSymbol = store.monitor.symbol
                openMonitor()
            }
    }

    private var watchlistPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                MarketBrandMark()
                VStack(alignment: .leading, spacing: 2) {
                    Text("MarketBar").font(.system(size: 18, weight: .semibold))
                    Text(hasOKX ? (hasStocks ? "美股与永续" : "OKX 永续") : "美股自选")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                AlertToolbarButton(monitor: store.monitor, action: openMonitor)
                Button {
                    draft = store.symbols.joined(separator: ", ")
                    withAnimation(.easeOut(duration: 0.15)) { editing.toggle() }
                    inputError = nil
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(MarketIconButtonStyle(selected: editing))
                .help("编辑自选")
                .accessibilityLabel("编辑自选股")
            }
            .padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 18)

            if editing {
                settings.padding(.horizontal, 20).padding(.bottom, 16)
            }

            HStack(spacing: 5) {
                Text("自选").font(.system(size: 11, weight: .medium))
                Text("\(store.symbols.count)").font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                connectionBadge
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 24).padding(.bottom, 10)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(store.symbols, id: \.self) { symbol in
                            Button {
                                selectedSymbol = symbol
                                onChartVisibility(true)
                                store.refreshSnapshots()
                            } label: {
                                quoteRow(symbol, now: previewDate ?? context.date)
                            }
                            .buttonStyle(QuoteRowButtonStyle())
                            .accessibilityLabel("\(symbol)，查看走势图")
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Rectangle().fill(MarketTheme.separator).frame(height: 1).padding(.horizontal, 22)
            HStack(spacing: 6) {
                Text(sourcesLabel).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    .help("公开行情；推送和快照按来源标注。OKX 价格单位为 USDT。")
                Spacer()
                Button { store.reconnect() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(MarketIconButtonStyle())
                    .help("重新连接").accessibilityLabel("重新连接行情")
                Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(MarketIconButtonStyle())
                    .help("退出 MarketBar").accessibilityLabel("退出 MarketBar")
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
        }
        .frame(width: 410, height: 520)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("自选代码").font(.system(size: 11, weight: .medium))
                Spacer()
                Text("最多 12 只").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            TextField("AMD, NVDA, SOXLUSDT", text: $draft)
                .font(.system(size: 12, design: .monospaced))
                .textFieldStyle(.roundedBorder).onSubmit(saveWatchlist)
                .accessibilityLabel("自选股代码，逗号或空格分隔")
            if let inputError {
                Text(inputError).font(.system(size: 10)).foregroundStyle(MarketTheme.negative)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("菜单栏").font(.system(size: 11)).foregroundStyle(.secondary)
                Picker("菜单栏显示数量", selection: $menuSymbolCount) {
                    Text("1 只").tag(1)
                    Text("2 只").tag(2)
                    Text("3 只").tag(3)
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 126)
                Spacer()
                Button("完成", action: saveWatchlist)
                    .buttonStyle(.borderedProminent).controlSize(.small).keyboardShortcut(.return)
            }
            Toggle("休市股票自动从菜单栏隐藏", isOn: $hideClosedStocks)
                .font(.system(size: 11)).toggleStyle(.switch).controlSize(.small)
                .help("列表仍保留这些股票，开市后自动恢复。永续合约不受影响。")
            Text("逗号或空格分隔；SOXLUSDT 对应 SOXL-USDT-SWAP 永续。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(MarketTheme.subtleSurface, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func quoteRow(_ symbol: String, now: Date) -> some View {
        let quote = store.quotes[symbol]
        let perpetual = Instrument.isOKX(symbol)
        let closed = store.isStockClosed(symbol, at: now)
        let change = quote.flatMap { perpetual ? $0.changePercent : dailyChange($0) }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(Instrument.displaySymbol(symbol)).font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary).help(symbol)
                    Text(perpetual ? "OKX 永续 · USDT" : names[symbol] ?? "美股")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: 94, alignment: .leading)
                QuoteSparkline(candles: sparklineCandles(symbol, quote: quote),
                               color: change.map(MarketTheme.changeColor) ?? MarketTheme.accent)
                    .frame(width: 68, height: 28).opacity(0.8)
                    .accessibilityHidden(true)
                Spacer(minLength: 2)
                VStack(alignment: .trailing, spacing: 5) {
                    if let quote {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            if !perpetual {
                                Text("$").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                            }
                            Text(quote.price.formatted(.number.precision(.fractionLength(2))))
                                .font(.system(size: 23, weight: .medium, design: .monospaced))
                                .foregroundStyle(.primary)
                            if perpetual {
                                Text("USDT").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("—").font(.system(size: 23, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    if let change {
                        Text((perpetual ? "24h " : "") + String(format: "%+.2f%%", abs(change) < 0.005 ? 0 : change))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(MarketTheme.changeColor(change))
                            .help(perpetual ? "过去 24 小时涨跌幅" : "较上一交易日收盘")
                    } else {
                        Text("—").font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                            .help(perpetual ? "暂无 24 小时基准价" : "暂无对应交易日的昨收价")
                    }
                }
            }
            if let quote {
                let age = max(0, now.timeIntervalSince(quote.timestamp))
                HStack(spacing: 6) {
                    Text(quote.session.label)
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(MarketTheme.accent)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(MarketTheme.accent.opacity(0.075), in: RoundedRectangle(cornerRadius: 4))
                    Circle().fill(closed ? Color.secondary : store.isConnected(symbol: symbol) ? MarketTheme.accent : .orange)
                        .frame(width: 4, height: 4).help(store.connectionLabel(symbol: symbol))
                    Text(perpetual ? "行情更新" : quote.source == .stream ? "推送" : "快照")
                    Text("·").foregroundStyle(.tertiary)
                    Text(clockString(quote.timestamp, zone: Instrument.timeZone(symbol))).monospacedDigit()
                    Text(perpetual ? "UTC" : "美东")
                    Spacer()
                    if let error = store.symbolErrors[symbol] {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange).help(error)
                    }
                    Text(closed ? "休市" : age > 60 ? "\(ageText(age))未更新" : "\(ageText(age))前")
                        .foregroundStyle(!closed && age > 60 ? Color.orange : Color.secondary)
                }
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .help(quoteHelp(quote))
            } else {
                Text(store.symbolErrors[symbol] ?? (closed ? "休市 · 暂无报价" : "等待报价…"))
                    .font(.system(size: 10)).foregroundStyle(store.symbolErrors[symbol] == nil ? Color.secondary : .orange)
                    .lineLimit(1).help(store.symbolErrors[symbol] ?? "正在接收行情")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var connectionBadge: some View {
        if previewDate != nil {
            Text("界面预览").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                .help("示例数据")
        } else {
            HStack(spacing: 5) {
                Circle().fill(store.connected ? MarketTheme.accent : .orange).frame(width: 5, height: 5)
                Text(connectionLabel).font(.system(size: 9, weight: .medium))
                    .foregroundStyle(store.connected ? Color.secondary : .orange)
            }
            .help(store.connectionText)
            .accessibilityLabel(store.connectionText)
        }
    }

    private var connectionLabel: String {
        if store.connected { return "已连接" }
        if store.connectionText == "已暂停" { return "已暂停" }
        if store.connectionText.contains("断开") || store.connectionText.contains("重") { return "重连中" }
        return "连接中"
    }

    private func chartNavigation(_ symbol: String) -> some View {
        HStack(spacing: 12) {
            Button {
                selectedSymbol = nil
                onChartVisibility(false)
            } label: {
                Label("自选股", systemImage: "chevron.left")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .keyboardShortcut(.leftArrow, modifiers: [.command])
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let quote = store.quotes[symbol] {
                    let now = previewDate ?? context.date
                    let age = max(0, now.timeIntervalSince(quote.timestamp))
                    let closed = store.isStockClosed(symbol, at: now)
                    Text(closed ? "休市 · 保留最近报价" : "\(Instrument.isOKX(symbol) ? "行情更新" : quote.source == .snapshot ? "快照" : "报价") \(ageText(age))前")
                        .font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(!closed && age > 60 ? Color.orange : Color.secondary)
                        .help(quoteHelp(quote))
                } else {
                    Text("等待报价…").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            sourceConnectionBadge(symbol)
            if symbol == store.monitor.symbol {
                AlertToolbarButton(monitor: store.monitor, action: openMonitor)
            }
        }
        .frame(height: 24)
    }

    private func openMonitor() {
        showingMonitor = true
        onChartVisibility(true)
    }

    @ViewBuilder
    private func sourceConnectionBadge(_ symbol: String) -> some View {
        if previewDate != nil {
            Text("界面预览").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 5) {
                Circle().fill(store.isConnected(symbol: symbol) ? MarketTheme.accent : .orange)
                    .frame(width: 5, height: 5)
                Text(store.connectionLabel(symbol: symbol)).font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary).lineLimit(1)
            }.help(store.connectionLabel(symbol: symbol))
        }
    }

    private func dailyChange(_ quote: PriceQuote) -> Double? {
        let day = Instrument.day(quote.symbol, at: quote.timestamp)
        guard let reference = store.chartReferences[quote.symbol]?[day], reference.day == day,
              reference.basis == .previousClose else { return nil }
        return reference.percentChange(at: quote.price)
    }

    private func sparklineCandles(_ symbol: String, quote: PriceQuote?) -> [MinuteCandle] {
        guard let quote else { return [] }
        let day = Instrument.day(symbol, at: quote.timestamp)
        let lowerBound = quote.timestamp.addingTimeInterval(-90 * 60)
        return (store.candles[symbol] ?? []).filter {
            $0.session == quote.session && $0.minute <= quote.timestamp && $0.minute >= lowerBound
                && Instrument.day(symbol, at: $0.minute) == day
        }.sorted { $0.minute < $1.minute }
    }

    private func quoteHelp(_ quote: PriceQuote) -> String {
        let perpetual = Instrument.isOKX(quote.symbol)
        let source = perpetual ? (quote.source == .stream ? "OKX 推送" : "OKX 行情快照") : quote.source.label
        var lines = [
            "\(quote.symbol) · \(quote.session.label) · \(source)",
            "\(perpetual ? "UTC 行情更新" : "美东") \(timeString(quote.timestamp, zone: Instrument.timeZone(quote.symbol)))",
            "本地 \(timeString(quote.timestamp, zone: .current))",
            store.connectionLabel(symbol: quote.symbol)
        ]
        if perpetual { lines.append("价格为 USDT；24h 为滚动涨跌幅。更新时间是行情消息生成时间。") }
        if quote.source == .stream, let lag = store.deliveryLag[quote.symbol] {
            lines.append(lag < -1 ? "报价时间与本机时钟存在偏差" : "报价到达时相差 \(String(format: "%.1f", max(0, lag))) 秒")
        }
        if let error = store.symbolErrors[quote.symbol] { lines.append(error) }
        return lines.joined(separator: "\n")
    }

    private func saveWatchlist() {
        do {
            let symbols = try Watchlist.parse(draft)
            store.setSymbols(symbols)
            withAnimation(.easeOut(duration: 0.15)) { editing = false }
            inputError = nil
        } catch { inputError = error.localizedDescription }
    }
}

private struct QuoteRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { RowBody(configuration: configuration) }

    private struct RowBody: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(Color.primary.opacity(configuration.isPressed ? 0.065 : hovering ? 0.035 : 0),
                            in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(hovering ? MarketTheme.separator : .clear, lineWidth: 0.5))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

private struct QuoteSparkline: View {
    let candles: [MinuteCandle]
    let color: Color

    var body: some View {
        Canvas { context, size in
            let values = candles.filter { $0.close.isFinite && $0.close > 0 }
            guard values.count >= 2, let first = values.first, let last = values.last else { return }
            let duration = max(60, last.minute.timeIntervalSince(first.minute))
            let low = values.map(\.close).min()!
            let high = values.map(\.close).max()!
            let span = max(high - low, max(high * 0.0001, 0.0001))
            func point(_ candle: MinuteCandle) -> CGPoint {
                CGPoint(x: CGFloat(candle.minute.timeIntervalSince(first.minute) / duration) * size.width,
                        y: 2 + CGFloat(1 - (candle.close - low) / span) * max(1, size.height - 4))
            }
            var previous: MinuteCandle?
            for candle in values {
                if let previous, candle.minute.timeIntervalSince(previous.minute) <= 60.01 {
                    var path = Path()
                    path.move(to: point(previous))
                    path.addLine(to: point(candle))
                    context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                }
                previous = candle
            }
        }
    }
}

private func clockString(_ date: Date, zone: TimeZone) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = zone
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
}

private func ageText(_ seconds: TimeInterval) -> String {
    if seconds < 60 { return "\(Int(seconds)) 秒" }
    if seconds < 3600 { return "\(Int(seconds / 60)) 分钟" }
    if seconds < 86400 { return "\(Int(seconds / 3600)) 小时" }
    return "\(Int(seconds / 86400)) 天" }

private func timeString(_ date: Date, zone: TimeZone) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = zone
    formatter.dateFormat = "MM-dd HH:mm:ss"
    return formatter.string(from: date)
}
