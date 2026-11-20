import Foundation
import TickerCore

final class YahooDecoderTests {
    private let nvdaFrame = "CgROVkRBFZqZDUMYsPPOj79oKgNOTVMwCDgARZ4GQMBl4CiMwNgBBPUC4CiMwP0CngZAwA=="

    func testObservedPremarketFrameAndJSONEnvelope() throws {
        let raw = try XCTUnwrap(YahooDecoder.stream(nvdaFrame))
        let wrapped = try XCTUnwrap(YahooDecoder.stream("{\"type\":\"pricing\",\"message\":\"\(nvdaFrame)\"}"))
        XCTAssertEqual(raw, wrapped)
        XCTAssertEqual(raw.symbol, "NVDA")
        XCTAssertEqual(raw.price, 141.6, accuracy: 0.001)
        XCTAssertEqual(raw.session, .pre)
        XCTAssertEqual(raw.source, .stream)
        XCTAssertEqual(raw.timestamp.timeIntervalSince1970, 1_795_178_487)
    }

    func testPremarketRegularAndPostmarketFlags() throws {
        for (flag, session) in [(UInt64(0), TradingSession.pre), (1, .regular), (2, .post), (3, .unknown), (12, .unknown)] {
            let quote = try XCTUnwrap(YahooDecoder.stream(frame(marketHours: flag)))
            XCTAssertEqual(quote.session, session)
            XCTAssertEqual(quote.timestamp.timeIntervalSince1970, 1_795_215_600)
        }
    }

    func testUnknownFieldsAreSkippedAndHeartbeatIgnored() throws {
        var data = Data(base64Encoded: frame(marketHours: 1))!
        data.append(contentsOf: varint(100 << 3 | 2) + varint(3) + [1, 2, 3])
        XCTAssertEqual(try YahooDecoder.stream(data.base64EncodedString())?.symbol, "AMD")
        XCTAssertNil(try YahooDecoder.stream("{\"type\":\"heartbeat\"}"))
        XCTAssertNil(try YahooDecoder.stream(""))
    }

    func testMalformedAndTruncatedFramesThrowWithoutTrapping() {
        let valid = Data(base64Encoded: frame(marketHours: 1))!
        for count in 1..<valid.count {
            // Truncation may produce a valid quote after all required fields;
            // the requirement here is graceful handling, never a bounds trap.
            _ = try? YahooDecoder.stream(valid.prefix(count).base64EncodedString())
        }
        for bytes in [[UInt8](repeating: 0xFF, count: 20), [0], [0x0A, 0xFF, 0xFF], [0x0A, 1, 0xFF], [0x0D, 0]] {
            XCTAssertThrowsError(try YahooDecoder.stream(Data(bytes).base64EncodedString()))
        }
        XCTAssertThrowsError(try YahooDecoder.stream("not base64!"))
        XCTAssertThrowsError(try YahooDecoder.stream("{\"type\":\"pricing\"}"))
        XCTAssertThrowsError(try YahooDecoder.stream(frame(marketHours: 1, price: .nan)))
        XCTAssertThrowsError(try YahooDecoder.stream(frame(marketHours: 1, price: -1)))
        XCTAssertThrowsError(try YahooDecoder.stream(frame(marketHours: 1, milliseconds: -1)))
    }

    func testSnapshotChoosesNewerPremarketBarOverYesterdayRegularQuote() throws {
        let snapshot = try YahooDecoder.chart(chart(
            regularTime: "2026-11-19T21:00:00Z", regularPrice: 100,
            dates: ["2026-11-20T12:30:00Z", "2026-11-20T12:31:00Z"], closes: [104, 105]
        ), expectedSymbol: "AMD")
        XCTAssertEqual(snapshot.quote.price, 105)
        XCTAssertEqual(snapshot.quote.session, .pre)
        XCTAssertEqual(snapshot.quote.changePercent!, 5, accuracy: 0.0001)
        XCTAssertEqual(snapshot.quote.source, .snapshot)
    }

    func testSnapshotChoosesPostmarketAndUsesRegularReference() throws {
        let snapshot = try YahooDecoder.chart(chart(
            regularTime: "2026-11-20T21:00:01Z", regularPrice: 110,
            dates: ["2026-11-20T21:01:00Z", "2026-11-20T23:59:00Z"], closes: [111, 121]
        ), expectedSymbol: "AMD")
        XCTAssertEqual(snapshot.quote.session, .post)
        XCTAssertEqual(snapshot.quote.price, 121)
        XCTAssertEqual(snapshot.quote.changePercent!, 10, accuracy: 0.0001)
        XCTAssertEqual(snapshot.regularClose, 110)
    }

    func testRegularMetadataNeverAcquiresCurrentExtendedSession() throws {
        let snapshot = try YahooDecoder.chart(chart(
            regularTime: "2026-11-20T21:00:01Z", regularPrice: 110,
            dates: ["2026-11-20T20:59:00Z", "2026-11-20T21:02:00Z"], closes: [109, NSNull()]
        ), expectedSymbol: "AMD")
        XCTAssertEqual(snapshot.quote.session, .regular)
        XCTAssertEqual(snapshot.quote.timestamp, date("2026-11-20T21:00:01Z"))
        XCTAssertEqual(snapshot.quote.price, 110)
    }

    func testSparseUnsortedBarsAndUnequalLengths() throws {
        let snapshot = try YahooDecoder.chart(chart(
            regularTime: "2026-11-19T21:00:00Z", regularPrice: 100,
            dates: ["2026-11-20T12:35:00Z", "2026-11-20T12:31:00Z", "2026-11-20T12:36:00Z", "2026-11-20T12:37:00Z"],
            closes: [105, 104, NSNull()]
        ), expectedSymbol: "AMD")
        XCTAssertEqual(snapshot.quote.price, 105)
        XCTAssertEqual(snapshot.quote.timestamp, date("2026-11-20T12:35:00Z"))
    }

