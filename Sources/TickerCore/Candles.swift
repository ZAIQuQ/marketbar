import Foundation
import CoreFoundation

public enum CandleOrigin: String, Codable {
    case yahoo, localSample, mixed
}

public struct MinuteCandle: Codable, Equatable, Identifiable {
    public var id: Date { minute }
    public let symbol: String
    public let minute: Date
    public let open: Double
    public let high: Double
    public let low: Double
    public let close: Double
    public let volume: Double?
    public let session: TradingSession
    public let origin: CandleOrigin
    public let firstEvent: Date
    public let lastEvent: Date
    public let observedAt: Date
    public let sampleCount: Int

    public init(symbol: String, minute: Date, open: Double, high: Double, low: Double,
                close: Double, volume: Double?, session: TradingSession, origin: CandleOrigin,
                firstEvent: Date, lastEvent: Date, observedAt: Date, sampleCount: Int) {
        self.symbol = symbol
        self.minute = minute
        self.open = open
        self.high = high
        self.low = low
        self.close = close
        self.volume = volume
        self.session = session
        self.origin = origin
        self.firstEvent = firstEvent
        self.lastEvent = lastEvent
        self.observedAt = observedAt
        self.sampleCount = sampleCount
    }
}

public enum CandleDecoder {
    /// Decode the actual reported 1-minute OHLCV rows. Missing or inconsistent
    /// rows are skipped; no missing minute or price is interpolated.
    public static func chart(_ data: Data, expectedSymbol: String,
                             receivedAt: Date = Date()) throws -> [MinuteCandle] {
        guard data.count <= 16_777_216, CandleValidation.date(receivedAt),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chart = root["chart"] as? [String: Any] else { throw QuoteError.malformedData }
        if let error = chart["error"], !(error is NSNull) { throw QuoteError.providerError }
        guard let result = (chart["result"] as? [[String: Any]])?.first,
              let meta = result["meta"] as? [String: Any],
              let symbol = meta["symbol"] as? String else { throw QuoteError.missingQuote }
        guard symbol.uppercased() == expectedSymbol.uppercased() else { throw QuoteError.unexpectedSymbol }
        guard CandleValidation.symbol(symbol.uppercased()) else { throw QuoteError.malformedData }
        if let provided = meta["currency"], !(provided is NSNull) {
            guard let currency = provided as? String, currency.uppercased() == "USD" else {
                throw QuoteError.malformedData
            }
        }
        if let granularity = meta["dataGranularity"] as? String, granularity != "1m" {
            throw QuoteError.malformedData
        }
        guard let timestamps = result["timestamp"] as? [Any],
              let indicators = result["indicators"] as? [String: Any],
              let row = (indicators["quote"] as? [[String: Any]])?.first,
              let opens = row["open"] as? [Any], let highs = row["high"] as? [Any],
              let lows = row["low"] as? [Any], let closes = row["close"] as? [Any] else {
            throw QuoteError.missingQuote
        }
        let volumes = row["volume"] as? [Any] ?? []
        var byMinute: [Date: MinuteCandle] = [:]
        let count = [timestamps.count, opens.count, highs.count, lows.count, closes.count].min() ?? 0
        for index in 0..<count {
            guard let seconds = number(timestamps[index]), let open = number(opens[index]),
                  let high = number(highs[index]), let low = number(lows[index]),
                  let close = number(closes[index]) else { continue }
            let event = Date(timeIntervalSince1970: seconds)
            guard CandleValidation.date(event), event <= receivedAt.addingTimeInterval(30),
                  CandleValidation.ohlc(open, high, low, close) else { continue }
            let minute = CandleValidation.minute(event)
            let volume = index < volumes.count ? number(volumes[index]).flatMap { $0 >= 0 ? $0 : nil } : nil
            let candle = MinuteCandle(symbol: symbol.uppercased(), minute: minute,
                                      open: open, high: high, low: low, close: close, volume: volume,
                                      session: session(at: event, metadata: meta), origin: .yahoo,
                                      firstEvent: event, lastEvent: event,
                                      observedAt: receivedAt, sampleCount: 0)
            if let prior = byMinute[minute] {
                // Yahoo can append a current-price row with a seconds timestamp
                // in the same bucket as its partial minute bar. Those intervals
                // overlap, so their reported volumes must never be summed.
                let first = prior.firstEvent <= candle.firstEvent ? prior : candle
                let last = prior.lastEvent > candle.lastEvent ? prior : candle
                let knownVolumes = [prior.volume, candle.volume].compactMap { $0 }
                byMinute[minute] = MinuteCandle(symbol: candle.symbol, minute: minute,
                    open: first.open, high: max(prior.high, candle.high), low: min(prior.low, candle.low),
                    close: last.close, volume: knownVolumes.max(), session: first.session, origin: .yahoo,
                    firstEvent: min(prior.firstEvent, candle.firstEvent),
                    lastEvent: max(prior.lastEvent, candle.lastEvent), observedAt: receivedAt, sampleCount: 0)
            } else { byMinute[minute] = candle }
        }
        return byMinute.values.sorted { $0.minute < $1.minute }
    }

