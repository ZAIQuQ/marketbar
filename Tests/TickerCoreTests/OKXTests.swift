import Foundation
import TickerCore

final class OKXTests {
    private let symbol = "SOXL-USDT-SWAP"
    private let minute = Date(timeIntervalSince1970: 1_795_220_760)

    func testPerpetualWatchlistAliasesDoNotChangeEquityMeaning() throws {
        XCTAssertEqual(try Watchlist.parse("SOXL,soxlusdt,SOXL-USDT-SWAP,btc-usdt-swap,nvidia"),
                       ["SOXL", "SOXL-USDT-SWAP", "BTC-USDT-SWAP", "NVDA"])
        XCTAssertEqual(try Watchlist.parse("AMD,NVDA"), ["AMD", "NVDA"])
        let maximum = String(repeating: "A", count: 22) + "-USDT-SWAP"
        XCTAssertEqual(try Watchlist.parse(maximum), [maximum])
        for bad in [String(repeating: "A", count: 23) + "-USDT-SWAP", "SOXL-USDT", "SOXL-USD-SWAP", "SOXL--USDT-SWAP"] {
            XCTAssertThrowsError(try Watchlist.parse(bad))
        }
    }

    func testPerpetualDisplayCurrencyAndUTCPartition() {
        XCTAssertEqual(Instrument.isOKX(symbol), true)
        XCTAssertEqual(Instrument.isOKX("SOXL"), false)
        XCTAssertEqual(Instrument.displaySymbol(symbol), "SOXLUSDT")
        XCTAssertEqual(Instrument.displaySymbol("SOXL"), "SOXL")
        XCTAssertEqual(Instrument.currency(symbol), "USDT")
        XCTAssertEqual(Instrument.currency("SOXL"), "USD")
        XCTAssertEqual(Instrument.day(symbol, at: minute), "2026-11-21")
        XCTAssertEqual(Instrument.day("SOXL", at: minute), "2026-11-20")
        XCTAssertEqual(Instrument.timeZone(symbol).secondsFromGMT(for: minute), 0)
        XCTAssertEqual(TradingSession.perpetual.label, "永续")
    }

    func testObservedTickerHasMessageTimestampAndUTCOpenReference() throws {
        let raw = try json(["code": "0", "data": [tickerRow()]])
        let ticker = try XCTUnwrap(OKXDecoder.ticker(raw, expectedSymbol: symbol))
        XCTAssertEqual(ticker.quote.price, 32.9)
        XCTAssertEqual(ticker.quote.timestamp.timeIntervalSince1970, 1_795_220_761.271, accuracy: 0.0001)
        XCTAssertEqual(ticker.quote.session, .perpetual)
        XCTAssertEqual(ticker.quote.recordsPriceSample, false)
        XCTAssertEqual(try XCTUnwrap(ticker.quote.changePercent), -25.750394944707743, accuracy: 0.000001)
        XCTAssertEqual(ticker.reference?.previousClose, 33.1)
        XCTAssertEqual(ticker.reference?.basis, .utcOpen)
        XCTAssertEqual(ticker.reference?.day, "2026-11-21")
        let snapshot = try XCTUnwrap(OKXDecoder.ticker(raw, expectedSymbol: symbol, source: .snapshot))
        XCTAssertEqual(snapshot.quote.source, .snapshot)
        XCTAssertEqual(snapshot.quote.recordsPriceSample, false)
    }

    func testBidAskTickerUpdatesNeverGeneratePriceSamples() throws {
        let first = try XCTUnwrap(OKXDecoder.ticker(json([
            "arg": ["channel": "tickers", "instId": symbol], "data": [tickerRow()]
        ]), expectedSymbol: symbol))
        var changed = tickerRow()
        changed["ts"] = "1795220765000"
        changed["bidPx"] = "32.89"
        let second = try XCTUnwrap(OKXDecoder.ticker(json([
            "arg": ["channel": "tickers", "instId": symbol], "data": [changed]
        ]), expectedSymbol: symbol))
        var book = CandleBook()
        book.ingest(first.quote, receivedAt: minute.addingTimeInterval(2))
        book.ingest(second.quote, receivedAt: minute.addingTimeInterval(6))
        XCTAssertEqual(book.candles.count, 0)
        XCTAssertEqual(first.quote.price, second.quote.price)
        XCTAssertEqual(second.quote.timestamp, minute.addingTimeInterval(5))
    }

