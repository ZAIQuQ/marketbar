import Foundation
import TickerCore

/// Deterministic logic checks only. These do not estimate a live false-alert
/// rate, market predictability, execution quality, or trading profitability.
final class AnomalyTests {
    private let symbol = "SOXL-USDT-SWAP"
    private let base = Date(timeIntervalSince1970: 1_795_248_000)

    func testSustainedMoveNeedsWarmupAndFiveSecondsConfirmation() throws {
        var detector = monitor()
        var alerts: [MarketAlert] = []
        for second in 0...75 {
            let result = step(&detector, second, price: second < 60 ? 100 : 101)
            if let alert = result.alert { alerts.append(alert) }
            if second < 67 { XCTAssertNil(result.alert) }
        }
        XCTAssertEqual(alerts.count, 1)
        let alert = try XCTUnwrap(alerts.first)
        XCTAssertEqual(alert.direction, .up)
        XCTAssertEqual(alert.windowSeconds, 60)
        XCTAssertEqual(alert.confirmedSeconds, 5)
        XCTAssertEqual(alert.referencePrice, 100)
        XCTAssertEqual(alert.price, 101)
        XCTAssertEqual(alert.changePercent, 1, accuracy: 0.00001)
        XCTAssertEqual(alert.thresholdPercent, 0.8)
        XCTAssertEqual(alert.escalated, false)
        XCTAssertEqual(try JSONDecoder().decode(MarketAlert.self, from: JSONEncoder().encode(alert)), alert)
    }

    func testIsolatedOutlierAndNoisyFlatNeverConfirm() {
        var detector = monitor()
        for second in 0...170 {
            let price = (70...72).contains(second) ? 105 : second % 2 == 0 ? 100.03 : 99.97
            // The outlier prints have no corroborating move in the order book.
            let result = step(&detector, second, price: price, midpoint: 100)
            XCTAssertNil(result.alert)
        }
    }

    func testTickerUpdatesAndDuplicateExecutionCannotCreateConfirmation() {
        var detector = monitor()
        for second in 0...62 { _ = step(&detector, second, price: second < 60 ? 100 : 101) }
        let repeated = trade(62, price: 101)
        for second in 63...72 {
            detector.ingestTrade(repeated, receivedAt: time(second))
            detector.ingestTicker(ticker(second, midpoint: 101), receivedAt: time(second))
            let result = detector.evaluate(at: time(second))
            XCTAssertNil(result.alert)
            XCTAssertNil(detector.evaluate(at: time(second).addingTimeInterval(0.1)).alert)
        }
        var tickerOnly = monitor()
        for second in 0...100 {
            tickerOnly.ingestTicker(ticker(second, midpoint: second < 60 ? 100 : 102), receivedAt: time(second))
            XCTAssertNil(tickerOnly.evaluate(at: time(second)).alert)
        }
    }

    func testStaleWideSpreadSparseAndResetFailClosed() {
        var detector = monitor()
        for second in 0...65 {
            let result = step(&detector, second, price: second < 60 ? 100 : 101,
                              spread: second >= 60 ? 1 : 0.02)
            XCTAssertNil(result.alert)
            if second >= 60 { XCTAssertEqual(result.phase, .wideSpread) }
        }
        XCTAssertEqual(detector.evaluate(at: time(72)).phase, .stale)
        for second in 73...130 {
            let result = step(&detector, second, price: 102)
            XCTAssertNil(result.alert)
            if second >= 76 { XCTAssertEqual(result.phase, .warming) }
        }
        detector.reset()
        for second in 131...188 {
            let result = step(&detector, second, price: 104)
            XCTAssertNil(result.alert)
            if second >= 134 { XCTAssertEqual(result.phase, .warming) }
        }
        var sparse = monitor()
        for second in 0...65 {
            sparse.ingestTicker(ticker(second, midpoint: 100), receivedAt: time(second))
            if second % 3 == 0 { sparse.ingestTrade(trade(second, price: 100), receivedAt: time(second)) }
            let result = sparse.evaluate(at: time(second))
            XCTAssertNil(result.alert)
            XCTAssertEqual(result.phase == .sparse || result.phase == .warming, true)
        }
    }

    func testCachedOrFutureExecutionsCannotPrefillWarmup() {
        var detector = monitor()
        for second in 0..<60 { detector.ingestTrade(trade(second, price: 100), receivedAt: time(60)) }
        detector.ingestTrade(trade(68, price: 120), receivedAt: time(60))
        for second in 60...90 {
            let result = step(&detector, second, price: 102)
            XCTAssertNil(result.alert)
            if second >= 63 { XCTAssertEqual(result.phase, .warming) }
        }
        // An old packet with a new arrival time cannot rewind the live series.
        detector.ingestTrade(trade(61, price: 50), receivedAt: time(91))
        XCTAssertNil(step(&detector, 91, price: 102).alert)
    }

