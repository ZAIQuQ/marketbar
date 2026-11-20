import AppKit
import Foundation
import SwiftUI
import TickerCore

@main
struct MarketBarEntry {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--self-test") {
            exit(runStoreChecks() ? 0 : 1)
        } else if CommandLine.arguments.contains("--archive-test") {
            Task { @MainActor in
                let diskPassed = await runArchiveChecks()
                let lifecyclePassed = await runHistoryIntegrationChecks()
                exit(diskPassed && lifecyclePassed ? 0 : 1)
            }
            app.run()
        } else if let index = CommandLine.arguments.firstIndex(of: "--preview"),
                  CommandLine.arguments.indices.contains(index + 1) {
            Task { @MainActor in
                do {
                    try await renderProjectPreview(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                    exit(0)
                } catch {
                    fputs("Preview failed: \(error.localizedDescription)\n", stderr)
                    exit(1)
                }
            }
            app.run()
        } else if CommandLine.arguments.contains("--diagnose") {
            let diagnostic = LiveDiagnostic()
            diagnostic.start()
            withExtendedLifetime(diagnostic) { app.run() }
        } else {
            // Avoid duplicate menu items from a second development/installed bundle.
            if NSRunningApplication.runningApplications(withBundleIdentifier: "local.leoping.MarketBar")
                .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) { return }
            let delegate = AppDelegate()
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        }
    }
}

@MainActor
private final class LiveDiagnostic {
    let store = MarketStore(archive: nil)
    var samples: [[String: Any]] = []
    var seen: [String: Date] = [:]
    var timer: Timer?

    func start() {
        print("Observing Yahoo Finance for 20s; no credentials or trades are involved.")
        store.start()
        timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            finish()
        }
    }

    private func sample() {
        for (symbol, quote) in store.quotes where quote.source == .stream {
            guard seen[symbol] != quote.timestamp else { continue }
            seen[symbol] = quote.timestamp
            samples.append(["symbol": symbol, "price": quote.price,
                "quoteTime": ISO8601DateFormatter().string(from: quote.timestamp),
                "session": quote.session.rawValue, "arrivalAgeSeconds": store.deliveryLag[symbol] ?? -1])
        }
    }

    private func finish() {
        let result: [String: Any] = [
            "observedAt": ISO8601DateFormatter().string(from: Date()),
            "connection": store.connectionText,
            "streamSamples": samples,
            "latest": store.quotes.values.map { ["symbol": $0.symbol, "price": $0.price,
                "quoteTime": ISO8601DateFormatter().string(from: $0.timestamp),
                "source": $0.source.rawValue, "session": $0.session.rawValue] as [String: Any] },
            "errors": store.symbolErrors,
            "minuteBars": store.candles.mapValues { bars in
                ["count": bars.count,
                 "premarket": bars.filter { $0.session == .pre }.count,
                 "online": bars.filter { $0.origin == .yahoo }.count,
                 "local": bars.filter { $0.origin == .localSample }.count,
                 "mixed": bars.filter { $0.origin == .mixed }.count]
            }, "historyErrors": store.historyErrors,
            "previousCloseByDay": store.chartReferences.mapValues { $0.mapValues(\.previousClose) }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) { print(text) }
        if let index = CommandLine.arguments.firstIndex(of: "--render-chart"),
           CommandLine.arguments.indices.contains(index + 1),
           let symbol = store.symbols.first, let bars = store.candles[symbol], !bars.isEmpty {
            let hover = CommandLine.arguments.contains("--render-hover") ? bars.last(where: { $0.session == .pre })?.minute : nil
            let view = IntradayChartView(symbol: symbol, candles: bars, loading: false, error: nil,
                                        references: store.chartReferences[symbol] ?? [:], initialHover: hover, onRefresh: {})
                .padding(18).frame(width: 680, height: 480)
                .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light)
            // Render our own view hierarchy, including native segmented controls,
            // without requiring screen recording or controlling another app.
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(x: 0, y: 0, width: 680, height: 480)
            hosting.layoutSubtreeIfNeeded()
            if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    do {
                        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]), options: .atomic)
                    } catch { fputs("Chart preview write failed: \(error.localizedDescription)\n", stderr) }
                }
            }
        }
        timer?.invalidate()
        store.stop()
        exit(samples.isEmpty ? 2 : 0)
    }
}
