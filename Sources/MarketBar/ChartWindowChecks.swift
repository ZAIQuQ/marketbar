import Foundation
import TickerCore

func runChartWindowChecks() -> Bool {
    var failures: [String] = []
    var count = 0
    func check(_ value: Bool, _ description: String) {
        count += 1
        if !value { failures.append(description) }
    }
    func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    let symbol = "SOXL-USDT-SWAP"
    let anchor = date("2026-11-21T00:05:37Z")
    let end = date("2026-11-21T00:06:00Z")
    for minutes in [30, 60, 120, 180, 360, 720, 1440] {
        let range = ChartWindow.range(minutes: minutes, anchor: anchor)!
        check(range.end == end && range.duration == Double(minutes) * 60,
              "\(minutes)-minute window ends at the known minute's end without hour rounding")
        check(range.start < date("2026-11-21T00:00:00Z"),
              "\(minutes)-minute window crosses UTC midnight without truncation")
    }
    let twelveHours = ChartWindow.range(minutes: 720, anchor: anchor)!
    check(twelveHours.start == date("2026-11-20T12:06:00Z"), "12h view includes preceding UTC day's candles")
    let twentyFourHours = ChartWindow.range(minutes: 1440, anchor: anchor)!
    check(twentyFourHours.start == date("2026-11-20T00:06:00Z") && twentyFourHours.end == end,
          "24h means the latest 1440 absolute minutes, not the current UTC calendar day")
    check(ChartWindow.range(minutes: 0, anchor: anchor) == twentyFourHours,
          "legacy saved zero uses the same rolling 24h window")
    check(twentyFourHours.contains(date("2026-11-21T00:05:00Z")) && !twentyFourHours.contains(end),
          "the latest known minute is included while the next, future minute is excluded")
    check(ChartWindow.presets == [30, 60, 120, 180, 360, 720, 1440],
          "all presets are rolling; there is no remaining calendar-day option")
    check(ChartWindow.label(1440) == "近 24 小时" && ChartWindow.label(0) == "近 24 小时",
          "legacy and explicit 24h values have the same rolling-window label")
    for (input, expectedStart, expectedEnd) in [
        ("2026-03-08T07:30:37Z", "2026-03-07T07:31:00Z", "2026-03-08T07:31:00Z"),
        ("2026-11-01T07:30:37Z", "2026-10-31T07:31:00Z", "2026-11-01T07:31:00Z")
    ] {
        let range = ChartWindow.range(minutes: 1440, anchor: date(input))!
        check(range.duration == 86_400 && range.start == date(expectedStart) && range.end == date(expectedEnd),
              "24h remains exactly 86400 seconds across both New York DST transitions")
    }
    check(ChartWindow.normalized(17) == 120 && ChartWindow.normalized(-1) == 120
          && ChartWindow.normalized(120) == 120 && ChartWindow.normalized(0) == 1440,
          "invalid saved windows retain the 2h default and legacy zero maps to 24h")
    check(ChartWindow.range(minutes: 120, anchor: Date(timeIntervalSince1970: .nan)) == nil,
          "non-finite anchor rejected")

    func candle(_ minute: Date, symbol value: String = "SOXL-USDT-SWAP") -> MinuteCandle {
        MinuteCandle(symbol: value, minute: minute, open: 33, high: 34, low: 32, close: 33,
            volume: nil, session: Instrument.marketSession(value), origin: .okx,
            firstEvent: minute, lastEvent: minute, observedAt: end,
            sampleCount: 0, isFinal: true)
    }
    let short = ChartTimeRange(start: date("2026-11-20T23:58:00Z"), end: date("2026-11-21T00:01:00Z"))
    let hole = date("2026-11-20T23:59:00Z")
    let present = [candle(short.start), candle(date("2026-11-21T00:00:00Z")),
                   candle(hole, symbol: "BTC-USDT-SWAP"), candle(short.end), candle(short.start)]
    check(ChartWindow.missingMinutes(in: short, symbol: symbol, candles: present) == [hole],
          "exact gap is retained across midnight; duplicates, other symbols and end boundary do not fill it")
    let cursor = ChartWindow.nextHistoryCursor(in: short, symbol: symbol, candles: present, searched: [])
    check(cursor == hole.addingTimeInterval(60), "exclusive history cursor includes the newest missing minute")
    let searched = [ChartTimeRange(start: hole, end: hole.addingTimeInterval(60))]
    check(ChartWindow.nextHistoryCursor(in: short, symbol: symbol, candles: present, searched: searched) == nil,
          "unavailable searched minute does not cause an endless identical request")
    check(ChartWindow.missingMinutes(in: short, symbol: symbol, candles: present) == [hole],
          "marking a gap searched never fabricates a candle")

    let spot = "BTC-USDT"
    let spotRows = [candle(short.start, symbol: spot), candle(date("2026-11-21T00:00:00Z"), symbol: spot),
                    candle(hole, symbol: "BTC-USDT-SWAP")]
    check(spotRows[0].session == .spot, "BTC spot retains its spot session")
    check(ChartWindow.missingMinutes(in: short, symbol: spot, candles: spotRows) == [hole],
          "spot rolling chart spans UTC midnight and never uses perpetual candles to fill gaps")
    check(ChartWindow.nextHistoryCursor(in: short, symbol: spot, candles: spotRows, searched: []) == hole.addingTimeInterval(60),
          "spot history uses the same exclusive missing-minute cursor")

    let latestMinute = date("2026-11-21T00:05:00Z")
    let twentyFourPresent = [candle(latestMinute), candle(twentyFourHours.end),
                            candle(twentyFourHours.end.addingTimeInterval(60)),
                            candle(twentyFourHours.start.addingTimeInterval(-60))]
    let twentyFourMissing = ChartWindow.missingMinutes(in: twentyFourHours, symbol: symbol, candles: twentyFourPresent)
    check(twentyFourMissing.count == 1439 && twentyFourMissing.first == twentyFourHours.start
          && twentyFourMissing.last == latestMinute.addingTimeInterval(-60),
          "24h backfill counts only the window's minutes; future and older data cannot fill gaps")
    check(ChartWindow.nextHistoryCursor(in: twentyFourHours, symbol: symbol, candles: [], searched: []) == end,
          "empty 24h backfill starts after the latest included minute, not after a future UTC day")

    var pages: [ChartTimeRange] = []
    while let cursor = ChartWindow.nextHistoryCursor(in: twelveHours, symbol: symbol, candles: [], searched: pages) {
        pages.append(ChartTimeRange(start: cursor.addingTimeInterval(-6_000), end: cursor))
        if pages.count > 9 { break }
    }
    check(pages.count == 8, "12h empty window needs at most eight non-overlapping 100-minute pages")
    var dayPages: [ChartTimeRange] = []
    while let cursor = ChartWindow.nextHistoryCursor(in: twentyFourHours, symbol: symbol, candles: [], searched: dayPages) {
        dayPages.append(ChartTimeRange(start: max(twentyFourHours.start, cursor.addingTimeInterval(-6_000)), end: cursor))
        if dayPages.count > 15 { break }
    }
    check(dayPages.count == 15 && dayPages.first?.end == twentyFourHours.end
          && dayPages.last?.start == twentyFourHours.start,
          "24h empty window is covered by exactly fifteen bounded 100-minute pages")
    check(zip(dayPages, dayPages.dropFirst()).allSatisfy { $0.start == $1.end },
          "24h pagination moves backward continuously without overlap or skipped minutes")
    check(ChartWindow.nextHistoryCursor(in: twentyFourHours, symbol: symbol, candles: [], searched: dayPages) == nil,
          "fifteen searched pages finish the 24h request without retrying empty history forever")
    if failures.isEmpty {
        print("PASS chart window checks: \(count) deterministic checks (no network)")
        return true
    }
    print("FAIL chart window checks: \(failures.count)/\(count)")
    failures.forEach { print("  \($0)") }
    return false
}