    private static func session(at timestamp: Date, metadata: [String: Any]) -> TradingSession {
        if let periods = metadata["currentTradingPeriod"] as? [String: Any] {
            for session in [TradingSession.pre, .regular, .post] {
                if let period = periods[session.rawValue] as? [String: Any],
                   let start = number(period["start"]), let end = number(period["end"]), start < end,
                   timestamp.timeIntervalSince1970 >= start, timestamp.timeIntervalSince1970 < end {
                    return session
                }
            }
        }
        // A real historical 04:00–09:30 ET bar is safely premarket even when
        // currentTradingPeriod has rolled to the next trading day. The normal
        // 09:30–16:00 / 16:00–20:00 split cannot resolve old early-close days.
        return TradingSession.inferred(at: timestamp) == .pre ? .pre : .unknown
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        return value.doubleValue.isFinite ? value.doubleValue : nil
    }
}

/// An online OHLC layer plus a separate layer of locally received trade-price
/// samples. `candles` is a display/cache projection; local samples are never
/// presented as complete market OHLC or as market volume.
public struct CandleBook {
    private struct Key: Hashable {
        let symbol: String
        let minute: Date
        init(_ candle: MinuteCandle) { symbol = candle.symbol; minute = candle.minute }
        init(_ quote: PriceQuote) { symbol = quote.symbol; minute = CandleValidation.minute(quote.timestamp) }
    }
    private struct Event {
        let price: Double
        let time: Date
        let receivedAt: Date
        let session: TradingSession
    }
    private struct Samples {
        var restored: MinuteCandle?
        var events: [Event] = []
        var count: Int { (restored?.sampleCount ?? 0) + events.count }
    }
    private var remote: [Key: MinuteCandle] = [:]
    private var local: [Key: Samples] = [:]
    private var latestMinute: [String: Date] = [:]
    // Kept separately: combining an old full-bar prefix with a late partial
    // quote does not prove that the source delivered a completed minute.
    private var completedRemote: Set<Key> = []

    public init() {}

    public mutating func mergeRemote(_ incoming: [MinuteCandle]) {
        for candle in incoming where candle.origin == .yahoo && CandleValidation.candle(candle) {
            let key = Key(candle)
            if let existing = remote[key], existing.observedAt > candle.observedAt { continue }
            let complete = isCompleteSourceBar(candle)
            if completedRemote.contains(key), !complete {
                // A late partial response must not reopen a completed minute.
                continue
            }
            if let existing = remote[key], !complete,
               candle.firstEvent > candle.minute || existing.lastEvent > candle.lastEvent {
                // HTTP receipt order is not price-event order. Preserve a newer
                // explicit price timestamp and any already observed extrema
                // when an incomplete response arrives later over the network.
                let first = existing.firstEvent <= candle.firstEvent ? existing : candle
                let last = existing.lastEvent > candle.lastEvent ? existing : candle
                remote[key] = MinuteCandle(symbol: candle.symbol, minute: candle.minute,
                    open: first.open, high: max(existing.high, candle.high), low: min(existing.low, candle.low),
                    close: last.close,
                    volume: existing.origin == .mixed ? nil : [existing.volume, candle.volume].compactMap { $0 }.max(),
                    session: first.session, origin: existing.origin,
                    firstEvent: first.firstEvent, lastEvent: last.lastEvent,
                    observedAt: candle.observedAt, sampleCount: existing.sampleCount)
            } else { remote[key] = candle }
            if complete { completedRemote.insert(key) }
            else { completedRemote.remove(key) }
            advanceMinute(key)
            if complete {
                // A complete historical remote minute supersedes all local
                // event prices whose timestamps fall inside that minute.
                local.removeValue(forKey: key)
            }
        }
    }

