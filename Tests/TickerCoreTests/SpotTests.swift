import Foundation
import TickerCore

final class SpotTests {
    private let symbol = "BTC-USDT"
    private let minute = Date(timeIntervalSince1970: 1_795_220_760)

    func testExplicitSpotAliasPreservesBareStockAndPerpetualSymbols() throws {
        XCTAssertEqual(try Watchlist.parse("BTC,btcusdt,BTC-USDT,BTC-USDT-SWAP,SOXL,SOXLUSDT,ETH-USDT"),
                       ["BTC", "BTC-USDT", "BTC-USDT-SWAP", "SOXL", "SOXL-USDT-SWAP", "ETH-USDT"])
        XCTAssertEqual(Instrument.isOKX("BTC"), false)
        XCTAssertEqual(Instrument.isOKXSpot(symbol), true)
        XCTAssertEqual(Instrument.isOKXPerpetual(symbol), false)
        XCTAssertEqual(Instrument.isOKXSpot("BTC-USDT-SWAP"), false)
        XCTAssertEqual(Instrument.isOKXPerpetual("BTC-USDT-SWAP"), true)
        XCTAssertEqual(Instrument.marketSession(symbol), .spot)
        XCTAssertEqual(Instrument.marketSession("BTC-USDT-SWAP"), .perpetual)
        XCTAssertEqual(Instrument.marketSession("BTC"), .unknown)
        XCTAssertEqual(Instrument.displaySymbol(symbol), "BTCUSDT")
        XCTAssertEqual(Instrument.currency(symbol), "USDT")
        XCTAssertEqual(Instrument.day(symbol, at: minute), "2026-11-21")
        XCTAssertEqual(Instrument.day("BTC", at: minute), "2026-11-20")
        XCTAssertEqual(TradingSession.spot.label, "现货")
        let maximum = String(repeating: "A", count: 27) + "-USDT"
        XCTAssertEqual(try Watchlist.parse(maximum), [maximum])
        for bad in [String(repeating: "A", count: 28) + "-USDT", "BTC--USDT", "-USDT", "BTC-USDT-SWAP-USDT"] {
            XCTAssertThrowsError(try Watchlist.parse(bad))
        }
    }

    func testSpotTickerValidatesSpotTypeAndCannotBecomePerpetual() throws {
        let row: [String: Any] = ["instType": "SPOT", "instId": symbol, "last": "90000",
                                  "open24h": "80000", "sodUtc0": "89000", "ts": "1795220761271",
                                  "bidPx": "89999.9", "askPx": "90000.1"]
        let data = try json(["code": "0", "data": [row]])
        let value = try XCTUnwrap(OKXDecoder.ticker(data, expectedSymbol: symbol))
        XCTAssertEqual(value.quote.session, .spot)
        XCTAssertEqual(value.quote.price, 90000)
        XCTAssertEqual(value.quote.changePercent, 12.5)
        XCTAssertEqual(value.quote.recordsPriceSample, false)
        XCTAssertEqual(value.reference?.basis, .utcOpen)
        XCTAssertEqual(value.reference?.day, "2026-11-21")
        XCTAssertNil(value.quote.sizeContracts)
        XCTAssertThrowsError(try OKXDecoder.ticker(data, expectedSymbol: "BTC-USDT-SWAP"))
        let wrongType = row.merging(["instType": "SWAP"]) { _, new in new }
        XCTAssertThrowsError(try OKXDecoder.ticker(json(["code": "0", "data": [wrongType]]), expectedSymbol: symbol))
        XCTAssertThrowsError(try OKXDecoder.ticker(json([
            "arg": ["channel": "tickers", "instId": "BTC-USDT-SWAP"], "data": [row]
        ]), expectedSymbol: symbol))
    }

