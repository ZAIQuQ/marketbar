import AppKit
import SwiftUI
import TickerCore

// Public documentation fixture. DEMO, every price, the date and the complete
// price path are invented here. No conversation-derived scenario, user history,
// account, network or existing application preferences are used.
@MainActor
func renderProjectPreview(to directory: URL) async throws {
    let suite = "MarketBar.PublicDemo.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let symbol = "DEMO"
    let start = ISO8601DateFormatter().date(from: "2031-07-17T08:00:00Z")!
    let previousClose = 18.00
    var bars: [MinuteCandle] = []
    var previous = 18.035
    for minute in 0..<297 {
        let t = Double(minute)
        let close = 18.00 + 0.0012 * t + 0.11 * sin(t / 28) + 0.035 * cos(t / 9)
        let time = start.addingTimeInterval(t * 60)
        bars.append(MinuteCandle(symbol: symbol, minute: time, open: previous,
            high: max(previous, close) + 0.012,
            low: min(previous, close) - 0.012,
            close: close, volume: 500 + t * 3, session: .pre, origin: .yahoo,
            firstEvent: time, lastEvent: time.addingTimeInterval(59),
            observedAt: time.addingTimeInterval(60), sampleCount: 0))
        previous = close
    }
    let reference = ChartReference(day: "2031-07-17", previousClose: previousClose)
    let chart = IntradayChartView(symbol: symbol, candles: bars, loading: false, error: nil,
        references: [reference.day: reference], initialHover: bars[163].minute, onRefresh: {})
    let quote = PriceQuote(symbol: symbol, price: bars.last!.close,
        timestamp: start.addingTimeInterval(297 * 60), session: .pre, source: .stream)

    let composition = VStack(spacing: 0) {
        PublicDemoMenuBar(quote: quote)
        Rectangle().fill(MarketTheme.separator).frame(height: 0.5)
        VStack(spacing: 0) {
            HStack {
                Spacer()
                PublicDemoPopoverArrow().fill(MarketTheme.surface).frame(width: 18, height: 10)
                    .padding(.trailing, 162)
            }
            VStack(spacing: 0) {
                HStack {
                    Label("自选股", systemImage: "chevron.left")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    Text("完全虚构示例").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
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
            Text("全部数据均为虚构示例 · 不对应真实标的或交易记录")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary.opacity(0.7)).padding(.top, 15)
        }
        .padding(.horizontal, 40).padding(.top, 10)
        Spacer(minLength: 12)
    }
    .frame(width: 760, height: 620, alignment: .top)
    .defaultAppStorage(defaults)
    .environment(\.locale, Locale(identifier: "en_US"))

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let previousAppearance = NSApp.appearance
    defer { NSApp.appearance = previousAppearance }
    for (scheme, name) in [(ColorScheme.light, "demo-chart.png"), (.dark, "demo-chart-dark.png")] {
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
    // Do not render a monitoring/settings panel: production monitor settings
    // are intentionally outside the public documentation fixture.
}

private struct PublicDemoMenuBar: View {
    let quote: PriceQuote

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "apple.logo").font(.system(size: 14))
                Text("MarketBar").font(.system(size: 12, weight: .semibold))
            }.frame(width: 90, alignment: .leading)
            Spacer(minLength: 8)
            Text("DEMO \(String(format: "%.2f", quote.price))前").frame(width: 200, height: 25)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            Image(systemName: "wifi").font(.system(size: 12)).frame(width: 16)
            Text("08:57").font(.system(size: 12, weight: .medium)).frame(width: 48)
        }
        .font(.system(size: 12, weight: .medium)).monospacedDigit()
        .padding(.horizontal, 18).frame(height: 34)
        .background(MarketTheme.surface)
    }
}

private struct PublicDemoPopoverArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