    public mutating func ingest(_ quote: PriceQuote, receivedAt: Date) {
        guard quote.source == .stream, quote.price.isFinite, quote.price > 0,
              CandleValidation.symbol(quote.symbol), CandleValidation.date(quote.timestamp),
              CandleValidation.date(receivedAt) else { return }
        let key = Key(quote)
        var samples = local[key] ?? Samples()
        samples.events.append(Event(price: quote.price, time: quote.timestamp,
                                    receivedAt: receivedAt, session: quote.session))
        local[key] = samples
        advanceMinute(key)
        if let latest = latestMinute[key.symbol], key.minute < latest { compact(key) }
    }

    public var candles: [MinuteCandle] {
        let keys = Set(remote.keys).union(local.keys)
        return keys.compactMap { key in
            let samples = local[key]
            guard let authoritative = remote[key] else {
                return samples.flatMap { localCandle(key, $0) }
            }
            guard let samples else { return authoritative }
            let cutoff = completedRemote.contains(key) ? authoritative.minute.addingTimeInterval(60) : authoritative.lastEvent
            let tail = samples.events.filter { $0.time > cutoff }
            let restored = samples.restored.flatMap { $0.lastEvent > cutoff ? $0 : nil }
            guard !tail.isEmpty || restored != nil else { return authoritative }
            var high = authoritative.high
            var low = authoritative.low
            var close = authoritative.close
            var last = authoritative.lastEvent
            var observed = authoritative.observedAt
            if let restored {
                // If a cached aggregate straddles the remote observation, only
                // its final price is known to be newer; older extremes must not
                // leak into the refreshed authoritative OHLC.
                high = max(high, restored.firstEvent > cutoff ? restored.high : restored.close)
                low = min(low, restored.firstEvent > cutoff ? restored.low : restored.close)
                if restored.lastEvent >= last { close = restored.close; last = restored.lastEvent }
                observed = max(observed, restored.observedAt)
            }
            for event in tail.sorted(by: eventOrder) {
                high = max(high, event.price)
                low = min(low, event.price)
                if event.time >= last { close = event.price; last = event.time }
                observed = max(observed, event.receivedAt)
            }
            return MinuteCandle(symbol: key.symbol, minute: key.minute,
                open: authoritative.open, high: high, low: low, close: close, volume: nil,
                session: authoritative.session, origin: .mixed,
                firstEvent: authoritative.firstEvent, lastEvent: last, observedAt: observed,
                sampleCount: authoritative.sampleCount + samples.count)
        }.sorted { $0.minute == $1.minute ? $0.symbol < $1.symbol : $0.minute < $1.minute }
    }

    /// Merge validated cached projections without erasing already received
    /// live samples. Mixed bars retain provenance; a newer complete remote bar
    /// may replace them entirely.
    public mutating func restore(_ saved: [MinuteCandle]) {
        for candle in saved where CandleValidation.candle(candle) {
            let key = Key(candle)
            if candle.origin == .localSample {
                if let prior = local[key]?.restored, prior.observedAt > candle.observedAt { continue }
                var samples = local[key] ?? Samples()
                samples.restored = candle
                local[key] = samples
            } else {
                if let prior = remote[key], prior.observedAt >= candle.observedAt { continue }
                remote[key] = candle
                // The cache projection cannot prove whether a Yahoo-looking
                // row was assembled from partial observations. Wait for an
                // actual completed source response before superseding samples.
                completedRemote.remove(key)
            }
        }
    }

