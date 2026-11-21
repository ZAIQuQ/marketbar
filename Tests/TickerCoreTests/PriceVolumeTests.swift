import Foundation
import TickerCore

final class PriceVolumeTests {
    private let symbol = "SOXL-USDT-SWAP"
    private let base = Date(timeIntervalSince1970: 1_795_248_000)

    func testMinutePriceVolumeIsBothDirectionsAndDoesNotMedianAwayBurst() throws {
        for sign in [-1.0, 1.0] {
            var detector = makeDetector()
            var alerts: [MarketAlert] = []
            for second in 0...18 {
                let price = second < 6 ? 100 : 100 + sign * 0.7
                let result = step(&detector, second: second, price: price, volume: Double(second + 1) * 60)
                if second < 11 { XCTAssertNil(result.alert) }
                if let alert = result.alert { alerts.append(alert) }
            }
            XCTAssertEqual(alerts.count, 1)
            let alert = try XCTUnwrap(alerts.first)
            XCTAssertEqual(alert.direction, sign < 0 ? .down : .up)
            XCTAssertEqual(alert.timestamp, base.addingTimeInterval(11))
            XCTAssertEqual(alert.windowSeconds, 60)
            XCTAssertEqual(alert.volumeContracts, 720)
            XCTAssertEqual(alert.baselineVolumeContracts, 100)
            XCTAssertEqual(alert.volumeRatio, 7.2)
        }
    }

    func testPartialVolumeIsNotTimeExtrapolatedAndFinalFutureVolumeCannotLeak() {
        var detector = makeDetector()
        for second in 0...20 {
            let time = base.addingTimeInterval(Double(second))
            // This impossible early final observation must not replace the
            // genuine partial bar with a full minute of future volume.
            detector.ingestCandles([bar(at: base, close: 101, volume: 100_000, final: true, observed: time)])
            let result = step(&detector, second: second, price: 101, volume: Double(second + 1) * 2)
            XCTAssertNil(result.alert)
            if second >= 5 { XCTAssertEqual((result.volumeRatio ?? 100) < 1, true) }
        }
    }

    func testTwoMinuteVolumeUsesPreviousPlusCurrentAndOutsideBaseline() throws {
        var detector = makeDetector()
        detector.ingestCandles([bar(at: base.addingTimeInterval(-60), close: 100.4,
                                    volume: 400, final: true, observed: base)])
        var alert: MarketAlert?
        for second in 0...16 {
            if let value = step(&detector, second: second, price: 101.1, volume: 300 + Double(second)).alert { alert = value }
        }
        let value = try XCTUnwrap(alert)
        XCTAssertEqual(value.windowSeconds, 120)
        XCTAssertEqual(value.referencePrice, 100)
        XCTAssertEqual(value.baselineVolumeContracts, 200)
        XCTAssertEqual(value.volumeContracts, 710)
        XCTAssertEqual(value.volumeRatio, 3.55)
    }

    func testExecutionContractVolumeDeduplicatesIDsAndLegacyModelsDecode() throws {
        let time = base.addingTimeInterval(1)
        let one = PriceQuote(symbol: symbol, price: 100, timestamp: time, session: .perpetual,
                             source: .stream, tradeID: "a", sizeContracts: 5)
        let two = PriceQuote(symbol: symbol, price: 100, timestamp: time, session: .perpetual,
                             source: .stream, tradeID: "b", sizeContracts: 7)
        var book = CandleBook()
        book.ingest(one, receivedAt: time)
        book.ingest(one, receivedAt: time)
        book.ingest(two, receivedAt: time)
        XCTAssertEqual(book.candles.first?.sampleCount, 2)
        XCTAssertEqual(book.candles.first?.volumeContracts, 12)
        XCTAssertNil(book.candles.first?.volume)
        let raw = Data("""
        {"arg":{"channel":"trades","instId":"SOXL-USDT-SWAP"},"data":[{"instId":"SOXL-USDT-SWAP","px":"33.1","ts":"1795220761271","tradeId":"12345","sz":"12.5"}]}
        """.utf8)
        let execution = try XCTUnwrap(OKXDecoder.trades(raw, expectedSymbol: symbol).first)
        XCTAssertEqual(execution.tradeID, "12345")
        XCTAssertEqual(execution.sizeContracts, 12.5)
        let old = try JSONDecoder().decode(AlertConfiguration.self, from: Data("{\"enabled\":true,\"direction\":\"up\",\"oneMinutePercent\":0.8}".utf8))
        XCTAssertEqual(old.strategy, .legacyMomentum)
        XCTAssertEqual(old.oneMinutePercent, 0.8)
        XCTAssertEqual(AlertConfiguration.defaults.strategy, .minutePriceVolume)
        XCTAssertEqual(AlertConfiguration.defaults.direction, .both)
        XCTAssertEqual(AlertConfiguration.defaults.oneMinutePercent, 0.6)
        XCTAssertEqual(AlertConfiguration.defaults.twoMinutePercent, 1.0)
        XCTAssertEqual(AlertConfiguration.defaults.volumeMultiplier, 3)
    }

