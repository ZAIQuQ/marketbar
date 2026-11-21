import Foundation
import CoreFoundation

public enum ReferenceBasis: String, Codable {
    case previousClose, utcOpen
}

/// A price reference for one explicit instrument-local trading date.
/// Callers must match `day` to the selected candle before displaying a percent.
public struct ChartReference: Codable, Equatable {
    public let day: String
    public let previousClose: Double
    public let basis: ReferenceBasis

    public init(day: String, previousClose: Double, basis: ReferenceBasis = .previousClose) {
        self.day = day
        self.previousClose = previousClose
        self.basis = basis
    }

    private enum CodingKeys: String, CodingKey { case day, previousClose, basis }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        day = try values.decode(String.self, forKey: .day)
        previousClose = try values.decode(Double.self, forKey: .previousClose)
        basis = try values.decodeIfPresent(ReferenceBasis.self, forKey: .basis) ?? .previousClose
    }

    public func percentChange(at price: Double) -> Double? {
        guard price.isFinite, price > 0, previousClose.isFinite, previousClose > 0 else { return nil }
        let result = (price / previousClose - 1) * 100
        return result.isFinite ? result : nil
    }
}

public enum ChartReferenceDecoder {
    public static func chart(_ data: Data, expectedSymbol: String) throws -> ChartReference? {
        guard data.count <= 16_777_216,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chart = root["chart"] as? [String: Any] else { throw QuoteError.malformedData }
        if let error = chart["error"], !(error is NSNull) { throw QuoteError.providerError }
        guard let result = (chart["result"] as? [[String: Any]])?.first,
              let meta = result["meta"] as? [String: Any],
              let symbol = meta["symbol"] as? String else { return nil }
        guard symbol.uppercased() == expectedSymbol.uppercased() else { throw QuoteError.unexpectedSymbol }
        if let provided = meta["currency"], !(provided is NSNull) {
            guard let currency = provided as? String, currency.uppercased() == "USD" else {
                throw QuoteError.malformedData
            }
        }
        // In longer ranges, chartPreviousClose may refer to the beginning of
        // the whole chart rather than the selected day's prior regular close.
        if let range = meta["range"] as? String, range != "1d" { return nil }
        guard let periods = meta["currentTradingPeriod"] as? [String: Any],
              let timestamps = result["timestamp"] as? [Any],
              let indicators = result["indicators"] as? [String: Any],
              let closes = (indicators["quote"] as? [[String: Any]])?.first?["close"] as? [Any] else { return nil }

        var latest: Date?
        for index in 0..<min(timestamps.count, closes.count) {
            guard positive(closes[index]) != nil, let timestamp = date(timestamps[index]) else { continue }
            if latest == nil || timestamp > latest! { latest = timestamp }
        }
        guard let latest else { return nil }
        let targetDay = day(latest)
        let regularStart = (periods["regular"] as? [String: Any]).flatMap { date($0["start"]) }
        let preStart = (periods["pre"] as? [String: Any]).flatMap { date($0["start"]) }
        guard let periodStart = regularStart ?? preStart, day(periodStart) == targetDay else { return nil }
        if let regularStart, let preStart, day(regularStart) != day(preStart) { return nil }

        guard let regularTime = date(meta["regularMarketTime"]) else { return nil }
        let regularDay = day(regularTime)
        let reference: Double?
        if regularDay < targetDay {
            // During premarket Yahoo's previousClose can still be relative to
            // yesterday's regular quote. The last regular price itself is the
            // correct close immediately preceding the chart's newer date.
            reference = positive(meta["regularMarketPrice"])
        } else if regularDay == targetDay {
            reference = positive(meta["previousClose"]) ?? positive(meta["chartPreviousClose"])
        } else {
            return nil
        }
        return reference.map { ChartReference(day: targetDay, previousClose: $0) }
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        return value.doubleValue.isFinite ? value.doubleValue : nil
    }

    private static func positive(_ value: Any?) -> Double? {
        guard let value = number(value), value > 0 else { return nil }
        return value
    }

    private static func date(_ value: Any?) -> Date? {
        guard let seconds = number(value), (946_684_800..<4_102_444_800).contains(seconds) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func day(_ value: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: value)
    }
}