    private func localCandle(_ key: Key, _ samples: Samples) -> MinuteCandle? {
        let events = samples.events.sorted(by: eventOrder)
        guard let first = events.first else { return samples.restored }
        let last = events.last!
        let saved = samples.restored
        let firstTime = min(first.time, saved?.firstEvent ?? first.time)
        let lastTime = max(last.time, saved?.lastEvent ?? last.time)
        let open = saved.map { $0.firstEvent <= first.time ? $0.open : first.price } ?? first.price
        let close = saved.map { $0.lastEvent > last.time ? $0.close : last.price } ?? last.price
        let high = max(events.map(\.price).max()!, saved?.high ?? first.price)
        let low = min(events.map(\.price).min()!, saved?.low ?? first.price)
        let session = saved.map { $0.firstEvent <= first.time ? $0.session : first.session } ?? first.session
        return MinuteCandle(symbol: key.symbol, minute: key.minute, open: open, high: high, low: low,
            close: close, volume: nil, session: session, origin: .localSample,
            firstEvent: firstTime, lastEvent: lastTime,
            observedAt: max(events.map(\.receivedAt).max()!, saved?.observedAt ?? first.receivedAt),
            sampleCount: samples.count)
    }

    private func eventOrder(_ left: Event, _ right: Event) -> Bool {
        left.time == right.time ? left.receivedAt < right.receivedAt : left.time < right.time
    }

    private func isCompleteSourceBar(_ candle: MinuteCandle) -> Bool {
        candle.origin == .yahoo && candle.firstEvent == candle.minute
            && candle.observedAt >= candle.minute.addingTimeInterval(60)
    }

    private mutating func advanceMinute(_ key: Key) {
        guard latestMinute[key.symbol] == nil || key.minute > latestMinute[key.symbol]! else { return }
        latestMinute[key.symbol] = key.minute
        for previous in Array(local.keys) where previous.symbol == key.symbol && previous.minute < key.minute {
            compact(previous)
        }
    }

    private mutating func compact(_ key: Key) {
        guard let samples = local[key], !samples.events.isEmpty,
              let summary = localCandle(key, samples) else { return }
        local[key] = Samples(restored: summary)
    }
}

private enum CandleValidation {
    static func date(_ value: Date) -> Bool {
        value.timeIntervalSince1970.isFinite && (946_684_800..<4_102_444_800).contains(value.timeIntervalSince1970)
    }
    static func minute(_ value: Date) -> Date {
        Date(timeIntervalSince1970: floor(value.timeIntervalSince1970 / 60) * 60)
    }
    static func symbol(_ value: String) -> Bool {
        value.range(of: "^[A-Z][A-Z0-9.-]{0,11}$", options: .regularExpression) != nil
    }
    static func ohlc(_ open: Double, _ high: Double, _ low: Double, _ close: Double) -> Bool {
        [open, high, low, close].allSatisfy { $0.isFinite && $0 > 0 }
            && low <= min(open, close) && high >= max(open, close) && low <= high
    }
    static func candle(_ value: MinuteCandle) -> Bool {
        guard symbol(value.symbol), date(value.minute), minute(value.minute) == value.minute,
              date(value.firstEvent), date(value.lastEvent), date(value.observedAt),
              value.firstEvent >= value.minute, value.lastEvent < value.minute.addingTimeInterval(60),
              value.lastEvent <= value.observedAt.addingTimeInterval(30),
              value.firstEvent <= value.lastEvent, ohlc(value.open, value.high, value.low, value.close),
              value.sampleCount >= 0, value.sampleCount <= 10_000_000 else { return false }
        if let volume = value.volume, !volume.isFinite || volume < 0 { return false }
        switch value.origin {
        case .yahoo: return value.sampleCount == 0
        case .localSample, .mixed: return value.sampleCount > 0 && value.volume == nil
        }
    }
}