    func testTickerRejectsProviderErrorsAndWrongInstrument() throws {
        XCTAssertThrowsError(try OKXDecoder.ticker(json(["code": "51001", "data": []]), expectedSymbol: symbol))
        XCTAssertThrowsError(try OKXDecoder.ticker(json(["event": "error", "code": "60018"]), expectedSymbol: symbol))
        let replacements: [[String: Any]] = [
            ["instId": "SOXL-USDT"], ["instType": "SPOT"], ["last": "NaN"],
            ["last": ""], ["last": -1], ["last": true], ["ts": "bad"], ["ts": "123"]
        ]
        for replacement in replacements {
            let row = tickerRow().merging(replacement) { _, new in new }
            XCTAssertThrowsError(try OKXDecoder.ticker(json(["code": "0", "data": [row]]), expectedSymbol: symbol))
        }
        var missingID = tickerRow()
        missingID.removeValue(forKey: "instId")
        XCTAssertThrowsError(try OKXDecoder.ticker(json(["code": "0", "data": [missingID]]), expectedSymbol: symbol))
        XCTAssertThrowsError(try OKXDecoder.ticker(json([
            "arg": ["channel": "tickers", "instId": "BTC-USDT-SWAP"], "data": [tickerRow()]
        ]), expectedSymbol: symbol))
        XCTAssertNil(try OKXDecoder.ticker(json([
            "event": "subscribe", "arg": ["channel": "tickers", "instId": symbol]
        ]), expectedSymbol: symbol))
    }

    func testTradesUseExecutionTimeAndCreateLocalSamples() throws {
        let raw = try json(["arg": ["channel": "trades", "instId": symbol], "data": [
            ["instId": symbol, "px": "32.9", "ts": "1795220765000", "sz": "2"],
            ["instId": symbol, "px": "32.8", "ts": "1795220761000", "sz": "3"]
        ]])
        let quotes = try OKXDecoder.trades(raw, expectedSymbol: symbol)
        XCTAssertEqual(quotes.map(\.price), [32.8, 32.9])
        XCTAssertEqual(quotes.map(\.recordsPriceSample), [true, true])
        var book = CandleBook()
        for quote in quotes { book.ingest(quote, receivedAt: minute.addingTimeInterval(6)) }
        let candle = try XCTUnwrap(book.candles.first)
        XCTAssertEqual(candle.open, 32.8)
        XCTAssertEqual(candle.close, 32.9)
        XCTAssertEqual(candle.sampleCount, 2)
        XCTAssertEqual(candle.origin, .localSample)
        XCTAssertEqual(candle.session, .perpetual)
        XCTAssertEqual(candle.isFinal, false)
        XCTAssertNil(candle.volume)
        XCTAssertThrowsError(try OKXDecoder.trades(json([
            "arg": ["channel": "trades", "instId": symbol],
            "data": [["instId": "SOXL-USDT", "px": "33", "ts": "1795220765000"]]
        ]), expectedSymbol: symbol))
    }

    func testCandlesDecodeConfirmationAndSkipInvalidRows() throws {
        let rows: [[Any]] = [
            ["1795220760000", "32.89", "32.9", "32.89", "32.9", "126.22", "126.22", "4151.3763", "0"],
            ["1795220700000", "32", "33", "31", "32.5", "100", "100", "3250", "1"],
            ["1795220640000", "32", "30", "31", "32.5", "100", "100", "3250", "1"],
            ["1795220580000", "32", "33", "31", "32.5", "100", "100", "3250", "2"],
            ["1795220521000", "32", "33", "31", "32.5", "100", "100", "3250", "1"]
        ]
        let bars = try OKXDecoder.candles(json(["code": "0", "data": rows]), expectedSymbol: symbol,
                                         receivedAt: minute.addingTimeInterval(2))
        XCTAssertEqual(bars.count, 2)
        XCTAssertEqual(bars.map(\.isFinal), [true, false])
        XCTAssertEqual(bars.map(\.origin), [.okx, .okx])
        XCTAssertEqual(bars.map(\.session), [.perpetual, .perpetual])
        XCTAssertEqual(bars[1].close, 32.9)
        XCTAssertNil(bars[0].volume)
        XCTAssertNil(bars[1].volume)
        XCTAssertThrowsError(try OKXDecoder.candles(json(["code": "51000", "data": []]), expectedSymbol: symbol))
        XCTAssertThrowsError(try OKXDecoder.candles(json(["code": "0", "data": rows]), expectedSymbol: "SOXL"))
    }

