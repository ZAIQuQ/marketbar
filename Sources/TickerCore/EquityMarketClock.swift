import Foundation
import CoreFoundation

public struct EquityTradingSchedule {
    public let intervals: [DateInterval]
    public let fetchedAt: Date

    public init(intervals: [DateInterval], fetchedAt: Date) {
        self.intervals = intervals
        self.fetchedAt = fetchedAt
    }
}

public enum EquityMarketClock {
    public static func schedule(from data: Data, fetchedAt: Date) -> EquityTradingSchedule? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chart = root["chart"] as? [String: Any],
              let row = (chart["result"] as? [[String: Any]])?.first,
              let meta = row["meta"] as? [String: Any],
              let periods = meta["currentTradingPeriod"] as? [String: Any] else { return nil }
        var intervals: [DateInterval] = []
        for name in ["pre", "regular", "post"] {
            guard let period = periods[name] as? [String: Any],
                  let start = seconds(period["start"]), let end = seconds(period["end"]),
                  end >= start, end - start <= 86_400 else { return nil }
            intervals.append(DateInterval(start: Date(timeIntervalSince1970: start),
                                          end: Date(timeIntervalSince1970: end)))
        }
        guard intervals[0].end <= intervals[1].start, intervals[1].end <= intervals[2].start else { return nil }
        return EquityTradingSchedule(intervals: intervals, fetchedAt: fetchedAt)
    }

    public static func isClosed(symbol: String, at now: Date, schedule: EquityTradingSchedule? = nil) -> Bool {
        guard !Instrument.isOKX(symbol) else { return false }
        if let schedule, now >= schedule.fetchedAt, now.timeIntervalSince(schedule.fetchedAt) <= 300 {
            return !schedule.intervals.contains { now >= $0.start && now < $0.end }
        }
        // A missing/stale schedule must not hide a stock merely because its
        // data feed stopped. Retain the normal extended-hours window as fallback.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: now)
        guard let weekday = parts.weekday, let hour = parts.hour, let minute = parts.minute else { return false }
        return !(2...6).contains(weekday) || !(240..<1200).contains(hour * 60 + minute)
    }

    private static func seconds(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let result = value.doubleValue
        return result.isFinite && (946_684_800..<4_102_444_800).contains(result) ? result : nil
    }
}
