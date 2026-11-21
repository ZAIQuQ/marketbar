import AppKit
import Foundation
import SwiftUI
import UserNotifications
import TickerCore

@main
struct MarketBarEntry {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--notification-status") {
            guard Bundle.main.bundleURL.pathExtension == "app" else {
                print("Notification status is available from the built app bundle.")
                return
            }
            Task { @MainActor in
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                print("authorization=\(settings.authorizationStatus.rawValue) alerts=\(settings.alertSetting.rawValue)")
                exit(0)
            }
            app.run()
        } else if CommandLine.arguments.contains("--self-test") {
            exit(runStoreChecks() && runAlertMonitorChecks() ? 0 : 1)
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
    let store: MarketStore
    private let suite = "MarketBar.Diagnostic.\(UUID().uuidString)"
    var samples: [[String: Any]] = []
    var seen: [String: Date] = [:]
    var timer: Timer?
    private var duration = 20
    private var monitorSamples: [[String: Any]] = []
    private var monitorSampleSecond: Int64?

    init() {
        let defaults = UserDefaults(suiteName: suite)!
        var symbols = UserDefaults.standard.stringArray(forKey: "MarketBar.watchlist") ?? ["AMD", "NVDA"]
        if let index = CommandLine.arguments.firstIndex(of: "--symbols"),
           CommandLine.arguments.indices.contains(index + 1),
           let requested = try? Watchlist.parse(CommandLine.arguments[index + 1]) { symbols = requested }
        defaults.set(symbols, forKey: "MarketBar.watchlist")
        store = MarketStore(defaults: defaults, archive: nil)
        if let index = CommandLine.arguments.firstIndex(of: "--seconds"),
           CommandLine.arguments.indices.contains(index + 1),
           let requested = Int(CommandLine.arguments[index + 1]), (10...300).contains(requested) { duration = requested }
        if CommandLine.arguments.contains("--monitor") {
            var configuration = AlertConfiguration.defaults
            configuration.enabled = true
            _ = store.monitor.updateConfiguration(configuration)
        }
    }

    func start() {
        print("Observing market data for \(duration)s; no credentials or trading actions are involved.")
        store.start()
        timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration) * 1_000_000_000)
            finish()
        }
    }

    private func sample() {
        if CommandLine.arguments.contains("--monitor") {
            let now = Date()
            let second = Int64(now.timeIntervalSince1970)
            if monitorSampleSecond != second {
                monitorSampleSecond = second
                let evaluation = store.monitor.evaluation
                var row: [String: Any] = ["time": now.timeIntervalSince1970,
                    "phase": evaluation.phase.rawValue, "detail": evaluation.detail]
                row["oneMinuteChange"] = evaluation.oneMinuteChange
                row["threeMinuteChange"] = evaluation.threeMinuteChange
                row["oneMinuteThreshold"] = evaluation.oneMinuteThreshold
                row["threeMinuteThreshold"] = evaluation.threeMinuteThreshold
                monitorSamples.append(row)
            }
        }
        for (symbol, quote) in store.quotes where quote.source == .stream {
            guard seen[symbol] != quote.timestamp else { continue }
            seen[symbol] = quote.timestamp
            samples.append(["symbol": symbol, "price": quote.price,
                "quoteTime": ISO8601DateFormatter().string(from: quote.timestamp),
                "session": quote.session.rawValue, "arrivalAgeSeconds": store.deliveryLag[symbol] ?? -1])
        }
    }

    private func finish() {
        let formatter = ISO8601DateFormatter()
        var latestQuotes: [[String: Any]] = []
        for quote in store.quotes.values {
            latestQuotes.append(["symbol": quote.symbol, "price": quote.price,
                                 "quoteTime": formatter.string(from: quote.timestamp),
                                 "source": quote.source.rawValue, "session": quote.session.rawValue])
        }
        var minuteBars: [String: [String: Int]] = [:]
        for (symbol, bars) in store.candles {
            minuteBars[symbol] = ["count": bars.count,
                                 "premarket": bars.filter { $0.session == .pre }.count,
                                 "online": bars.filter { $0.origin == .yahoo || $0.origin == .okx }.count,
                                 "local": bars.filter { $0.origin == .localSample }.count,
                                 "mixed": bars.filter { $0.origin == .mixed }.count]
        }
        var references: [String: [String: [String: Any]]] = [:]
        for (symbol, days) in store.chartReferences {
            var values: [String: [String: Any]] = [:]
            for (day, reference) in days {
                values[day] = ["price": reference.previousClose, "basis": reference.basis.rawValue]
            }
            references[symbol] = values
        }
        var connections: [String: String] = [:]
        for symbol in store.symbols { connections[symbol] = store.connectionLabel(symbol: symbol) }
        let candleTimes: [String: String] = store.candleReceivedAt.mapValues { formatter.string(from: $0) }
        let result: [String: Any] = [
            "observedAt": formatter.string(from: Date()),
            "connection": store.connectionText,
            "streamSamples": samples,
            "latest": latestQuotes,
            "errors": store.symbolErrors,
            "minuteBars": minuteBars,
            "historyErrors": store.historyErrors,
            "chartReferences": references,
            "connections": connections,
            "candleConnection": store.candleConnectionText,
            "candleLastReceived": candleTimes,
            "monitorSamples": monitorSamples,
            "monitorAlerts": store.monitor.history.count
        ]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) { print(text) }
        if let index = CommandLine.arguments.firstIndex(of: "--render-chart"),
           CommandLine.arguments.indices.contains(index + 1),
           let symbol = store.symbols.first, let bars = store.candles[symbol], !bars.isEmpty {
            let expectedSession: TradingSession = Instrument.isOKX(symbol) ? .perpetual : .pre
            let hover = CommandLine.arguments.contains("--render-hover") ? bars.last(where: { $0.session == expectedSession })?.minute : nil
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
        UserDefaults.standard.removePersistentDomain(forName: suite)
        exit(samples.isEmpty ? 2 : 0)
    }
}