    func testCooldownSuppressesRepeatsButAllowsConfirmedEscalation() {
        var detector = monitor()
        var alerts: [MarketAlert] = []
        for second in 0...170 {
            let price: Double = second < 60 ? 100 : second < 80 ? 101 : second < 110 ? 101.6 : 102
            let result = step(&detector, second, price: price)
            if let alert = result.alert {
                alerts.append(alert)
                XCTAssertNil(detector.evaluate(at: time(second)).alert)
            }
        }
        XCTAssertEqual(alerts.count, 2)
        if alerts.count == 2 {
            XCTAssertEqual(alerts[0].escalated, false)
            XCTAssertEqual(alerts[1].escalated, true)
            XCTAssertEqual(alerts[1].timestamp.timeIntervalSince(alerts[0].timestamp) >= 30, true)
            XCTAssertEqual((alerts[1].price / alerts[0].price - 1) * 100 >= 0.8, true)
        }
    }

    func testDirectionChangesRequireFreshWarmup() {
        var up = monitor()
        for second in 0...90 { XCTAssertNil(step(&up, second, price: second < 60 ? 100 : 99).alert) }
        var config = enabled()
        config.direction = .down
        up.configure(config)
        for second in 91...145 { XCTAssertNil(step(&up, second, price: 98).alert) }
        for direction in [AlertDirection.down, .both] {
            config.direction = direction
            var detector = monitor(config)
            var alerts: [MarketAlert] = []
            for second in 0...80 {
                if let alert = step(&detector, second, price: second < 60 ? 100 : 99).alert { alerts.append(alert) }
            }
            XCTAssertEqual(alerts.count, 1)
            XCTAssertEqual(alerts.first?.direction, .down)
        }
    }

    func testOppositeDirectionsHaveIndependentCooldowns() {
        var configuration = enabled()
        configuration.direction = .both
        var detector = monitor(configuration)
        var alerts: [MarketAlert] = []
        for second in 0...190 {
            let price: Double = second < 60 ? 100 : second < 95 ? 101 : second < 140 ? 98 : 101
            if let alert = step(&detector, second, price: price).alert { alerts.append(alert) }
        }
        // The down move is independently eligible, while returning to the
        // already-alerted up price does not bypass that direction's cooldown.
        XCTAssertEqual(alerts.map(\.direction), [.up, .down])
        XCTAssertEqual(alerts.map(\.escalated), [false, false])

        var switched = monitor()
        var switchedAlerts: [MarketAlert] = []
        for second in 0...75 {
            if let alert = step(&switched, second, price: second < 60 ? 100 : 101).alert { switchedAlerts.append(alert) }
        }
        configuration.direction = .down
        switched.configure(configuration)
        for second in 76...155 {
            if let alert = step(&switched, second, price: second < 140 ? 101 : 98).alert { switchedAlerts.append(alert) }
        }
        XCTAssertEqual(switchedAlerts.map(\.direction), [.up, .down])
        XCTAssertEqual(switchedAlerts.last?.escalated, false)
    }

    func testVolatilityRaisesThresholdAndExcludesCurrentWindow() {
        var adaptive = monitor(withBaseline: false)
        adaptive.ingestCandles(baseline(volatile: true))
        var last = MonitorEvaluation(phase: .warming, detail: "")
        for second in 0...190 {
            last = step(&adaptive, second, price: second < 60 ? 100 : 101)
            XCTAssertNil(last.alert)
        }
        XCTAssertEqual((last.oneMinuteThreshold ?? 0) > 5, true)
        if let one = last.oneMinuteThreshold, let three = last.threeMinuteThreshold {
            XCTAssertEqual(three / one, sqrt(3), accuracy: 0.000001)
        }
        var excluded = monitor()
        // These confirmed, already observed bars overlap the candidate's latest
        // three-minute window and must not inflate its earlier volatility base.
        excluded.ingestCandles((-2..<0).map { offset in
            bar(minuteOffset: offset, close: offset == -2 ? 200 : 1)
        })
        var alert: MarketAlert?
        for second in 0...75 { alert = step(&excluded, second, price: second < 60 ? 100 : 101).alert ?? alert }
        XCTAssertEqual(alert?.thresholdPercent, 0.8)
    }

