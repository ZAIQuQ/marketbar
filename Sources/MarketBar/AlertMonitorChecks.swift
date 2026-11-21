import Foundation
import TickerCore

@MainActor
func runAlertMonitorChecks() -> Bool {
    let suite = "MarketBar.AlertChecks.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let monitor = AlertMonitor(defaults: defaults, systemEffects: false)
    defer { monitor.shutdown() }
    var configuration = AlertConfiguration.defaults
    configuration.enabled = true
    guard monitor.updateConfiguration(configuration) else { return false }
    monitor.setConnected(true, reason: "isolated fixture")
    let base = Date(timeIntervalSince1970: 1_795_233_600)
    let symbol = monitor.symbol
    let bars = (1...60).map { offset -> MinuteCandle in
        let minute = base.addingTimeInterval(Double(-offset * 60))
        return MinuteCandle(symbol: symbol, minute: minute, open: 100, high: 100, low: 100, close: 100,
            volume: nil, session: .perpetual, origin: .okx, firstEvent: minute, lastEvent: minute,
            observedAt: minute.addingTimeInterval(60), sampleCount: 0, isFinal: true)
    }
    monitor.ingestCandles(bars)
    for second in 0...155 {
        let price = second < 125 ? 100 : min(101.3, 100 + Double(second - 125) * 0.13)
        let time = base.addingTimeInterval(Double(second))
        for offset in [0.1, 0.5] {
            let trade = PriceQuote(symbol: symbol, price: price, timestamp: time.addingTimeInterval(offset),
                                   session: .perpetual, source: .stream)
            monitor.ingestTrades([trade], receivedAt: time.addingTimeInterval(offset + 0.01))
        }
        let quote = PriceQuote(symbol: symbol, price: price, timestamp: time.addingTimeInterval(0.7),
                               session: .perpetual, source: .stream, recordsPriceSample: false)
        monitor.ingestTicker(OKXTicker(quote: quote, reference: nil, bid: price - 0.01, ask: price + 0.01),
                             receivedAt: time.addingTimeInterval(0.71))
        monitor.tick(at: time.addingTimeInterval(0.9))
    }
    guard monitor.history.count == 1, monitor.pendingAlert?.direction == .up,
          monitor.pendingAlert!.changePercent >= configuration.oneMinutePercent else {
        print("FAIL monitor integration: confirmed move did not produce one pending event")
        return false
    }
    monitor.acknowledge()
    guard monitor.pendingAlert == nil, monitor.history.count == 1 else { return false }
    configuration.enabled = false
    guard monitor.updateConfiguration(configuration), !monitor.isEnabled,
          monitor.notificationStatus.contains("测试") else { return false }
    configuration.enabled = true
    _ = monitor.updateConfiguration(configuration)
    monitor.tick(at: base.addingTimeInterval(156))
    guard monitor.evaluation.phase == .warming, monitor.history.count == 1 else {
        print("FAIL monitor integration: re-enabling replayed a historical event")
        return false
    }
    print("PASS monitor integration: confirmation, pending badge, acknowledgment and rewarm; no system effects")
    return true
}
