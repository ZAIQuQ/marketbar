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
    configuration.strategy = .legacyMomentum
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
    let oldSettings = Data("""
    {"enabled":true,"direction":"up","oneMinutePercent":0.8,"threeMinutePercent":1.5,
     "confirmationSeconds":5,"cooldownSeconds":300,"volatilityMultiplier":3.5,"maximumSpreadPercent":0.3}
    """.utf8)
    defaults.set(oldSettings, forKey: "MarketBar.alertConfiguration")
    let upgraded = AlertMonitor(defaults: defaults, systemEffects: false)
    defer { upgraded.shutdown() }
    guard upgraded.isEnabled, upgraded.configuration.strategy == .minutePriceVolume,
          upgraded.configuration.direction == .both,
          upgraded.configuration.oneMinutePercent == AlertConfiguration.defaults.oneMinutePercent,
          defaults.data(forKey: "MarketBar.alertConfiguration.beforeMinutePriceVolume") == oldSettings else {
        print("FAIL monitor configuration migration")
        return false
    }
    var customized = upgraded.configuration
    customized.oneMinutePercent = 0.7
    _ = upgraded.updateConfiguration(customized)
    let reloaded = AlertMonitor(defaults: defaults, systemEffects: false)
    defer { reloaded.shutdown() }
    guard reloaded.configuration.oneMinutePercent == 0.7 else { return false }
    print("PASS monitor integration: confirmation, pending badge, acknowledgment, rewarm and settings migration; no system effects")
    return true
}
