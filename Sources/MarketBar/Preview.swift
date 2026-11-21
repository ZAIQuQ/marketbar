import AppKit
import SwiftUI
import TickerCore

// Self-contained example market data for the README. No network, account,
// production preferences or user history are read by this renderer.
@MainActor
func renderProjectPreview(to directory: URL) async throws {
    let suite = "MarketBar.Preview.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(120, forKey: "chartWindowMinutes")
    defer { defaults.removePersistentDomain(forName: suite) }

    let symbol = "SOXL-USDT-SWAP"
    let start = ISO8601DateFormatter().date(from: "2026-11-21T01:45:00Z")!
    let utcOpen = 33.50
    var bars: [MinuteCandle] = []
    var previous = 33.35
    for minute in 0..<120 {
        let t = Double(minute)
        let drift = -0.0006 * t
        let decline = min(max(t - 79, 0), 29) * 0.032
        let recovery = max(t - 108, 0) * 0.008
        let close = 33.35 + drift - decline + recovery
            + 0.055 * sin(t / 7.3) + 0.017 * sin(t / 2.1)
        let time = start.addingTimeInterval(t * 60)
        bars.append(MinuteCandle(symbol: symbol, minute: time, open: previous,
            high: max(previous, close) + 0.025,
            low: min(previous, close) - 0.025,
            close: close, volume: nil, session: .perpetual, origin: .okx,
            firstEvent: time, lastEvent: time.addingTimeInterval(59),
            observedAt: time.addingTimeInterval(60), sampleCount: 0,
            isFinal: true, volumeContracts: 1_000 + t * 17))
        previous = close
    }
    let btc = PriceQuote(symbol: "BTC-USDT", price: 96_284.50,
        timestamp: start.addingTimeInterval(120 * 60), session: .spot, source: .stream,
        recordsPriceSample: false)
    let soxl = PriceQuote(symbol: symbol, price: bars.last!.close,
        timestamp: btc.timestamp, session: .perpetual, source: .stream,
        recordsPriceSample: false)
    let reference = ChartReference(day: "2026-11-21", previousClose: utcOpen, basis: .utcOpen)
    let chart = IntradayChartView(symbol: symbol, candles: bars, loading: false, error: nil,
        references: [reference.day: reference], initialHover: bars[105].minute, onRefresh: {})

    let composition = VStack(spacing: 0) {
        PreviewMenuBar(btc: btc, soxl: soxl)
        Rectangle().fill(MarketTheme.separator).frame(height: 0.5)
        VStack(spacing: 0) {
            HStack {
                Spacer()
                PreviewPopoverArrow().fill(MarketTheme.surface).frame(width: 18, height: 10)
                    .padding(.trailing, 136)
            }
            VStack(spacing: 0) {
                HStack {
                    Label("自选股", systemImage: "chevron.left")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    Text("界面示例").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16).padding(.vertical, 11)
                Rectangle().fill(MarketTheme.separator).frame(height: 0.5).padding(.horizontal, 14)
                chart
            }
            .frame(width: 680)
            .background(MarketTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(MarketTheme.separator, lineWidth: 0.7))
            .shadow(color: .black.opacity(0.11), radius: 12, y: 5)
            Text("示例行情 · 非实时报价")
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 15)
        }
        .padding(.horizontal, 40).padding(.top, 10)
        Spacer(minLength: 12)
    }
    .frame(width: 760, height: 620, alignment: .top)
    .defaultAppStorage(defaults)

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let previousAppearance = NSApp.appearance
    defer { NSApp.appearance = previousAppearance }
    for (scheme, name) in [(ColorScheme.light, "marketbar.png"), (.dark, "marketbar-dark.png")] {
        NSApp.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        let background = scheme == .light ? Color(red: 0.94, green: 0.95, blue: 0.95)
            : Color(red: 0.075, green: 0.085, blue: 0.09)
        let view = composition.background(background).environment(\.colorScheme, scheme)
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSApp.appearance
        hosting.frame = NSRect(x: 0, y: 0, width: 760, height: 620)
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    // Preserve the existing --preview settings image without using the real
    // monitor configuration, event history, notifications or power assertions.
    let monitor = AlertMonitor(defaults: defaults, systemEffects: false)
    defer { monitor.shutdown() }
    NSApp.appearance = NSAppearance(named: .aqua)
    let settingsView = AlertPanel(monitor: monitor, onBack: {})
        .defaultAppStorage(defaults).environment(\.colorScheme, .light)
    let panel = NSHostingView(rootView: settingsView)
    panel.appearance = NSApp.appearance
    panel.frame = NSRect(x: 0, y: 0, width: 680, height: 560)
    panel.layoutSubtreeIfNeeded()
    guard let bitmap = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) else {
        throw CocoaError(.fileWriteUnknown)
    }
    panel.cacheDisplay(in: panel.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: directory.appendingPathComponent("monitor-settings.png"), options: .atomic)
}

private struct PreviewMenuBar: View {
    let btc: PriceQuote
    let soxl: PriceQuote

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "apple.logo").font(.system(size: 14))
                Text("MarketBar").font(.system(size: 12, weight: .semibold))
            }.frame(width: 90, alignment: .leading)
            Spacer(minLength: 8)
            Text(menuTitle(btc)).frame(width: 125)
            Text(menuTitle(soxl)).frame(width: 148, height: 25)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            Image(systemName: "wifi").font(.system(size: 12)).frame(width: 16)
            Text(clock).font(.system(size: 12, weight: .medium)).frame(width: 48)
        }
        .font(.system(size: 12, weight: .medium)).monospacedDigit()
        .padding(.horizontal, 18).frame(height: 34)
        .background(MarketTheme.surface)
    }

    private func menuTitle(_ quote: PriceQuote) -> String {
        let name = Instrument.isOKXSpot(quote.symbol) ? String(quote.symbol.dropLast(5))
            : Instrument.displaySymbol(quote.symbol)
        let suffix = Instrument.isOKXSpot(quote.symbol) ? "现" : "永"
        return "\(name) \(quote.price.formatted(.number.precision(.fractionLength(2))))\(suffix)"
    }

    private var clock: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: soxl.timestamp)
    }
}

private struct PreviewPopoverArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