    func testSpotExecutionsUseDeduplicatedBaseQuantityOnly() throws {
        let data = try json(["arg": ["channel": "trades", "instId": symbol], "data": [
            ["instId": symbol, "px": "90000", "ts": "1795220761000", "tradeId": "spot-1", "sz": "0.01"]
        ]])
        let quote = try XCTUnwrap(OKXDecoder.trades(data, expectedSymbol: symbol).first)
        XCTAssertEqual(quote.session, .spot)
        XCTAssertEqual(quote.sizeBase, 0.01)
        XCTAssertNil(quote.sizeContracts)
        var book = CandleBook()
        book.ingest(quote, receivedAt: minute.addingTimeInterval(2))
        book.ingest(quote, receivedAt: minute.addingTimeInterval(3))
        let local = try XCTUnwrap(book.candles.first)
        XCTAssertEqual(local.session, .spot)
        XCTAssertEqual(local.origin, .localSample)
        XCTAssertEqual(local.sampleCount, 1)
        XCTAssertEqual(local.volumeBase, 0.01)
        XCTAssertNil(local.volumeContracts)
        XCTAssertNil(local.volume)
        // A spot quote carrying the wrong session must not silently create a
        // perpetual-looking cache record under the spot instrument directory.
        var rejected = CandleBook()
        rejected.ingest(PriceQuote(symbol: symbol, price: 90000, timestamp: minute,
                                  session: .perpetual, source: .stream), receivedAt: minute)
        XCTAssertEqual(rejected.candles.count, 0)
    }

    func testSpotCandleVolumeAndLegacyCacheCompatibility() throws {
        let data = try json(["code": "0", "data": [[
            "1795220760000", "90000", "90010", "89990", "90005", "0.5", "45000", "45000", "1"
        ]]])
        let spot = try XCTUnwrap(OKXDecoder.candles(data, expectedSymbol: symbol,
                                                  receivedAt: minute.addingTimeInterval(60)).first)
        XCTAssertEqual(spot.session, .spot)
        XCTAssertEqual(spot.origin, .okx)
        XCTAssertEqual(spot.volumeBase, 0.5)
        XCTAssertNil(spot.volumeContracts)
        XCTAssertNil(spot.volume)
        var book = CandleBook()
        book.mergeRemote([spot])
        XCTAssertEqual(book.candles, [spot])
        let dataRoundTrip = try JSONEncoder().encode([spot])
        var restored = CandleBook()
        restored.restore(try JSONDecoder().decode([MinuteCandle].self, from: dataRoundTrip))
        XCTAssertEqual(restored.candles, [spot])
        let oldPerpetual = MinuteCandle(symbol: "SOXL-USDT-SWAP", minute: minute,
            open: 33, high: 34, low: 32, close: 33, volume: nil, session: .perpetual,
            origin: .okx, firstEvent: minute, lastEvent: minute, observedAt: minute.addingTimeInterval(60),
            sampleCount: 0, isFinal: true, volumeContracts: 10)
        let oldJSON = try JSONEncoder().encode(oldPerpetual)
        XCTAssertNil((try JSONSerialization.jsonObject(with: oldJSON) as! [String: Any])["volumeBase"])
        XCTAssertEqual(try JSONDecoder().decode(MinuteCandle.self, from: oldJSON), oldPerpetual)
        let contaminated = MinuteCandle(symbol: symbol, minute: minute,
            open: 90000, high: 90010, low: 89990, close: 90005, volume: nil, session: .spot,
            origin: .okx, firstEvent: minute, lastEvent: minute, observedAt: minute.addingTimeInterval(60),
            sampleCount: 0, isFinal: true, volumeContracts: 10)
        var invalid = CandleBook()
        invalid.restore([contaminated])
        XCTAssertEqual(invalid.candles.count, 0)
    }

    func testSpotCannotEnterPerpetualAnomalyStrategy() {
        var detector = AnomalyDetector(symbol: symbol, configuration: AlertConfiguration(enabled: true))
        let quote = PriceQuote(symbol: symbol, price: 90000, timestamp: minute,
                               session: .spot, source: .stream, tradeID: "1", sizeBase: 0.1)
        detector.ingestTrade(quote, receivedAt: minute)
        detector.ingestTicker(OKXTicker(quote: quote, reference: nil, bid: 89999, ask: 90001), receivedAt: minute)
        let value = detector.evaluate(at: minute)
        XCTAssertEqual(value.phase, .off)
        XCTAssertNil(value.alert)
    }

    private func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
}