    func testOKXFinalFlagControlsCompletionAndLaterPartialCannotReopen() throws {
        var book = CandleBook()
        // An old-looking but explicitly unconfirmed minute stays provisional.
        book.mergeRemote([candle(close: 32.5, observed: 70, final: false)])
        book.ingest(PriceQuote(symbol: symbol, price: 34, timestamp: minute.addingTimeInterval(50),
                              session: .perpetual, source: .stream), receivedAt: minute.addingTimeInterval(75))
        XCTAssertEqual(book.candles.first?.close, 34)
        XCTAssertEqual(book.candles.first?.origin, .mixed)
        XCTAssertEqual(book.candles.first?.isFinal, false)
        book.mergeRemote([candle(close: 33, observed: 80, final: true)])
        XCTAssertEqual(book.candles.first?.close, 33)
        XCTAssertEqual(book.candles.first?.origin, .okx)
        XCTAssertEqual(book.candles.first?.isFinal, true)
        book.mergeRemote([candle(close: 32, observed: 90, final: false)])
        XCTAssertEqual(book.candles.first?.close, 33)
        var restored = CandleBook()
        restored.restore(try JSONDecoder().decode([MinuteCandle].self, from: JSONEncoder().encode(book.candles)))
        restored.ingest(PriceQuote(symbol: symbol, price: 35, timestamp: minute.addingTimeInterval(55),
                                  session: .perpetual, source: .stream), receivedAt: minute.addingTimeInterval(91))
        XCTAssertEqual(restored.candles.first?.close, 33)
    }

    func testOKXCurrentMinuteUpsertsAndOlderResponseIsIgnored() {
        var book = CandleBook()
        book.mergeRemote([candle(close: 32.5, observed: 20, final: false)])
        book.mergeRemote([candle(close: 33, observed: 30, final: false)])
        book.mergeRemote([candle(close: 32, observed: 25, final: false)])
        XCTAssertEqual(book.candles.first?.close, 33)
        XCTAssertEqual(book.candles.first?.isFinal, false)
    }

    func testLegacyReferenceAndCandleJSONStillDecode() throws {
        let legacy = try JSONDecoder().decode(ChartReference.self,
            from: Data("{\"day\":\"2026-11-20\",\"previousClose\":100}".utf8))
        XCTAssertEqual(legacy.basis, .previousClose)
        let utc = ChartReference(day: "2026-11-21", previousClose: 33.1, basis: .utcOpen)
        XCTAssertEqual(try JSONDecoder().decode(ChartReference.self, from: JSONEncoder().encode(utc)), utc)
        let stock = MinuteCandle(symbol: "AMD", minute: minute, open: 100, high: 101, low: 99, close: 100,
                                 volume: 1, session: .post, origin: .yahoo, firstEvent: minute,
                                 lastEvent: minute, observedAt: minute, sampleCount: 0)
        let encoded = try JSONEncoder().encode(stock)
        let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        XCTAssertNil(object["isFinal"])
        XCTAssertNil(try JSONDecoder().decode(MinuteCandle.self, from: encoded).isFinal)
        XCTAssertEqual(PriceQuote(symbol: "AMD", price: 100, timestamp: minute, session: .post,
                                  source: .stream).recordsPriceSample, true)
    }

    private func tickerRow() -> [String: Any] {
        ["instType": "SWAP", "instId": symbol, "last": "32.9", "open24h": "44.31",
         "ts": "1795220761271", "sodUtc0": "33.1", "sodUtc8": "36.53"]
    }

    private func candle(close: Double, observed: TimeInterval, final: Bool) -> MinuteCandle {
        MinuteCandle(symbol: symbol, minute: minute, open: 32, high: 34, low: 31, close: close,
                     volume: nil, session: .perpetual, origin: .okx,
                     firstEvent: minute, lastEvent: minute, observedAt: minute.addingTimeInterval(observed),
                     sampleCount: 0, isFinal: final)
    }

    private func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
}
