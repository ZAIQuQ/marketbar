import Foundation
import TickerCore

final class EquityHoursTests {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    func testExtendedHoursBoundariesAndDST() {
        XCTAssertEqual(EquityMarketClock.isClosed(symbol: "AMD", at: date("2026-11-20T08:59:59Z")), true)
        XCTAssertEqual(EquityMarketClock.isClosed(symbol: "AMD", at: date("2026-11-20T09:00:00Z")), false)
        XCTAssertEqual(EquityMarketClock.isClosed(symbol: "AMD", at: date("2026-11-21T00:59:59Z")), false)
        XCTAssertEqual(EquityMarketClock.isClosed(symbol: "AMD", at: date("2026-11-21T01:00:00Z")), true)
        XCTAssertEqual(EquityMarketClock.isClosed(symbol: "AMD", at: date("2026-07-10T08:00:00Z")), false)
        XCTAssertEqual(EquityMarketClock.isClosed(symbol: "AMD", at: date("2026-07-11T00:00:00Z")), true)
    }

    func testWeekendDoesNotHidePerpetuals() {
        let weekend = date("2026-11-21T15:00:00Z")
        XCTAssertEqual(EquityMarketClock.isClosed(symbol: "NVDA", at: weekend), true)
        XCTAssertEqual(EquityMarketClock.isClosed(symbol: "SOXL-USDT-SWAP", at: weekend), false)
    }

    func testFreshScheduleAndStaleFallback() {
        let now = date("2026-11-27T23:00:00Z")
        let earlyClose = DateInterval(start: date("2026-11-27T09:00:00Z"), end: date("2026-11-27T22:00:00Z"))
        let fresh = EquityTradingSchedule(intervals: [earlyClose], fetchedAt: now.addingTimeInterval(-30))
        XCTAssertEqual(EquityMarketClock.isClosed(symbol: "AMD", at: now, schedule: fresh), true)
        let old = EquityTradingSchedule(intervals: [earlyClose], fetchedAt: now.addingTimeInterval(-600))
        XCTAssertEqual(EquityMarketClock.isClosed(symbol: "AMD", at: now, schedule: old), false)
    }
}
