import Foundation
import CoreFoundation

public enum YahooDecoder {
    /// Yahoo sends a JSON envelope containing base64 protobuf. Older variants
    /// send base64 directly. Unknown control messages have no price and are ignored.
    public static func stream(_ text: String) throws -> PriceQuote? {
        guard text.utf8.count <= 1_048_576 else { throw QuoteError.malformedData }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let encoded: String
        if trimmed.hasPrefix("{") {
            guard let object = try JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] else {
                throw QuoteError.malformedData
            }
            guard object["type"] as? String == "pricing" else { return nil }
            guard let message = object["message"] as? String else { throw QuoteError.malformedData }
            encoded = message
        } else {
            encoded = trimmed
        }
        guard let data = Data(base64Encoded: encoded), !data.isEmpty else { throw QuoteError.malformedData }
        var reader = ProtoReader(data: data)
        var symbol: String?
        var price: Double?
        var timestamp: Date?
        // Protobuf's omitted scalar value is zero (PRE_MARKET).
        var marketHours: UInt64 = 0
        var changePercent: Double?
        while !reader.isAtEnd {
            let tag = try reader.varint()
            let field = tag >> 3
            let wire = tag & 7
            guard field > 0 else { throw QuoteError.malformedData }
            switch (field, wire) {
            case (1, 2):
                let bytes = try reader.lengthDelimited()
                guard let value = String(data: bytes, encoding: .utf8) else { throw QuoteError.malformedData }
                symbol = value
            case (2, 5): price = Double(Float(bitPattern: try reader.fixed32()))
            case (3, 0):
                let raw = try reader.varint()
                let decoded = Int64(bitPattern: raw >> 1) ^ -Int64(raw & 1)
                timestamp = validTimestamp(Double(decoded) / 1_000)
            case (7, 0): marketHours = try reader.varint()
            case (8, 5): changePercent = Double(Float(bitPattern: try reader.fixed32()))
            default: try reader.skip(wire: wire)
            }
        }
        guard let symbol, !symbol.isEmpty, symbol.utf8.count <= 64,
              let price, validPrice(price) != nil, let timestamp else { throw QuoteError.missingQuote }
        let session: TradingSession
        switch marketHours {
        case 0: session = .pre
        case 1: session = .regular
        case 2: session = .post
        // 3 means EXTENDED_HOURS; it does not distinguish pre/post/overnight.
        case 3: session = .unknown
        default: session = .unknown
        }
        return PriceQuote(symbol: symbol.uppercased(), price: price, timestamp: timestamp,
                          session: session, source: .stream,
                          changePercent: changePercent.flatMap { $0.isFinite ? $0 : nil })
    }

    public static func chart(_ data: Data, expectedSymbol: String) throws -> ChartSnapshot {
        guard data.count <= 5_242_880 else { throw QuoteError.malformedData }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chart = object["chart"] as? [String: Any] else { throw QuoteError.malformedData }
        if let error = chart["error"], !(error is NSNull) { throw QuoteError.providerError }
        guard let results = chart["result"] as? [[String: Any]], let result = results.first,
              let meta = result["meta"] as? [String: Any], let symbol = meta["symbol"] as? String else {
            throw QuoteError.missingQuote
        }
        guard symbol.uppercased() == expectedSymbol.uppercased() else { throw QuoteError.unexpectedSymbol }
        let previousClose = number(meta["previousClose"]).flatMap(validPrice)
            ?? number(meta["chartPreviousClose"]).flatMap(validPrice)
        let regularPrice = number(meta["regularMarketPrice"]).flatMap(validPrice)
        var candidate: (price: Double, date: Date, session: TradingSession)?
        // This metadata field is always a regular-session quote, even when its
        // timestamp falls a few seconds after the official closing boundary.
        if let price = regularPrice, let seconds = number(meta["regularMarketTime"]),
           let date = validTimestamp(seconds) {
            candidate = (price, date, .regular)
        }
        if let timestamps = result["timestamp"] as? [Any],
           let indicators = result["indicators"] as? [String: Any],
           let quotes = indicators["quote"] as? [[String: Any]],
           let closes = quotes.first?["close"] as? [Any] {
            for index in 0..<min(timestamps.count, closes.count) {
                guard let price = number(closes[index]).flatMap(validPrice),
                      let seconds = number(timestamps[index]), let date = validTimestamp(seconds) else { continue }
                // Prefer the exact-time regular metadata quote when times tie.
                if candidate == nil || date > candidate!.date {
                    candidate = (price, date, session(at: date, metadata: meta))
                }
            }
        }
        guard let chosen = candidate else { throw QuoteError.missingQuote }
        let reference: Double?
        switch chosen.session {
        case .post: reference = regularPrice
        case .pre, .regular: reference = previousClose
        case .closed, .unknown, .perpetual, .spot: reference = nil
        }
        let change = reference.map { (chosen.price / $0 - 1) * 100 }
        let quote = PriceQuote(symbol: symbol.uppercased(), price: chosen.price, timestamp: chosen.date,
                               session: chosen.session, source: .snapshot, changePercent: change)
        return ChartSnapshot(quote: quote, previousClose: previousClose, regularClose: regularPrice)
    }

    private static func session(at date: Date, metadata: [String: Any]) -> TradingSession {
        if let periods = metadata["currentTradingPeriod"] as? [String: Any], !periods.isEmpty {
            for session in [TradingSession.pre, .regular, .post] {
                if let period = periods[session.rawValue] as? [String: Any],
                   let start = number(period["start"]), let end = number(period["end"]), start < end,
                   date.timeIntervalSince1970 >= start, date.timeIntervalSince1970 < end {
                    return session
                }
            }
            // A different day's schedule cannot identify an older early-close
            // session. Preserve uncertainty instead of applying normal hours.
            return .unknown
        }
        return TradingSession.inferred(at: date)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let result = value.doubleValue
        return result.isFinite ? result : nil
    }

    private static func validPrice(_ price: Double) -> Double? {
        price.isFinite && price > 0 ? price : nil
    }

    private static func validTimestamp(_ seconds: Double) -> Date? {
        guard seconds.isFinite, (946_684_800..<4_102_444_800).contains(seconds) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

private struct ProtoReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(data: Data) { bytes = Array(data) }
    var isAtEnd: Bool { offset == bytes.count }

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        for index in 0..<10 {
            guard offset < bytes.count else { throw QuoteError.malformedData }
            let byte = bytes[offset]
            offset += 1
            if index == 9 && byte > 1 { throw QuoteError.malformedData }
            result |= UInt64(byte & 0x7F) << (index * 7)
            if byte & 0x80 == 0 { return result }
        }
        throw QuoteError.malformedData
    }

    mutating func fixed32() throws -> UInt32 {
        let data = try take(4)
        return UInt32(data[0]) | UInt32(data[1]) << 8 | UInt32(data[2]) << 16 | UInt32(data[3]) << 24
    }

    mutating func lengthDelimited() throws -> Data {
        let count = try varint()
        guard count <= UInt64(bytes.count - offset) else { throw QuoteError.malformedData }
        return Data(try take(Int(count)))
    }

    mutating func skip(wire: UInt64) throws {
        switch wire {
        case 0: _ = try varint()
        case 1: _ = try take(8)
        case 2: _ = try lengthDelimited()
        case 5: _ = try take(4)
        default: throw QuoteError.malformedData
        }
    }

    private mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, count <= bytes.count - offset else { throw QuoteError.malformedData }
        let start = offset
        offset += count
        // Reset slice indices so fixed-width decoding never indexes a nonzero base.
        return ArraySlice(Array(bytes[start..<offset]))
    }
}
