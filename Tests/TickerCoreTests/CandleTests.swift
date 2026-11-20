import Foundation
import TickerCore

final class CandleTests {
    private let start = ISO8601DateFormatter().date(from: "2026-11-20T13:00:00Z")!

    func testChartKeepsGapsAndSkipsMalformedOHLC() throws {
        let data = try chart(seconds: [0, 60, 120, 180, 240], opens: [100, NSNull(), 100, 100, 100],
                             highs: [102, 102, 99, 104, true], lows: [99, 99, 99, 99, 99],
                             closes: [101, 101, 101, 103, 101], volumes: [10, 20, 30, NSNull(), 50])
        let rows = try CandleDecoder.chart(data, expectedSymbol: "AMD", receivedAt: start.addingTimeInterval(300))
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.minute), [start, start.addingTimeInterval(180)])
        XCTAssertEqual(rows[0].volume, 10)
        XCTAssertNil(rows[1].volume)
        XCTAssertEqual(rows[0].sampleCount, 0)
        XCTAssertEqual(rows[0].origin, .yahoo)
    }

    func testDuplicateCurrentMinuteAggregatesWithoutDoubleVolume() throws {
        let data = try chart(seconds: [40, 0], opens: [103, 100], highs: [106, 105],
                             lows: [102, 99], closes: [106, 104], volumes: [0, 100])
        let row = try XCTUnwrap(CandleDecoder.chart(data, expectedSymbol: "AMD", receivedAt: start.addingTimeInterval(45)).first)
        XCTAssertEqual(row.minute, start)
        XCTAssertEqual(row.open, 100)
        XCTAssertEqual(row.high, 106)
        XCTAssertEqual(row.low, 99)
        XCTAssertEqual(row.close, 106)
        XCTAssertEqual(row.volume, 100)
        XCTAssertEqual(row.firstEvent, start)
        XCTAssertEqual(row.lastEvent, start.addingTimeInterval(40))
    }

    func testChartRejectsWrongCurrencySymbolAndGranularity() throws {
        let standard = try chart(seconds: [0], opens: [100], highs: [101], lows: [99], closes: [100])
        XCTAssertThrowsError(try CandleDecoder.chart(standard, expectedSymbol: "NVDA"))
        let foreign = try chart(seconds: [0], opens: [100], highs: [101], lows: [99], closes: [100], currency: "EUR")
        XCTAssertThrowsError(try CandleDecoder.chart(foreign, expectedSymbol: "AMD"))
        let daily = try chart(seconds: [0], opens: [100], highs: [101], lows: [99], closes: [100], granularity: "1d")
        XCTAssertThrowsError(try CandleDecoder.chart(daily, expectedSymbol: "AMD"))
        XCTAssertThrowsError(try CandleDecoder.chart(Data("{}".utf8), expectedSymbol: "AMD"))
        let absentVolume = try CandleDecoder.chart(standard, expectedSymbol: "AMD")
        XCTAssertNil(absentVolume.first?.volume)
    }

    func testSessionBoundariesAndDST() throws {
        for day in ["2026-11-20", "2026-07-20"] {
            let winter = day.contains("11-20")
            let open = date("\(day)T\(winter ? "14" : "13"):30:00Z")
            let end = date("\(day)T\(winter ? "21" : "20"):00:00Z")
            let pre = date("\(day)T\(winter ? "09" : "08"):00:00Z")
            let periods: [String: Any] = [
                "pre": ["start": pre.timeIntervalSince1970, "end": open.timeIntervalSince1970],
                "regular": ["start": open.timeIntervalSince1970, "end": end.timeIntervalSince1970],
                "post": ["start": end.timeIntervalSince1970, "end": end.addingTimeInterval(14400).timeIntervalSince1970]
            ]
            let times = [open.addingTimeInterval(-1), open, end]
            let data = try chart(seconds: times.map { $0.timeIntervalSince(start) }, opens: [100, 100, 100],
                                 highs: [101, 101, 101], lows: [99, 99, 99], closes: [100, 100, 100], periods: periods)
            let rows = try CandleDecoder.chart(data, expectedSymbol: "AMD", receivedAt: end.addingTimeInterval(60))
            XCTAssertEqual(rows.map(\.session), [.pre, .regular, .post])
        }
    }

    func testPriorDayPremarketAndEarlyCloseUncertainty() throws {
        let futurePeriods: [String: Any] = ["regular": [
            "start": date("2026-11-30T14:30:00Z").timeIntervalSince1970,
            "end": date("2026-11-30T21:00:00Z").timeIntervalSince1970]]
        let dates = [date("2026-11-27T13:00:00Z"), date("2026-11-27T19:00:00Z")]
        let data = try chart(seconds: dates.map { $0.timeIntervalSince(start) }, opens: [100, 100], highs: [101, 101],
                             lows: [99, 99], closes: [100, 100], periods: futurePeriods)
        XCTAssertEqual(try CandleDecoder.chart(data, expectedSymbol: "AMD", receivedAt: dates.last!.addingTimeInterval(60)).map(\.session), [.pre, .unknown])
    }

    func testLocalSamplesPreserveEventOrderAndIgnoreSnapshots() throws {
        var book = CandleBook()
        book.ingest(quote(20, 100), receivedAt: start.addingTimeInterval(21))
        book.ingest(quote(10, 103), receivedAt: start.addingTimeInterval(22))
        book.ingest(quote(30, 99), receivedAt: start.addingTimeInterval(31))
        book.ingest(quote(40, 500, source: .snapshot), receivedAt: start.addingTimeInterval(41))
        let row = try XCTUnwrap(book.candles.first)
        XCTAssertEqual(row.open, 103)
        XCTAssertEqual(row.high, 103)
        XCTAssertEqual(row.low, 99)
        XCTAssertEqual(row.close, 99)
        XCTAssertEqual(row.sampleCount, 3)
        XCTAssertEqual(row.origin, .localSample)
        XCTAssertNil(row.volume)
        XCTAssertEqual(row.firstEvent, start.addingTimeInterval(10))
        XCTAssertEqual(row.lastEvent, start.addingTimeInterval(30))
    }

    func testRemoteLocalPrecedenceAndOldRefreshRejected() throws {
        var book = CandleBook()
        book.ingest(quote(10, 101), receivedAt: start.addingTimeInterval(11))
        book.ingest(quote(30, 105), receivedAt: start.addingTimeInterval(31))
        book.mergeRemote([candle(observed: 20)])
        let merged = try XCTUnwrap(book.candles.first)
        XCTAssertEqual(merged.open, 100)
        XCTAssertEqual(merged.high, 105)
        XCTAssertEqual(merged.low, 99)
        XCTAssertEqual(merged.close, 105)
        XCTAssertEqual(merged.origin, .mixed)
        XCTAssertEqual(merged.sampleCount, 2)
        XCTAssertNil(merged.volume)
        book.mergeRemote([candle(high: 104, close: 103, observed: 80)])
        book.mergeRemote([candle(high: 999, close: 999, observed: 15)])
        let refreshed = try XCTUnwrap(book.candles.first)
        XCTAssertEqual(refreshed.high, 104)
        XCTAssertEqual(refreshed.close, 103)
        XCTAssertEqual(refreshed.origin, .yahoo)
        XCTAssertEqual(refreshed.volume, 100)
    }

    func testPartialRemoteCannotEraseExistingMinuteExtremes() throws {
        var book = CandleBook()
        book.mergeRemote([candle(high: 110, low: 90, observed: 20)])
        book.mergeRemote([candle(open: 103, high: 103, low: 103, close: 103,
                                 volume: 0, first: 35, last: 35, observed: 36)])
        let row = try XCTUnwrap(book.candles.first)
        XCTAssertEqual(row.open, 100)
        XCTAssertEqual(row.high, 110)
        XCTAssertEqual(row.low, 90)
        XCTAssertEqual(row.close, 103)
        XCTAssertEqual(row.volume, 100)
    }

    func testRestoreValidatesAndPreservesLiveSamplesAndMixedProvenance() throws {
        var book = CandleBook()
        book.ingest(quote(40, 108), receivedAt: start.addingTimeInterval(41))
        let cached = candle(open: 100, high: 106, low: 99, close: 105, volume: nil,
                            origin: .mixed, first: 0, last: 30, observed: 31, sampleCount: 3)
        let invalid = candle(high: 80, observed: 42)
        book.restore([cached, invalid])
        let row = try XCTUnwrap(book.candles.first)
        XCTAssertEqual(book.candles.count, 1)
        XCTAssertEqual(row.high, 108)
        XCTAssertEqual(row.low, 99)
        XCTAssertEqual(row.close, 108)
        XCTAssertEqual(row.origin, .mixed)
        XCTAssertEqual(row.sampleCount, 4)
        let saved = try JSONDecoder().decode([MinuteCandle].self, from: JSONEncoder().encode(book.candles))
        var restored = CandleBook()
        restored.restore(saved)
        XCTAssertEqual(restored.candles, book.candles)
        restored.mergeRemote([candle(high: 109, close: 104, observed: 80)])
        XCTAssertEqual(restored.candles.first?.origin, .yahoo)
        XCTAssertEqual(restored.candles.first?.close, 104)
    }

    func testRestoredLocalSamplesCombineWithoutInventingVolume() throws {
        var book = CandleBook()
        book.ingest(quote(40, 108), receivedAt: start.addingTimeInterval(41))
        book.restore([candle(open: 103, high: 105, low: 102, close: 104, volume: nil,
                             origin: .localSample, first: 10, last: 30, observed: 31, sampleCount: 2)])
        let row = try XCTUnwrap(book.candles.first)
        XCTAssertEqual(row.open, 103)
        XCTAssertEqual(row.high, 108)
        XCTAssertEqual(row.low, 102)
        XCTAssertEqual(row.close, 108)
        XCTAssertEqual(row.sampleCount, 3)
        XCTAssertNil(row.volume)
        book.mergeRemote([candle(observed: 20)])
        // The still-open remote minute has no later explicit source timestamp;
        // known local samples retain their observed range until a full refresh.
        XCTAssertEqual(book.candles.first?.high, 108)
        XCTAssertEqual(book.candles.first?.open, 100)
    }

    func testCompletedMinuteRetainsOHLCWhenLateEventsArrive() throws {
        var book = CandleBook()
        book.ingest(quote(10, 100), receivedAt: start.addingTimeInterval(11))
        book.ingest(quote(30, 110), receivedAt: start.addingTimeInterval(31))
        book.ingest(quote(50, 105), receivedAt: start.addingTimeInterval(51))
        book.ingest(quote(65, 200), receivedAt: start.addingTimeInterval(66))
        book.ingest(quote(20, 99), receivedAt: start.addingTimeInterval(67))
        let previous = try XCTUnwrap(book.candles.first)
        XCTAssertEqual(book.candles.count, 2)
        XCTAssertEqual(previous.open, 100)
        XCTAssertEqual(previous.high, 110)
        XCTAssertEqual(previous.low, 99)
        XCTAssertEqual(previous.close, 105)
        XCTAssertEqual(previous.sampleCount, 4)
        book.mergeRemote([candle(high: 107, low: 98, close: 106, observed: 80)])
        XCTAssertEqual(book.candles.first?.origin, .yahoo)
        XCTAssertEqual(book.candles.first?.high, 107)
        XCTAssertEqual(book.candles.first?.sampleCount, 0)
    }

    func testFutureRemoteBarsAreSkipped() throws {
        let data = try chart(seconds: [0, 120], opens: [100, 100], highs: [101, 101],
                             lows: [99, 99], closes: [100, 100])
        let rows = try CandleDecoder.chart(data, expectedSymbol: "AMD", receivedAt: start.addingTimeInterval(10))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.minute, start)
    }

    func testLaterHTTPResponseDoesNotRewindNewerLocalEvent() throws {
        var book = CandleBook()
        book.ingest(quote(40, 105), receivedAt: start.addingTimeInterval(41))
        book.mergeRemote([candle(open: 103, high: 103, low: 103, close: 103,
                                 volume: 0, first: 35, last: 35, observed: 45)])
        let row = try XCTUnwrap(book.candles.first)
        XCTAssertEqual(row.close, 105)
        XCTAssertEqual(row.lastEvent, start.addingTimeInterval(40))
        XCTAssertEqual(row.origin, .mixed)
        XCTAssertNil(row.volume)
        // A true complete minute may subsequently correct its authoritative OHLC.
        book.mergeRemote([candle(high: 104, close: 104, observed: 80)])
        XCTAssertEqual(book.candles.first?.close, 104)
        XCTAssertEqual(book.candles.first?.origin, .yahoo)
    }

    func testOlderPartialSourceTimeCannotReplaceNewerPartial() throws {
        var book = CandleBook()
        book.mergeRemote([candle(open: 105, high: 105, low: 105, close: 105,
                                 volume: 0, first: 40, last: 40, observed: 41)])
        book.mergeRemote([candle(open: 103, high: 103, low: 103, close: 103,
                                 volume: 0, first: 35, last: 35, observed: 45)])
        XCTAssertEqual(book.candles.first?.open, 103)
        XCTAssertEqual(book.candles.first?.close, 105)
        XCTAssertEqual(book.candles.first?.lastEvent, start.addingTimeInterval(40))
        // A minute-aligned but still-open bar also lacks proof of coverage past :40.
        book.mergeRemote([candle(high: 104, close: 103, observed: 50)])
        XCTAssertEqual(book.candles.first?.close, 105)
        XCTAssertEqual(book.candles.first?.open, 100)
    }

    func testLatePartialCannotReopenCompletedMinuteOrClaimCompletion() throws {
        var complete = CandleBook()
        complete.mergeRemote([candle(high: 108, close: 107, observed: 80)])
        complete.mergeRemote([candle(open: 103, high: 103, low: 103, close: 103,
                                     volume: 0, first: 35, last: 35, observed: 90)])
        XCTAssertEqual(complete.candles.first?.close, 107)
        var partial = CandleBook()
        partial.mergeRemote([candle(observed: 20)])
        partial.mergeRemote([candle(open: 103, high: 103, low: 103, close: 103,
                                    volume: 0, first: 35, last: 35, observed: 75)])
        let archive = try JSONEncoder().encode(partial.candles)
        var restored = CandleBook()
        restored.restore(try JSONDecoder().decode([MinuteCandle].self, from: archive))
        restored.ingest(quote(40, 105), receivedAt: start.addingTimeInterval(76))
        XCTAssertEqual(restored.candles.first?.close, 105)
        XCTAssertEqual(restored.candles.first?.origin, .mixed)
        partial.ingest(quote(40, 105), receivedAt: start.addingTimeInterval(76))
        XCTAssertEqual(partial.candles.first?.close, 105)
        XCTAssertEqual(partial.candles.first?.origin, .mixed)
    }

    private func chart(seconds: [TimeInterval], opens: [Any], highs: [Any], lows: [Any], closes: [Any],
                       volumes: [Any] = [], currency: String = "USD", granularity: String = "1m",
                       periods: [String: Any] = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["chart": ["error": NSNull(), "result": [[
            "meta": ["symbol": "AMD", "currency": currency, "dataGranularity": granularity, "currentTradingPeriod": periods],
            "timestamp": seconds.map { start.addingTimeInterval($0).timeIntervalSince1970 },
            "indicators": ["quote": [["open": opens, "high": highs, "low": lows, "close": closes, "volume": volumes]]]
        ]]]])
    }

    private func candle(open: Double = 100, high: Double = 102, low: Double = 99, close: Double = 101,
                        volume: Double? = 100, origin: CandleOrigin = .yahoo,
                        first: TimeInterval = 0, last: TimeInterval = 0,
                        observed: TimeInterval = 20, sampleCount: Int = 0) -> MinuteCandle {
        MinuteCandle(symbol: "AMD", minute: start, open: open, high: high, low: low, close: close,
                     volume: volume, session: .pre, origin: origin,
                     firstEvent: start.addingTimeInterval(first), lastEvent: start.addingTimeInterval(last),
                     observedAt: start.addingTimeInterval(observed), sampleCount: sampleCount)
    }

    private func quote(_ second: TimeInterval, _ price: Double, source: QuoteSource = .stream) -> PriceQuote {
        PriceQuote(symbol: "AMD", price: price, timestamp: start.addingTimeInterval(second), session: .pre, source: source)
    }

    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
}
