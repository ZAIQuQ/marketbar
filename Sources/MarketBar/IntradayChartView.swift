import SwiftUI
import TickerCore

/// A fixed time scale deliberately leaves unobserved minutes empty.
struct IntradayChartView: View {
    let symbol: String
    let candles: [MinuteCandle]
    let loading: Bool
    let error: String?
    let references: [String: ChartReference]
    let onRefresh: () -> Void

    init(symbol: String, candles: [MinuteCandle], loading: Bool, error: String?,
         references: [String: ChartReference] = [:], initialHover: Date? = nil,
         onRefresh: @escaping () -> Void) {
        self.symbol = symbol
        self.candles = candles
        self.loading = loading
        self.error = error
        self.references = references
        self.onRefresh = onRefresh
        self._hoveredMinute = State(initialValue: initialHover)
    }

    @State private var mode: ChartMode = .candles
    @State private var selectedSession: TradingSession = .pre
    @State private var selectedDay = ""
    @State private var hoveredMinute: Date?
    @State private var hoveringGap = false
    @State private var showingDataInfo = false

    private enum ChartMode: String, CaseIterable {
        case line = "分时"
        case candles = "1 分 K"
    }

    private static let newYork = TimeZone(identifier: "America/New_York")!
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = newYork
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = newYork
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private var symbolCandles: [MinuteCandle] {
        candles.filter { $0.symbol == symbol }.sorted { $0.minute < $1.minute }
    }

    private var dayKeys: [String] {
        Array(Set(symbolCandles.map { Self.dayFormatter.string(from: $0.minute) })).sorted(by: >)
    }

    private var effectiveDay: String {
        if dayKeys.contains(selectedDay) { return selectedDay }
        if let premarket = symbolCandles.last(where: { $0.session == .pre }) {
            return Self.dayFormatter.string(from: premarket.minute)
        }
        return dayKeys.first ?? ""
    }

    private var sessionCandles: [MinuteCandle] {
        let day = effectiveDay
        return symbolCandles.filter {
            $0.session == selectedSession && Self.dayFormatter.string(from: $0.minute) == day
                && $0.open.isFinite && $0.high.isFinite && $0.low.isFinite && $0.close.isFinite
                && [$0.open, $0.high, $0.low, $0.close].allSatisfy { $0 > 0 }
        }
    }

    private var detailCandle: MinuteCandle? {
        if let hoveredMinute,
           let hovered = sessionCandles.first(where: { $0.minute == hoveredMinute }) { return hovered }
        return sessionCandles.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(symbol).font(.system(size: 22, weight: .semibold, design: .rounded))
                Text("USD").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(MarketIconButtonStyle())
                    .disabled(loading)
                    .help("刷新分钟行情")
                    .accessibilityLabel("刷新分钟行情")
            }

            details.frame(height: 66, alignment: .topLeading)

