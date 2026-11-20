import Foundation
import TickerCore

final class ChartReferenceTests {
    func testPremarketUsesYesterdayRegularPriceInsteadOfOlderPreviousClose() throws {
        let data = try chart(latest: "2026-11-20T13:00:00Z", regularTime: "2026-11-19T21:00:01Z",
                             regularPrice: 489.19, previous: 530.14)
        let reference = try XCTUnwrap(ChartReferenceDecoder.chart(data, expectedSymbol: "AMD"))
        XCTAssertEqual(reference.day, "2026-11-20")
        XCTAssertEqual(reference.previousClose, 489.19)
        XCTAssertEqual(reference.percentChange(at: 489.19), 0)
    }

    func testRegularAndPostmarketUseSameDayPriorClose() throws {
        for latest in ["2026-11-20T16:30:00Z", "2026-11-21T00:30:00Z"] {
            let data = try chart(latest: latest, regularTime: "2026-11-20T16:00:00Z",
                                 regularPrice: 510, previous: 489.19)
            let reference = try XCTUnwrap(ChartReferenceDecoder.chart(data, expectedSymbol: "AMD"))
            XCTAssertEqual(reference.day, "2026-11-20")
            XCTAssertEqual(reference.previousClose, 489.19)
        }
        let fallback = try chart(latest: "2026-11-20T16:30:00Z", regularTime: "2026-11-20T16:00:00Z",
                                 regularPrice: 510, previous: NSNull(), chartPrevious: 489.19)
        XCTAssertEqual(try ChartReferenceDecoder.chart(fallback, expectedSymbol: "AMD")?.previousClose, 489.19)
    }

    func testMismatchedDaysAndLongRangeHaveNoReference() throws {
        let oldChart = try chart(latest: "2026-11-19T23:00:00Z", regularTime: "2026-11-19T21:00:00Z",
                                 regularPrice: 489.19, previous: 530.14)
        XCTAssertNil(try ChartReferenceDecoder.chart(oldChart, expectedSymbol: "AMD"))
        let futureRegular = try chart(latest: "2026-11-20T13:00:00Z", regularTime: "2026-11-23T15:00:00Z",
                                      regularPrice: 489.19, previous: 530.14)
        XCTAssertNil(try ChartReferenceDecoder.chart(futureRegular, expectedSymbol: "AMD"))
        let longRange = try chart(latest: "2026-11-20T16:30:00Z", regularTime: "2026-11-20T16:00:00Z",
                                  regularPrice: 510, previous: 489.19, range: "5d")
        XCTAssertNil(try ChartReferenceDecoder.chart(longRange, expectedSymbol: "AMD"))
    }

    func testMissingBaselineInvalidPriceCurrencyAndSymbol() throws {
        let missing = try chart(latest: "2026-11-20T13:00:00Z", regularTime: "2026-11-19T21:00:00Z",
                                regularPrice: NSNull(), previous: 530.14)
        XCTAssertNil(try ChartReferenceDecoder.chart(missing, expectedSymbol: "AMD"))
        let invalid = try chart(latest: "2026-11-20T16:30:00Z", regularTime: "2026-11-20T16:00:00Z",
                                regularPrice: 510, previous: true, chartPrevious: -1)
        XCTAssertNil(try ChartReferenceDecoder.chart(invalid, expectedSymbol: "AMD"))
        let foreign = try chart(latest: "2026-11-20T13:00:00Z", regularTime: "2026-11-19T21:00:00Z",
                                regularPrice: 489.19, previous: 530.14, currency: "EUR")
        XCTAssertThrowsError(try ChartReferenceDecoder.chart(foreign, expectedSymbol: "AMD"))
        XCTAssertThrowsError(try ChartReferenceDecoder.chart(missing, expectedSymbol: "NVDA"))
        XCTAssertThrowsError(try ChartReferenceDecoder.chart(Data("{}".utf8), expectedSymbol: "AMD"))
    }

    func testNullFutureBarCannotSelectWrongTradingDay() throws {
        let standard = try chart(latest: "2026-11-20T13:00:00Z", regularTime: "2026-11-19T21:00:00Z",
                                 regularPrice: 489.19, previous: 530.14)
        var root = try JSONSerialization.jsonObject(with: standard) as! [String: Any]
        var chart = root["chart"] as! [String: Any]
        var result = (chart["result"] as! [[String: Any]])[0]
        result["timestamp"] = [date("2026-11-20T13:00:00Z"), date("2026-11-23T13:00:00Z")]
        result["indicators"] = ["quote": [["close": [100, NSNull()]]]]
        chart["result"] = [result]
        root["chart"] = chart
        let reference = try ChartReferenceDecoder.chart(JSONSerialization.data(withJSONObject: root), expectedSymbol: "AMD")
        XCTAssertEqual(reference?.day, "2026-11-20")
    }

    func testPercentChangeAndCodable() throws {
        let reference = ChartReference(day: "2026-11-20", previousClose: 100)
        XCTAssertEqual(try XCTUnwrap(reference.percentChange(at: 110)), 10, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(reference.percentChange(at: 90)), -10, accuracy: 0.000001)
        XCTAssertNil(reference.percentChange(at: .nan))
        XCTAssertNil(reference.percentChange(at: -1))
        XCTAssertNil(ChartReference(day: "2026-11-20", previousClose: 0).percentChange(at: 100))
        XCTAssertEqual(try JSONDecoder().decode(ChartReference.self, from: JSONEncoder().encode(reference)), reference)
    }

    private func chart(latest: String, regularTime: String, regularPrice: Any, previous: Any,
                       chartPrevious: Any = NSNull(), range: String = "1d", currency: String = "USD") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["chart": ["error": NSNull(), "result": [[
            "meta": ["symbol": "AMD", "currency": currency, "range": range,
                     "regularMarketTime": date(regularTime), "regularMarketPrice": regularPrice,
                     "previousClose": previous, "chartPreviousClose": chartPrevious,
                     "currentTradingPeriod": [
                        "pre": ["start": date("2026-11-20T09:00:00Z")],
                        "regular": ["start": date("2026-11-20T14:30:00Z")]]],
            "timestamp": [date(latest)], "indicators": ["quote": [["close": [100]]]]
        ]]]])
    }

    private func date(_ text: String) -> Double { ISO8601DateFormatter().date(from: text)!.timeIntervalSince1970 }
}
