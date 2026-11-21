import Foundation
import TickerCore

struct ChartTimeRange: Hashable {
    let start: Date
    let end: Date

    var duration: TimeInterval { end.timeIntervalSince(start) }
    func contains(_ minute: Date) -> Bool { minute >= start && minute < end }
}

/// Rolling windows use absolute minutes, including candles on earlier UTC days.
/// A full-day plot may extend into the future; its history request never does.
enum ChartWindow {
    static let presets = [30, 60, 120, 180, 360, 720, 0]

    static func normalized(_ minutes: Int) -> Int {
        presets.contains(minutes) ? minutes : 120
    }

    static func label(_ minutes: Int) -> String {
        switch normalized(minutes) {
        case 0: return "全天（UTC）"
        case 30: return "近 30 分钟"
        default: return "近 \(normalized(minutes) / 60) 小时"
        }
    }

    static func range(minutes: Int, anchor: Date) -> ChartTimeRange? {
        let seconds = anchor.timeIntervalSince1970
        guard seconds.isFinite, (946_684_800..<4_102_444_800).contains(seconds) else { return nil }
        let end = Date(timeIntervalSince1970: floor(seconds / 60) * 60 + 60)
        let window = normalized(minutes)
        if window > 0 {
            return ChartTimeRange(start: end.addingTimeInterval(-Double(window) * 60), end: end)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.startOfDay(for: anchor)
        return calendar.date(byAdding: .day, value: 1, to: start)
            .map { ChartTimeRange(start: start, end: $0) }
    }

    static func historyRange(minutes: Int, anchor: Date) -> ChartTimeRange? {
        guard let plot = range(minutes: minutes, anchor: anchor) else { return nil }
        let knownEnd = Date(timeIntervalSince1970: floor(anchor.timeIntervalSince1970 / 60) * 60 + 60)
        return ChartTimeRange(start: plot.start, end: min(plot.end, knownEnd))
    }

    /// Existing local samples count as displayed data, retaining their source
    /// label. This only identifies empty minutes; it does not certify complete OHLC.
    static func missingMinutes(in range: ChartTimeRange, symbol: String,
                               candles: [MinuteCandle]) -> [Date] {
        guard range.duration.isFinite, range.duration > 0, range.duration <= 86_400 else { return [] }
        let present = Set(candles.filter { $0.symbol == symbol && range.contains($0.minute) }.map(\.minute))
        return stride(from: range.start.timeIntervalSince1970, to: range.end.timeIntervalSince1970, by: 60)
            .map { Date(timeIntervalSince1970: $0) }.filter { !present.contains($0) }
    }

    /// A searched gap stays blank and is skipped for the rest of this request,
    /// rather than repeatedly querying the same unavailable minute.
    static func nextHistoryCursor(in range: ChartTimeRange, symbol: String, candles: [MinuteCandle],
                                  searched: [ChartTimeRange]) -> Date? {
        missingMinutes(in: range, symbol: symbol, candles: candles)
            .last(where: { minute in !searched.contains(where: { $0.contains(minute) }) })?.addingTimeInterval(60)
    }
}
