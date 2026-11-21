import Foundation
import CoreFoundation

public struct OKXTicker {
    public let quote: PriceQuote
    public let reference: ChartReference?
    public let bid: Double?
    public let ask: Double?

    public init(quote: PriceQuote, reference: ChartReference?, bid: Double? = nil, ask: Double? = nil) {
        self.quote = quote
        self.reference = reference
        self.bid = bid
        self.ask = ask
    }
}

/// Parses public OKX perpetual market data. Ticker `ts` is a message-generation
/// timestamp, so only the separate trades channel may create local OHLC samples.
public enum OKXDecoder {
    public static func ticker(_ data: Data, expectedSymbol: String,
                              source: QuoteSource = .stream) throws -> OKXTicker? {
        let root = try envelope(data, expectedSymbol: expectedSymbol, channels: ["tickers"])
        guard root["event"] == nil else { return nil }
        guard let rows = root["data"] as? [[String: Any]] else { throw QuoteError.malformedData }
        var latest: OKXTicker?
        for row in rows {
            // REST ticker payloads must name their own instrument. Never attach
            // a price to the requested symbol solely because a request used it.
            try identity(row, expectedSymbol: expectedSymbol, requireID: true)
            guard let price = positive(row["last"]), let timestamp = timestamp(row["ts"]) else {
                throw QuoteError.malformedData
            }
            let change = positive(row["open24h"]).flatMap { reference -> Double? in
                let value = (price / reference - 1) * 100
                return value.isFinite ? value : nil
            }
            let quote = PriceQuote(symbol: expectedSymbol, price: price, timestamp: timestamp,
                                   session: .perpetual, source: source,
                                   changePercent: change, recordsPriceSample: false)
            let reference = positive(row["sodUtc0"]).map {
                ChartReference(day: Instrument.day(expectedSymbol, at: timestamp),
                               previousClose: $0, basis: .utcOpen)
            }
            if latest == nil || timestamp >= latest!.quote.timestamp {
                latest = OKXTicker(quote: quote, reference: reference,
                                   bid: positive(row["bidPx"]), ask: positive(row["askPx"]))
            }
        }
        return latest
    }

    public static func trades(_ data: Data, expectedSymbol: String) throws -> [PriceQuote] {
        let root = try envelope(data, expectedSymbol: expectedSymbol, channels: ["trades", "trades-all"])
        guard root["event"] == nil else { return [] }
        guard let rows = root["data"] as? [[String: Any]] else { throw QuoteError.malformedData }
        let isStream = root["arg"] != nil
        return try rows.map { row in
            try identity(row, expectedSymbol: expectedSymbol, requireID: isStream)
            guard let price = positive(row["px"]), let timestamp = timestamp(row["ts"]) else {
                throw QuoteError.malformedData
            }
            return PriceQuote(symbol: expectedSymbol, price: price, timestamp: timestamp,
                              session: .perpetual, source: .stream, recordsPriceSample: true)
        }.sorted { $0.timestamp < $1.timestamp }
    }

    public static func candles(_ data: Data, expectedSymbol: String,
                               receivedAt: Date = Date()) throws -> [MinuteCandle] {
        let root = try envelope(data, expectedSymbol: expectedSymbol, channels: ["candle1m"])
        guard root["event"] == nil else { return [] }
        guard validDate(receivedAt), let rows = root["data"] as? [[Any]] else { throw QuoteError.malformedData }
        var minutes: [Date: MinuteCandle] = [:]
        for row in rows {
            guard row.count >= 9, let minute = timestamp(row[0]),
                  minute.timeIntervalSince1970.truncatingRemainder(dividingBy: 60) == 0,
                  minute <= receivedAt.addingTimeInterval(30),
                  let open = positive(row[1]), let high = positive(row[2]),
                  let low = positive(row[3]), let close = positive(row[4]),
                  low <= min(open, close), high >= max(open, close), low <= high,
                  let confirmation = row[8] as? String, confirmation == "0" || confirmation == "1" else { continue }
            let final = confirmation == "1"
            let candle = MinuteCandle(symbol: expectedSymbol, minute: minute,
                open: open, high: high, low: low, close: close,
                // SWAP's vol is a contract count. Do not label contracts as
                // shares/base tokens or invent missing volume for local trades.
                volume: nil, session: .perpetual, origin: .okx,
                firstEvent: minute, lastEvent: minute, observedAt: receivedAt,
                sampleCount: 0, isFinal: final)
            if let prior = minutes[minute], prior.isFinal == true, !final { continue }
            minutes[minute] = candle
        }
        return minutes.values.sorted { $0.minute < $1.minute }
    }

    private static func envelope(_ data: Data, expectedSymbol: String,
                                 channels: Set<String>) throws -> [String: Any] {
        guard Instrument.isOKX(expectedSymbol), expectedSymbol == expectedSymbol.uppercased(),
              data.count <= 16_777_216,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuoteError.malformedData
        }
        if root["event"] as? String == "error" { throw QuoteError.providerError }
        if let code = root["code"] {
            guard let value = code as? String, value == "0" else { throw QuoteError.providerError }
        }
        if let argument = root["arg"] {
            guard let arg = argument as? [String: Any], let channel = arg["channel"] as? String,
                  channels.contains(channel) else { throw QuoteError.malformedData }
            try identity(arg, expectedSymbol: expectedSymbol, requireID: true)
        } else {
            guard root["code"] as? String == "0" else { throw QuoteError.malformedData }
        }
        if let event = root["event"] as? String,
           event != "subscribe" && event != "unsubscribe" { throw QuoteError.malformedData }
        return root
    }

    private static func identity(_ fields: [String: Any], expectedSymbol: String,
                                 requireID: Bool) throws {
        if let value = fields["instId"] {
            guard let symbol = value as? String, symbol == expectedSymbol else { throw QuoteError.unexpectedSymbol }
        } else if requireID { throw QuoteError.unexpectedSymbol }
        if let value = fields["instType"] {
            guard let type = value as? String, type == "SWAP" else { throw QuoteError.unexpectedSymbol }
        }
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? String {
            guard !value.isEmpty, let number = Double(value), number.isFinite else { return nil }
            return number
        }
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    private static func positive(_ value: Any?) -> Double? {
        guard let number = number(value), number > 0 else { return nil }
        return number
    }

    private static func timestamp(_ value: Any?) -> Date? {
        guard let milliseconds = number(value), milliseconds.rounded(.towardZero) == milliseconds else { return nil }
        let date = Date(timeIntervalSince1970: milliseconds / 1_000)
        return validDate(date) ? date : nil
    }

    private static func validDate(_ date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite && (946_684_800..<4_102_444_800).contains(date.timeIntervalSince1970)
    }
}