            HStack(spacing: 12) {
                HStack(spacing: 2) {
                    ForEach(ChartMode.allCases, id: \.self) { item in
                        segment(item.rawValue, selected: mode == item) { mode = item }
                    }
                }
                .padding(3).background(MarketTheme.subtleSurface, in: RoundedRectangle(cornerRadius: 9))
                HStack(spacing: 2) {
                    ForEach([TradingSession.pre, .regular, .post], id: \.self) { item in
                        segment(item.label, selected: selectedSession == item) { selectedSession = item }
                    }
                }.padding(3).background(MarketTheme.subtleSurface, in: RoundedRectangle(cornerRadius: 9))
                Spacer(minLength: 0)
                Picker("美东日期", selection: Binding(
                    get: { effectiveDay }, set: { selectedDay = $0 }
                )) {
                    if dayKeys.isEmpty { Text("暂无日期").tag("") }
                    ForEach(dayKeys, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 136)
                .disabled(dayKeys.isEmpty)
                .help("美东日期")
            }

            GeometryReader { geometry in
                let visible = sessionCandles
                let layout = PlotLayout(size: geometry.size, day: effectiveDay, session: selectedSession,
                                        candles: visible)
                ZStack {
                    Canvas { context, size in
                        drawGrid(context: &context, layout: layout, hasData: !visible.isEmpty)
                        if mode == .candles {
                            drawCandles(context: &context, layout: layout, candles: visible)
                        } else {
                            drawLine(context: &context, layout: layout, candles: visible)
                        }
                        if let hoveredMinute,
                           let candle = visible.first(where: { $0.minute == hoveredMinute }) {
                            drawCrosshair(context: &context, layout: layout, candle: candle)
                        }
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            guard layout.plot.contains(point) else {
                                hoveredMinute = nil
                                hoveringGap = false
                                return
                            }
                            let target = layout.time(at: point.x)
                            let nearest = visible.min {
                                abs($0.minute.addingTimeInterval(30).timeIntervalSince(target))
                                    < abs($1.minute.addingTimeInterval(30).timeIntervalSince(target))
                            }
                            if let nearest,
                               abs(nearest.minute.addingTimeInterval(30).timeIntervalSince(target)) <= 30 {
                                hoveredMinute = nearest.minute
                                hoveringGap = false
                            } else {
                                hoveredMinute = nil
                                hoveringGap = true
                            }
                        case .ended:
                            hoveredMinute = nil
                            hoveringGap = false
                        }
                    }
                    if visible.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: loading ? "clock" : "chart.xyaxis.line")
                                .font(.title2).foregroundStyle(.secondary)
                            Text(loading ? "正在加载…" : "暂无\(selectedSession.label)数据")
                                .font(.callout)
                            if !loading {
                                Text("试试其他日期，或稍后刷新")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .allowsHitTesting(false)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(symbol)，\(effectiveDay) 美东时间，\(selectedSession.label)，\(visible.count) 个有数据的分钟。缺失分钟留空。")
            }
            .frame(height: 248)

            HStack(spacing: 12) {
                Text("Yahoo Finance").font(.system(size: 10)).foregroundStyle(.secondary)
                if sessionCandles.contains(where: { $0.origin != .yahoo }) {
                    legendItem("含本机采样", color: .orange, outlined: true)
                }
                Spacer(minLength: 0)
                Text("美东时间").font(.system(size: 10)).foregroundStyle(.secondary)
                Button { showingDataInfo.toggle() } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("数据说明")
                    .popover(isPresented: $showingDataInfo) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("数据说明").font(.headline)
                            Text("分钟数据来自 Yahoo Finance。橙色标记含本机收到的报价样本，可能不完整。缺失分钟留空。")
                            Text("涨跌幅相对所选交易日的昨收价。当前分钟仍会更新。")
                        }.font(.system(size: 12)).padding(18).frame(width: 290)
                    }
            }
            if let error, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).lineLimit(2)
            }
        }
        .padding(14)
        .onChange(of: symbol) { _ in
            selectedDay = ""
            selectedSession = .pre
            clearHover()
        }
        .onChange(of: selectedDay) { _ in clearHover() }
        .onChange(of: selectedSession) { _ in clearHover() }
    }

    @ViewBuilder
    private var details: some View {
        if hoveringGap {
            VStack(alignment: .leading, spacing: 4) {
                Text("—").font(.system(size: 32, weight: .semibold))
                Text("此分钟无数据").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        } else if let candle = detailCandle {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("$\(Self.price(candle.close))")
                        .font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(changeLabel(candle)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(changeColor(candle))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(changeColor(candle).opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                }
                Text("\(Self.clockFormatter.string(from: candle.minute)) · \(selectedSession.label) · \(referenceLabel(candle))")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
        } else {
            Text("—").font(.system(size: 32, weight: .semibold)).foregroundStyle(.secondary)
        }
    }

    private func segment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? MarketTheme.accent : Color.secondary)
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(selected ? MarketTheme.surface : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityValue(selected ? "已选中" : "")
    }

    private func reference(_ candle: MinuteCandle) -> ChartReference? {
        let day = Self.dayFormatter.string(from: candle.minute)
        guard let value = references[day], value.day == day else { return nil }
        return value
    }

    private func changeLabel(_ candle: MinuteCandle) -> String {
        guard let value = reference(candle)?.percentChange(at: candle.close) else { return "涨跌幅 —" }
        return String(format: "%+.2f%%", abs(value) < 0.005 ? 0 : value)
    }

    private func changeColor(_ candle: MinuteCandle) -> Color {
        guard let value = reference(candle)?.percentChange(at: candle.close), abs(value) >= 0.005 else { return .secondary }
        return MarketTheme.changeColor(value)
    }

    private func referenceLabel(_ candle: MinuteCandle) -> String {
        guard let value = reference(candle) else { return "昨收基准暂无" }
        return "较昨收 $\(Self.price(value.previousClose))"
    }

    private func legendItem(_ title: String, color: Color, outlined: Bool) -> some View {
        HStack(spacing: 4) {
            if outlined {
                RoundedRectangle(cornerRadius: 1).stroke(color, lineWidth: 1.2).frame(width: 8, height: 8)
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func clearHover() {
        hoveredMinute = nil
        hoveringGap = false
    }

    private static func price(_ value: Double) -> String {
        String(format: value < 1 ? "%.4f" : "%.2f", value)
    }

    private struct PlotLayout {
        let plot: CGRect
        let start: Date
        let end: Date
        let low: Double
        let high: Double

        init(size: CGSize, day: String, session: TradingSession, candles: [MinuteCandle]) {
            plot = CGRect(x: 58, y: 12, width: max(1, size.width - 72), height: max(1, size.height - 42))
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = IntradayChartView.newYork
            let date = IntradayChartView.dayFormatter.date(from: day)
                ?? calendar.startOfDay(for: Date())
            let minutes: (Int, Int)
            switch session {
            case .pre: minutes = (240, 570)
            case .regular: minutes = (570, 960)
            case .post: minutes = (960, 1200)
            default: minutes = (240, 1200)
            }
            start = calendar.date(bySettingHour: minutes.0 / 60, minute: minutes.0 % 60, second: 0, of: date)!
            end = calendar.date(bySettingHour: minutes.1 / 60, minute: minutes.1 % 60, second: 0, of: date)!
            let minimum = candles.map(\.low).min() ?? 0
            let maximum = candles.map(\.high).max() ?? 1
            let padding = max((maximum - minimum) * 0.09, max(abs(maximum) * 0.0005, 0.005))
            low = max(0, minimum - padding)
            high = max(low + 0.01, maximum + padding)
        }

        var duration: TimeInterval { max(60, end.timeIntervalSince(start)) }
        func x(_ minute: Date) -> CGFloat {
            plot.minX + CGFloat(minute.addingTimeInterval(30).timeIntervalSince(start) / duration) * plot.width
        }
        func y(_ value: Double) -> CGFloat {
            plot.maxY - CGFloat((value - low) / (high - low)) * plot.height
        }
        func time(at x: CGFloat) -> Date {
            start.addingTimeInterval(Double((x - plot.minX) / plot.width) * duration)
        }
    }

    private func drawGrid(context: inout GraphicsContext, layout: PlotLayout, hasData: Bool) {
        let tickMinutes: [Double]
        switch selectedSession {
        case .pre: tickMinutes = [0, 90, 180, 270, 330]
        case .regular: tickMinutes = [0, 90, 180, 270, 390]
        case .post: tickMinutes = [0, 60, 120, 180, 240]
        default: tickMinutes = [0, 240, 480, 720, 960]
        }
        for index in 0...4 {
            let fraction = Double(index) / 4
            let y = layout.plot.minY + CGFloat(fraction) * layout.plot.height
            var line = Path()
            line.move(to: CGPoint(x: layout.plot.minX, y: y))
            line.addLine(to: CGPoint(x: layout.plot.maxX, y: y))
            context.stroke(line, with: .color(MarketTheme.separator), lineWidth: 0.5)
            if hasData {
                let price = layout.high - fraction * (layout.high - layout.low)
                context.draw(Text(Self.price(price)).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary),
                             at: CGPoint(x: layout.plot.minX - 7, y: y), anchor: .trailing)
            }
        }
        for (index, minutes) in tickMinutes.enumerated() {
            let fraction = minutes * 60 / layout.duration
            let date = layout.start.addingTimeInterval(layout.duration * fraction)
            let x = layout.plot.minX + CGFloat(fraction) * layout.plot.width
            let anchor: UnitPoint = index == 0 ? .leading : (index == 4 ? .trailing : .center)
            context.draw(Text(Self.clockFormatter.string(from: date)).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary),
                         at: CGPoint(x: x, y: layout.plot.maxY + 17), anchor: anchor)
        }
    }

    private func drawCandles(context: inout GraphicsContext, layout: PlotLayout, candles: [MinuteCandle]) {
        let width = min(6, max(1, layout.plot.width / CGFloat(layout.duration / 60) * 0.72))
        for candle in candles {
            let x = layout.x(candle.minute)
            guard x >= layout.plot.minX, x <= layout.plot.maxX else { continue }
            let color: Color = candle.close >= candle.open ? MarketTheme.positive : MarketTheme.negative
            let sampled = candle.origin == .localSample
            var wick = Path()
            wick.move(to: CGPoint(x: x, y: layout.y(candle.high)))
            wick.addLine(to: CGPoint(x: x, y: layout.y(candle.low)))
            context.stroke(wick, with: .color(sampled ? .orange : color),
                           style: StrokeStyle(lineWidth: 0.8, dash: sampled ? [2, 2] : []))
            let top = min(layout.y(candle.open), layout.y(candle.close))
            let height = max(1.2, abs(layout.y(candle.open) - layout.y(candle.close)))
            let body = Path(CGRect(x: x - width / 2, y: top, width: width, height: height))
            if sampled {
                context.fill(body, with: .color(.orange.opacity(0.12)))
                context.stroke(body, with: .color(.orange), lineWidth: 0.9)
            } else {
                context.fill(body, with: .color(color))
                if candle.origin == .mixed {
                    context.stroke(body, with: .color(.orange), lineWidth: 0.8)
                }
            }
        }
    }

    private func drawLine(context: inout GraphicsContext, layout: PlotLayout, candles: [MinuteCandle]) {
        var previous: MinuteCandle?
        for candle in candles {
            let point = CGPoint(x: layout.x(candle.minute), y: layout.y(candle.close))
            guard layout.plot.contains(point) else { previous = nil; continue }
            if let last = previous {
                let gap = candle.minute.timeIntervalSince(last.minute)
                if gap > 0, gap <= 60.01 {
                    var path = Path()
                    path.move(to: CGPoint(x: layout.x(last.minute), y: layout.y(last.close)))
                    path.addLine(to: point)
                    let sampled = candle.origin == .localSample || last.origin == .localSample
                    context.stroke(path, with: .color(sampled ? .orange : MarketTheme.accent),
                                   style: StrokeStyle(lineWidth: 1.5, dash: sampled ? [3, 2] : []))
                }
            }
            if candle.origin != .yahoo || previous == nil {
                let color: Color = candle.origin == .yahoo ? MarketTheme.accent : .orange
                context.fill(Path(ellipseIn: CGRect(x: point.x - 1.5, y: point.y - 1.5, width: 3, height: 3)), with: .color(color))
            }
            previous = candle
        }
    }

    private func drawCrosshair(context: inout GraphicsContext, layout: PlotLayout, candle: MinuteCandle) {
        let point = CGPoint(x: layout.x(candle.minute), y: layout.y(candle.close))
        var path = Path()
        path.move(to: CGPoint(x: point.x, y: layout.plot.minY))
        path.addLine(to: CGPoint(x: point.x, y: layout.plot.maxY))
        path.move(to: CGPoint(x: layout.plot.minX, y: point.y))
        path.addLine(to: CGPoint(x: layout.plot.maxX, y: point.y))
        context.stroke(path, with: .color(MarketTheme.accent.opacity(0.5)),
                       style: StrokeStyle(lineWidth: 0.7, dash: [3, 3]))
        context.fill(Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)),
                     with: .color(MarketTheme.accent))
        // Place the readout next to the real candle's closing-price crosshair,
        // flipping at plot edges so neither value is clipped by the popover.
        let width: CGFloat = 178
        let height: CGFloat = 52
        let proposedX = point.x + 12 + width <= layout.plot.maxX ? point.x + 12 : point.x - width - 12
        let proposedY = point.y - height - 12 >= layout.plot.minY ? point.y - height - 12 : point.y + 12
        let box = CGRect(x: max(layout.plot.minX + 3, min(proposedX, layout.plot.maxX - width - 3)),
                         y: max(layout.plot.minY + 3, min(proposedY, layout.plot.maxY - height - 3)),
                         width: width, height: height)
        let bubble = Path(roundedRect: box, cornerRadius: 7)
        context.fill(bubble, with: .color(Color(nsColor: .controlBackgroundColor).opacity(0.97)))
        context.stroke(bubble, with: .color(.secondary.opacity(0.35)), lineWidth: 0.7)
        context.draw(Text("$\(Self.price(candle.close))")
            .font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundColor(.primary),
                     at: CGPoint(x: box.minX + 10, y: box.minY + 15), anchor: .leading)
        context.draw(Text(changeLabel(candle))
            .font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundColor(changeColor(candle)),
                     at: CGPoint(x: box.maxX - 10, y: box.minY + 15), anchor: .trailing)
        context.draw(Text("\(Self.clockFormatter.string(from: candle.minute)) · \(referenceLabel(candle))")
            .font(.system(size: 10)).foregroundColor(.secondary),
                     at: CGPoint(x: box.minX + 10, y: box.minY + 36), anchor: .leading)
    }
}