    /// Opt-in local fixture replay. No network or user paths are part of normal
    /// tests. Historical BBO and exact fills are unavailable, so the controlled
    /// quote inputs and one execution proxy per positive-volume second are
    /// explicitly reported rather than described as historical live evidence.
    static func replay(path: String) throws {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
        let symbol = object["symbol"] as! String
        let minuteRows = (object["minuteRows"] as! [[String]]).sorted { Double($0[0])! < Double($1[0])! }
        let secondRows = (object["secondRows"] as! [[String]]).sorted { Double($0[0])! < Double($1[0])! }
        let expected = object["expected"] as! [String: Any]
        let expectedCandidate = expected["firstCandidate"] as! [String: Any]
        let expectedAlert = expected["first5sConfirmation"] as! [String: Any]
        let iso = ISO8601DateFormatter()
        let candidateTime = iso.date(from: expectedCandidate["availableAtUTC"] as! String)!
        let alertTime = iso.date(from: expectedAlert["availableAtUTC"] as! String)!
        var detector = AnomalyDetector(symbol: symbol, configuration: AlertConfiguration(enabled: true))
        var pointer = 0
        var currentMinute: Double?
        var open = 0.0, high = 0.0, low = 0.0, close = 0.0, volume = 0.0
        var firstCandidate: Date?
        var alerts: [MarketAlert] = []
        for row in secondRows {
            let second = Double(row[0])! / 1_000
            let now = Date(timeIntervalSince1970: second + 1)
            while pointer < minuteRows.count, Double(minuteRows[pointer][0])! / 1_000 + 60 <= second + 1 {
                let data = try JSONSerialization.data(withJSONObject: ["code": "0", "data": [minuteRows[pointer]]])
                detector.ingestCandles(try OKXDecoder.candles(data, expectedSymbol: symbol, receivedAt: now))
                pointer += 1
            }
            let bucket = floor(second / 60) * 60
            if currentMinute != bucket {
                currentMinute = bucket; open = 0; high = 0; low = 0; close = 0; volume = 0
            }
            let size = Double(row[5])!
            let lastPrice = Double(row[4])!
            if size > 0 {
                if volume == 0 { open = Double(row[1])!; high = Double(row[2])!; low = Double(row[3])! }
                else { high = max(high, Double(row[2])!); low = min(low, Double(row[3])!) }
                close = lastPrice; volume += size
                detector.ingestTrade(PriceQuote(symbol: symbol, price: lastPrice,
                    timestamp: now.addingTimeInterval(-0.001), session: .perpetual, source: .stream,
                    tradeID: "one-second-proxy-\(row[0])", sizeContracts: size), receivedAt: now)
            }
            if volume > 0 {
                let minute = Date(timeIntervalSince1970: bucket)
                detector.ingestCandles([MinuteCandle(symbol: symbol, minute: minute,
                    open: open, high: high, low: low, close: close, volume: nil, session: .perpetual,
                    origin: .okx, firstEvent: minute, lastEvent: minute, observedAt: now,
                    sampleCount: 0, isFinal: second + 1 >= bucket + 60, volumeContracts: volume)])
            }
            detector.ingestTicker(OKXTicker(quote: PriceQuote(symbol: symbol, price: lastPrice,
                timestamp: now.addingTimeInterval(0.07), session: .perpetual, source: .stream, recordsPriceSample: false),
                reference: nil, bid: lastPrice * 0.99995, ask: lastPrice * 1.00005), receivedAt: now)
            let evaluation = detector.evaluate(at: now)
            if evaluation.phase == .confirming, firstCandidate == nil { firstCandidate = now }
            if let alert = evaluation.alert { alerts.append(alert) }
        }
        let first = try XCTUnwrap(alerts.first)
        XCTAssertEqual(firstCandidate, candidateTime)
        XCTAssertEqual(first.timestamp, alertTime)
        XCTAssertEqual(first.direction, .down)
        XCTAssertEqual(first.price, expectedAlert["price"] as! Double, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(first.volumeRatio), expectedAlert["volumeRatio"] as! Double, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(first.volumeContracts), expectedAlert["cumulativeVolumeContracts"] as! Double, accuracy: 0.000001)
        let alertData = try JSONEncoder().encode(first)
        let summary: [String: Any] = [
            "mode": "production-core-on-official-1s-bars-with-controlled-health-inputs",
            "seconds": secondRows.count, "firstCandidateUTC": firstCandidate.map(iso.string) ?? "none",
            "firstAlertUTC": iso.string(from: first.timestamp), "alerts": alerts.count,
            "alertTimeline": alerts.map { alert -> [String: Any] in
                ["timestampUTC": iso.string(from: alert.timestamp), "direction": alert.direction.rawValue,
                 "price": alert.price, "changePercent": alert.changePercent,
                 "windowSeconds": alert.windowSeconds, "escalated": alert.escalated,
                 "volumeRatio": alert.volumeRatio ?? 0]
            },
            "firstAlert": try JSONSerialization.jsonObject(with: alertData),
            "limitations": ["Availability assumed at each 1s close; not measured publication or network latency.",
                "BBO is controlled at a narrow synthetic spread; actual historical BBO is unavailable.",
                "Each positive-volume second supplies one aggregate execution proxy, not exact trade IDs or fills."]]
        print(String(decoding: try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }

    private func makeDetector() -> AnomalyDetector {
        var detector = AnomalyDetector(symbol: symbol, configuration: AlertConfiguration(enabled: true))
        detector.ingestCandles((-50..<0).map { bar(at: base.addingTimeInterval(Double($0 * 60)), close: 100,
                                                    volume: 100, final: true, observed: base) })
        return detector
    }

    private func step(_ detector: inout AnomalyDetector, second: Int, price: Double, volume: Double) -> MonitorEvaluation {
        let now = base.addingTimeInterval(Double(second))
        detector.ingestTrade(PriceQuote(symbol: symbol, price: price, timestamp: now,
            session: .perpetual, source: .stream, tradeID: "\(second)", sizeContracts: 1), receivedAt: now)
        detector.ingestTicker(OKXTicker(quote: PriceQuote(symbol: symbol, price: price,
            timestamp: now.addingTimeInterval(0.07), session: .perpetual, source: .stream, recordsPriceSample: false),
            reference: nil, bid: price * 0.9999, ask: price * 1.0001), receivedAt: now)
        detector.ingestCandles([bar(at: base, close: price, volume: volume, final: false, observed: now)])
        return detector.evaluate(at: now)
    }

    private func bar(at minute: Date, close: Double, volume: Double, final: Bool, observed: Date) -> MinuteCandle {
        MinuteCandle(symbol: symbol, minute: minute, open: close, high: close, low: close, close: close,
                     volume: nil, session: .perpetual, origin: .okx, firstEvent: minute, lastEvent: minute,
                     observedAt: observed, sampleCount: 0, isFinal: final, volumeContracts: volume)
    }
}