    func testPartialMixedFutureAndGappedBaselineAreNotEvidence() {
        let variants: [[MinuteCandle]] = [
            baseline(final: false),
            baseline(origin: .mixed),
            baseline(observedOffset: 1_000),
            baseline().filter { $0.minute != base.addingTimeInterval(-12 * 60) }
        ]
        for bars in variants {
            var detector = monitor(withBaseline: false)
            detector.ingestCandles(bars)
            for second in 0...75 {
                let result = step(&detector, second, price: second < 60 ? 100 : 101)
                XCTAssertNil(result.alert)
                if second >= 62 { XCTAssertEqual(result.phase, .warming) }
            }
        }
    }

    func testFixedThresholdOptOutStillNeedsLiveWarmup() {
        var config = enabled()
        config.volatilityMultiplier = 0
        var detector = monitor(config, withBaseline: false)
        var alerts: [MarketAlert] = []
        for second in 0...75 {
            let result = step(&detector, second, price: second < 60 ? 100 : 101)
            if second < 60 { XCTAssertNil(result.alert) }
            if let alert = result.alert { alerts.append(alert) }
        }
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.thresholdPercent, 0.8)
    }

    func testConfigurationAndBidAskParsing() throws {
        XCTAssertEqual(AlertConfiguration.defaults.enabled, false)
        XCTAssertNil(AlertConfiguration.defaults.validationError)
        var invalid = enabled()
        invalid.oneMinutePercent = .nan
        XCTAssertEqual(invalid.validationError != nil, true)
        var detector = monitor(invalid)
        XCTAssertEqual(step(&detector, 0, price: 100).phase, .off)
        let data = Data("""
        {"code":"0","data":[{"instId":"SOXL-USDT-SWAP","instType":"SWAP","last":"32.9","ts":"1795220761271","bidPx":"32.89","askPx":"32.91"}]}
        """.utf8)
        let parsed = try XCTUnwrap(OKXDecoder.ticker(data, expectedSymbol: symbol))
        XCTAssertEqual(parsed.bid, 32.89)
        XCTAssertEqual(parsed.ask, 32.91)
        XCTAssertEqual(parsed.quote.recordsPriceSample, false)
    }

    private func enabled() -> AlertConfiguration { AlertConfiguration(enabled: true) }

    private func monitor(_ configuration: AlertConfiguration? = nil, withBaseline: Bool = true) -> AnomalyDetector {
        var detector = AnomalyDetector(symbol: symbol, configuration: configuration ?? enabled())
        if withBaseline { detector.ingestCandles(baseline()) }
        return detector
    }

    private func step(_ detector: inout AnomalyDetector, _ second: Int, price: Double,
                      midpoint: Double? = nil, spread: Double = 0.02) -> MonitorEvaluation {
        detector.ingestTrade(trade(second, price: price), receivedAt: time(second))
        detector.ingestTicker(ticker(second, midpoint: midpoint ?? price, spread: spread), receivedAt: time(second))
        return detector.evaluate(at: time(second))
    }

    private func trade(_ second: Int, price: Double) -> PriceQuote {
        PriceQuote(symbol: symbol, price: price, timestamp: time(second), session: .perpetual, source: .stream)
    }

    private func ticker(_ second: Int, midpoint: Double, spread: Double = 0.02) -> OKXTicker {
        OKXTicker(quote: PriceQuote(symbol: symbol, price: midpoint, timestamp: time(second),
                                   session: .perpetual, source: .stream, recordsPriceSample: false),
                  reference: nil, bid: midpoint * (1 - spread / 200), ask: midpoint * (1 + spread / 200))
    }

    private func baseline(volatile: Bool = false, final: Bool = true, origin: CandleOrigin = .okx,
                          observedOffset: TimeInterval = 0) -> [MinuteCandle] {
        (-45..<0).map { offset in
            bar(minuteOffset: offset, close: volatile && offset % 2 == 0 ? 102 : 100,
                final: final, origin: origin, observedOffset: observedOffset)
        }
    }

    private func bar(minuteOffset: Int, close: Double = 100, final: Bool = true,
                     origin: CandleOrigin = .okx, observedOffset: TimeInterval = 0) -> MinuteCandle {
        let timestamp = base.addingTimeInterval(Double(minuteOffset * 60))
        return MinuteCandle(symbol: symbol, minute: timestamp, open: close, high: close, low: close, close: close,
                            volume: nil, session: .perpetual, origin: origin, firstEvent: timestamp,
                            lastEvent: timestamp, observedAt: base.addingTimeInterval(observedOffset),
                            sampleCount: origin == .mixed ? 1 : 0, isFinal: final)
    }

    private func time(_ second: Int) -> Date { base.addingTimeInterval(Double(second)) }
}
