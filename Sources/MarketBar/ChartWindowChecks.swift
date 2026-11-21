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
    let anchor = date("2026-11-21T00:05:00Z")
    let end = date("2026-11-21T00:06:00Z")
    for minutes in [30, 60, 120, 180, 360, 720] {
        let range = ChartWindow.range(minutes: minutes, anchor: anchor)!
        check(range.end == end && range.duration == Double(minutes) * 60,
              "\(minutes)-minute window ends at the known minute's end without hour rounding")
        check(range.start < date("2026-11-21T00:00:00Z"),
              "\(minutes)-minute window crosses UTC midnight without truncation")
    }
    let twelveHours = ChartWindow.range(minutes: 720, anchor: anchor)!
    check(twelveHours.start == date("2026-11-20T12:06:00Z"), "12h view includes preceding UTC day's candles")
    let full = ChartWindow.range(minutes: 0, anchor: anchor)!
    let fullHistory = ChartWindow.historyRange(minutes: 0, anchor: anchor)!
    check(full.start == date("2026-11-21T00:00:00Z") && full.end == date("2026-11-22T00:00:00Z"),
          "full-day plot keeps UTC day boundaries")
    check(fullHistory.start == full.start && fullHistory.end == end,
          "full-day backfill excludes future minutes")
    let dstAnchor = date("2026-11-01T07:30:00Z")
    check(ChartWindow.range(minutes: 720, anchor: dstAnchor)?.duration == 43_200,
          "rolling duration stays absolute across local daylight-saving transitions")
    check(ChartWindow.normalized(17) == 120 && ChartWindow.normalized(0) == 0,
          "invalid saved window falls back to 2h while full-day zero is preserved")
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

    var pages: [ChartTimeRange] = []
    while let cursor = ChartWindow.nextHistoryCursor(in: twelveHours, symbol: symbol, candles: [], searched: pages) {
        pages.append(ChartTimeRange(start: cursor.addingTimeInterval(-6_000), end: cursor))
        if pages.count > 9 { break }
    }
    check(pages.count == 8, "12h empty window needs at most eight non-overlapping 100-minute pages")
    if failures.isEmpty {
        print("PASS chart window checks: \(count) deterministic checks (no network)")
        return true
    }
    print("FAIL chart window checks: \(failures.count)/\(count)")
    failures.forEach { print("  \($0)") }
    return false
}