    func testProviderTradingPeriodsHandleEarlyClose() throws {
        let periods: [String: Any] = [
            "pre": ["start": date("2026-11-27T09:00:00Z").timeIntervalSince1970, "end": date("2026-11-27T14:30:00Z").timeIntervalSince1970],
            "regular": ["start": date("2026-11-27T14:30:00Z").timeIntervalSince1970, "end": date("2026-11-27T18:00:00Z").timeIntervalSince1970],
            "post": ["start": date("2026-11-27T18:00:00Z").timeIntervalSince1970, "end": date("2026-11-27T22:00:00Z").timeIntervalSince1970]
        ]
        let snapshot = try YahooDecoder.chart(chart(
            regularTime: "2026-11-27T18:00:00Z", regularPrice: 100,
            dates: ["2026-11-27T19:00:00Z"], closes: [103], periods: periods
        ), expectedSymbol: "AMD")
        XCTAssertEqual(snapshot.quote.session, .post)
    }

    func testPriorEarlyCloseIsUnknownWhenOnlyNextDayScheduleExists() throws {
        let nextDay: [String: Any] = [
            "regular": ["start": date("2026-11-30T14:30:00Z").timeIntervalSince1970,
                        "end": date("2026-11-30T21:00:00Z").timeIntervalSince1970]
        ]
        let snapshot = try YahooDecoder.chart(chart(
            regularTime: "2026-11-27T18:00:00Z", regularPrice: 100,
            dates: ["2026-11-27T19:00:00Z"], closes: [103], periods: nextDay
        ), expectedSymbol: "AMD")
        XCTAssertEqual(snapshot.quote.session, .unknown)
        XCTAssertNil(snapshot.quote.changePercent)
    }

    func testNewYorkDSTAndExactBoundaries() {
        XCTAssertEqual(TradingSession.inferred(at: date("2026-07-20T13:29:59Z")), .pre)
        XCTAssertEqual(TradingSession.inferred(at: date("2026-07-20T13:30:00Z")), .regular)
        XCTAssertEqual(TradingSession.inferred(at: date("2026-11-20T14:29:59Z")), .pre)
        XCTAssertEqual(TradingSession.inferred(at: date("2026-11-20T14:30:00Z")), .regular)
        XCTAssertEqual(TradingSession.inferred(at: date("2026-11-20T21:00:00Z")), .post)
        XCTAssertEqual(TradingSession.inferred(at: date("2026-11-21T01:00:00Z")), .closed)
        XCTAssertEqual(TradingSession.inferred(at: date("2026-11-21T15:30:00Z")), .closed)
    }

    func testInvalidChartAndSymbolMismatchFailClosed() throws {
        let data = try chart(regularTime: "2026-11-20T20:00:00Z", regularPrice: 100, dates: [], closes: [])
        XCTAssertThrowsError(try YahooDecoder.chart(data, expectedSymbol: "NVDA"))
        XCTAssertThrowsError(try YahooDecoder.chart(Data("{\"chart\":{\"result\":null,\"error\":{\"description\":\"Not Found\"}}}".utf8), expectedSymbol: "AMD"))
        XCTAssertThrowsError(try YahooDecoder.chart(Data("{}".utf8), expectedSymbol: "AMD"))
        let invalid = try chart(regularTime: "1900-01-01T00:00:00Z", regularPrice: 100, dates: [], closes: [])
        XCTAssertThrowsError(try YahooDecoder.chart(invalid, expectedSymbol: "AMD"))
    }

    private func chart(regularTime: String, regularPrice: Double, dates: [String], closes: [Any], periods: [String: Any] = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["chart": ["result": [[
            "meta": ["symbol": "AMD", "previousClose": 100, "regularMarketPrice": regularPrice,
                     "regularMarketTime": date(regularTime).timeIntervalSince1970, "currentTradingPeriod": periods],
            "timestamp": dates.map { date($0).timeIntervalSince1970 },
            "indicators": ["quote": [["close": closes]]]
        ]], "error": NSNull()]])
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func frame(marketHours: UInt64, price: Float = 150, milliseconds: Int64 = 1_795_215_600_000) -> String {
        let bits = price.bitPattern
        var bytes: [UInt8] = [0x0A, 3, 65, 77, 68, 0x15,
                             UInt8(truncatingIfNeeded: bits), UInt8(truncatingIfNeeded: bits >> 8),
                             UInt8(truncatingIfNeeded: bits >> 16), UInt8(truncatingIfNeeded: bits >> 24), 0x18]
        bytes += varint(UInt64(bitPattern: (milliseconds << 1) ^ (milliseconds >> 63)))
        bytes += [0x38] + varint(marketHours)
        return Data(bytes).base64EncodedString()
    }

    private func varint(_ value: UInt64) -> [UInt8] {
        var remaining = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while remaining != 0
        return bytes
    }
}

final class WatchlistTests {
    func testNormalizesAliasesAndDeduplicatesInOrder() throws {
        XCTAssertEqual(try Watchlist.parse("amd, NVIDIA， nvda\nBRK-B; amD"), ["AMD", "NVDA", "BRK-B"])
    }

    func testRejectsEmptyInvalidAndOversizedLists() {
        for value in ["", " , ; ", "1AMD", "AMD/NVDA", "AMD<script>", "A B C D E F G H I J K L M", "ABCDEFGHIJKLM"] {
            XCTAssertThrowsError(try Watchlist.parse(value), value)
        }
    }
}
