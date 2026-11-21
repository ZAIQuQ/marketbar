import AppKit
import SwiftUI
import TickerCore

// Deterministic screenshots use sample prices and never contact a data provider.
@MainActor
func renderProjectPreview(to directory: URL) async throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MarketBarPreview-\(UUID().uuidString)")
    let suite = "MarketBar.Preview.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: temporary)
    }
    let symbols = ["AMD", "NVDA", "AAPL"]
    defaults.set(symbols, forKey: "MarketBar.watchlist")
    let start = ISO8601DateFormatter().date(from: "2026-11-20T09:00:00Z")!
    let bases = [138.2, 129.4, 229.4]
    let archive = CandleArchive(directory: temporary)
    var series: [String: [MinuteCandle]] = [:]
    for (index, symbol) in symbols.enumerated() {
        var bars: [MinuteCandle] = []
        var previous = bases[index]
        for minute in 0..<261 {
            let t = Double(minute)
            let trend = index == 2 ? -0.000035 * t : 0.00009 * t
            let close = bases[index] * (1 + trend + 0.0025 * sin(t / 11) + 0.0013 * sin(t / 3.7))
            let time = start.addingTimeInterval(t * 60)
            bars.append(MinuteCandle(symbol: symbol, minute: time, open: previous,
                high: max(previous, close) + bases[index] * 0.0006,
                low: min(previous, close) - bases[index] * 0.0006,
                close: close, volume: 1000 + t * 17, session: .pre, origin: .yahoo,
                firstEvent: time, lastEvent: time.addingTimeInterval(59),
                observedAt: time.addingTimeInterval(60), sampleCount: 0))
            previous = close
        }
        series[symbol] = bars
        try await archive.save(symbol: symbol, candles: bars,
            references: ["2026-11-20": ChartReference(day: "2026-11-20", previousClose: bases[index])])
    }
    let store = MarketStore(defaults: defaults, archive: archive)
    store.prepareHistory()
    await store.finishHistory()
    let previewDate = start.addingTimeInterval(261 * 60 + 1)
    for symbol in symbols {
        let last = series[symbol]!.last!
        store.ingest(PriceQuote(symbol: symbol, price: last.close, timestamp: previewDate.addingTimeInterval(-2),
                                session: .pre, source: .stream), received: previewDate)
    }
    let chart = IntradayChartView(symbol: "AMD", candles: series["AMD"]!, loading: false, error: nil,
        references: store.chartReferences["AMD"]!, initialHover: series["AMD"]![210].minute, onRefresh: {})
    let composition = VStack(alignment: .leading, spacing: 22) {
        HStack(alignment: .firstTextBaseline) {
            Text("MarketBar").font(.system(size: 28, weight: .semibold, design: .rounded))
            Spacer()
            Text("界面预览 · 演示数据").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        HStack(alignment: .top, spacing: 24) {
            TickerPanel(store: store, previewDate: previewDate)
                .frame(width: 410, height: 520, alignment: .top)
                .background(MarketTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(MarketTheme.separator, lineWidth: 1))
            chart.padding(12).frame(width: 680, height: 520, alignment: .top)
                .background(MarketTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(MarketTheme.separator, lineWidth: 1))
        }
    }.padding(32).frame(width: 1178, height: 650)

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (scheme, name) in [(ColorScheme.light, "marketbar.png"), (.dark, "marketbar-dark.png")] {
        NSApp.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        let background = scheme == .light ? Color(red: 0.94, green: 0.95, blue: 0.95)
            : Color(red: 0.075, green: 0.09, blue: 0.095)
        let view = composition.background(background).environment(\.colorScheme, scheme)
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSApp.appearance
        hosting.frame = NSRect(x: 0, y: 0, width: 1178, height: 650)
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) {
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        }
    }
    let monitorView = AlertPanel(monitor: store.monitor, onBack: {})
        .environment(\.colorScheme, .light)
    NSApp.appearance = NSAppearance(named: .aqua)
    let panel = NSHostingView(rootView: monitorView)
    panel.appearance = NSApp.appearance
    panel.frame = NSRect(x: 0, y: 0, width: 680, height: 560)
    panel.layoutSubtreeIfNeeded()
    if let bitmap = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) {
        panel.cacheDisplay(in: panel.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) {
            try data.write(to: directory.appendingPathComponent("monitor-settings.png"), options: .atomic)
        }
    }
}
