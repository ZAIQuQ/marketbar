import Foundation

public enum AlertDirection: String, Codable, CaseIterable { case up, down, both }

public struct AlertConfiguration: Codable, Equatable {
    public var enabled: Bool
    public var direction: AlertDirection
    public var oneMinutePercent: Double
    public var threeMinutePercent: Double
    public var confirmationSeconds: Int
    public var cooldownSeconds: Int
    public var volatilityMultiplier: Double
    public var maximumSpreadPercent: Double

    public static let defaults = AlertConfiguration()

    public init(enabled: Bool = false, direction: AlertDirection = .up,
                oneMinutePercent: Double = 0.8, threeMinutePercent: Double = 1.5,
                confirmationSeconds: Int = 5, cooldownSeconds: Int = 300,
                volatilityMultiplier: Double = 3.5, maximumSpreadPercent: Double = 0.3) {
        self.enabled = enabled
        self.direction = direction
        self.oneMinutePercent = oneMinutePercent
        self.threeMinutePercent = threeMinutePercent
        self.confirmationSeconds = confirmationSeconds
        self.cooldownSeconds = cooldownSeconds
        self.volatilityMultiplier = volatilityMultiplier
        self.maximumSpreadPercent = maximumSpreadPercent
    }

    public var validationError: String? {
        guard oneMinutePercent.isFinite, (0.01...100).contains(oneMinutePercent),
              threeMinutePercent.isFinite, (0.01...100).contains(threeMinutePercent) else {
            return "涨跌阈值须为 0.01% 至 100% 的有限数值。"
        }
        guard (1...60).contains(confirmationSeconds) else { return "确认时间须为 1 至 60 秒。" }
        guard (30...86_400).contains(cooldownSeconds) else { return "冷却时间须为 30 秒至 24 小时。" }
        guard volatilityMultiplier.isFinite,
              volatilityMultiplier == 0 || (1...20).contains(volatilityMultiplier) else {
            return "波动倍数须为 1 至 20；0 表示关闭近期波动过滤。"
        }
        guard maximumSpreadPercent.isFinite, (0.01...5).contains(maximumSpreadPercent) else {
            return "最大价差须为 0.01% 至 5%。"
        }
        return nil
    }
}

public struct MarketAlert: Codable, Equatable, Identifiable {
    public let id: String
    public let symbol: String
    public let timestamp: Date
    public let direction: AlertDirection
    public let windowSeconds: Int
    public let changePercent: Double
    public let thresholdPercent: Double
    public let referencePrice: Double
    public let price: Double
    public let spreadPercent: Double
    public let confirmedSeconds: Int
    public let escalated: Bool

    public init(id: String, symbol: String, timestamp: Date, direction: AlertDirection,
                windowSeconds: Int, changePercent: Double, thresholdPercent: Double,
                referencePrice: Double, price: Double, spreadPercent: Double,
                confirmedSeconds: Int, escalated: Bool) {
        self.id = id; self.symbol = symbol; self.timestamp = timestamp; self.direction = direction
        self.windowSeconds = windowSeconds; self.changePercent = changePercent
        self.thresholdPercent = thresholdPercent; self.referencePrice = referencePrice
        self.price = price; self.spreadPercent = spreadPercent
        self.confirmedSeconds = confirmedSeconds; self.escalated = escalated
    }
}

public enum MonitorPhase: String { case off, warming, watching, confirming, stale, wideSpread, sparse }

public struct MonitorEvaluation {
    public let phase: MonitorPhase
    public let detail: String
    public let alert: MarketAlert?
    public let oneMinuteChange: Double?
    public let threeMinuteChange: Double?
    public let oneMinuteThreshold: Double?
    public let threeMinuteThreshold: Double?

    public init(phase: MonitorPhase, detail: String, alert: MarketAlert? = nil,
                oneMinuteChange: Double? = nil, threeMinuteChange: Double? = nil,
                oneMinuteThreshold: Double? = nil, threeMinuteThreshold: Double? = nil) {
        self.phase = phase; self.detail = detail; self.alert = alert
        self.oneMinuteChange = oneMinuteChange; self.threeMinuteChange = threeMinuteChange
        self.oneMinuteThreshold = oneMinuteThreshold; self.threeMinuteThreshold = threeMinuteThreshold
    }

    fileprivate var withoutAlert: MonitorEvaluation {
        MonitorEvaluation(phase: phase, detail: detail, oneMinuteChange: oneMinuteChange,
                          threeMinuteChange: threeMinuteChange, oneMinuteThreshold: oneMinuteThreshold,
                          threeMinuteThreshold: threeMinuteThreshold)
    }
}

/// A descriptive market-move monitor, not a position or execution model.
/// Live execution samples, ticker/BBO freshness, and completed-bar volatility
/// are separate inputs; cached candles can never satisfy live warm-up.
public struct AnomalyDetector {
    public let symbol: String
    public private(set) var configuration: AlertConfiguration

    private struct Signature: Hashable { let time: Double; let price: Double }
    private struct Bucket {
        var prices: [Double] = []
        var replacement = 0
        var signatures: Set<Signature> = []
        mutating func insert(_ signature: Signature) -> Bool {
            // Bound work and storage even if a very active contract emits a
            // large burst. Additional ticks in this second do not create time.
            guard signatures.count < 128, signatures.insert(signature).inserted else { return false }
            if prices.count < 9 { prices.append(signature.price) }
            else { prices[replacement] = signature.price; replacement = (replacement + 1) % 9 }
            return true
        }
        var median: Double { AnomalyDetector.median(prices) }
    }
    private struct Candidate {
        let direction: AlertDirection
        let started: Int64
        let startingExecutions: UInt64
        var evaluated: Int64
    }
    private struct Move {
        let seconds: Int
        let reference: Double
        let change: Double
        let threshold: Double
        var direction: AlertDirection { change >= 0 ? .up : .down }
    }

    private var buckets: [Int64: Bucket] = [:]
    private var completedBars: [Int64: MinuteCandle] = [:]
    private var firstLiveEvent: Date?
    private var lastTrade: PriceQuote?
    private var lastTradeReceived: Date?
    private var ticker: OKXTicker?
    private var tickerReceived: Date?
    private var executions: UInt64 = 0
    private var prunedAt: Int64?
    private var candidate: Candidate?
    private var lastAlerts: [AlertDirection: MarketAlert] = [:]
    private var evaluatedAt: Int64?
    private var evaluation = MonitorEvaluation(phase: .off, detail: "提醒未启用")

    public init(symbol: String, configuration: AlertConfiguration = .defaults) {
        self.symbol = symbol
        self.configuration = configuration
    }

    public mutating func configure(_ config: AlertConfiguration) {
        guard config != configuration else { return }
        configuration = config
        reset()
    }

    /// Reset live warm-up on a reconnect. Keep completed-bar context and alert
    /// cooldown so a transient connection failure cannot produce a new storm.
    public mutating func reset() {
        clearLive()
        lastTrade = nil; lastTradeReceived = nil; ticker = nil; tickerReceived = nil
        evaluatedAt = nil
        evaluation = MonitorEvaluation(phase: configuration.enabled ? .warming : .off,
                                       detail: configuration.enabled ? "等待连续的新成交" : "提醒未启用")
    }

    public mutating func ingestTrade(_ quote: PriceQuote, receivedAt: Date) {
        guard Instrument.isOKX(symbol), quote.symbol == symbol, quote.session == .perpetual,
              quote.source == .stream, quote.recordsPriceSample,
              quote.price.isFinite, quote.price > 0, validDate(quote.timestamp), validDate(receivedAt),
              quote.timestamp <= receivedAt.addingTimeInterval(3),
              receivedAt.timeIntervalSince(quote.timestamp) <= 5 else { return }
        if let previous = lastTrade {
            guard quote.timestamp >= previous.timestamp,
                  receivedAt >= (lastTradeReceived ?? receivedAt) else { return }
            if quote.timestamp.timeIntervalSince(previous.timestamp) > 10 { clearLive() }
        }
        let second = secondOf(quote.timestamp)
        var bucket = buckets[second] ?? Bucket()
        guard bucket.insert(Signature(time: quote.timestamp.timeIntervalSince1970, price: quote.price)) else { return }
        buckets[second] = bucket
        executions &+= 1
        firstLiveEvent = firstLiveEvent ?? quote.timestamp
        lastTrade = quote; lastTradeReceived = receivedAt
        if prunedAt != second {
            buckets = buckets.filter { $0.key >= second - 210 }
            prunedAt = second
        }
    }

    public mutating func ingestTicker(_ value: OKXTicker, receivedAt: Date) {
        guard value.quote.symbol == symbol, value.quote.session == .perpetual,
              validDate(value.quote.timestamp), validDate(receivedAt),
              value.quote.timestamp <= receivedAt.addingTimeInterval(3),
              receivedAt.timeIntervalSince(value.quote.timestamp) <= 5 else { return }
        if let previous = ticker, value.quote.timestamp < previous.quote.timestamp { return }
        ticker = value; tickerReceived = receivedAt
    }

    public mutating func ingestCandles(_ bars: [MinuteCandle]) {
        for bar in bars {
            guard bar.symbol == symbol, bar.origin == .okx, bar.isFinal == true,
                  bar.session == .perpetual, validDate(bar.minute), validDate(bar.observedAt),
                  bar.minute.timeIntervalSince1970.truncatingRemainder(dividingBy: 60) == 0,
                  bar.minute.addingTimeInterval(60) <= bar.observedAt.addingTimeInterval(3),
                  [bar.open, bar.high, bar.low, bar.close].allSatisfy({ $0.isFinite && $0 > 0 }),
                  bar.low <= min(bar.open, bar.close), bar.high >= max(bar.open, bar.close) else { continue }
            let key = secondOf(bar.minute)
            if let previous = completedBars[key], previous.observedAt > bar.observedAt { continue }
            completedBars[key] = bar
        }
        if completedBars.count > 180 {
            let keep = Set(completedBars.keys.sorted().suffix(180))
            completedBars = completedBars.filter { keep.contains($0.key) }
        }
    }

    public mutating func evaluate(at now: Date) -> MonitorEvaluation {
        guard validDate(now) else { candidate = nil; return MonitorEvaluation(phase: .stale, detail: "当前时间无效") }
        let second = secondOf(now)
        if let previous = evaluatedAt, second <= previous { return evaluation.withoutAlert }
        evaluatedAt = second
        guard configuration.enabled else { candidate = nil; return finish(.off, "提醒未启用") }
        guard configuration.validationError == nil, Instrument.isOKX(symbol) else {
            candidate = nil
            return finish(.off, configuration.validationError ?? "仅支持明确的 OKX USDT 永续合约")
        }
        guard let trade = lastTrade, let tradeReceived = lastTradeReceived,
              let ticker, let tickerReceived else {
            candidate = nil; return finish(.warming, "等待新成交及买卖报价")
        }
        guard trade.timestamp <= now, ticker.quote.timestamp <= now else {
            candidate = nil; return finish(.stale, "行情时间领先本机，等待时间对齐")
        }
        guard fresh(trade.timestamp, at: now), fresh(tradeReceived, at: now),
              fresh(ticker.quote.timestamp, at: now), fresh(tickerReceived, at: now) else {
            clearLive()
            return finish(.stale, "成交或报价超过 5 秒未更新，重新预热")
        }
        guard let bid = ticker.bid, let ask = ticker.ask, bid.isFinite, ask.isFinite,
              bid > 0, ask >= bid else {
            candidate = nil; return finish(.wideSpread, "等待有效的买卖报价")
        }
        let midpoint = bid + (ask - bid) / 2
        let spread = (ask - bid) / midpoint * 100
        guard spread.isFinite, spread <= configuration.maximumSpreadPercent else {
            candidate = nil; return finish(.wideSpread, "买卖价差过大，暂不提醒")
        }
        let recent = values(from: second - 4, through: second)
        guard recent.count >= 3 else { candidate = nil; return finish(.sparse, "最近 5 秒成交覆盖不足") }
        let price = Self.median(recent)
        guard abs(price / midpoint - 1) * 100 <= configuration.maximumSpreadPercent else {
            candidate = nil; return finish(.wideSpread, "成交中位价偏离买卖报价，等待确认")
        }
        guard let began = firstLiveEvent, now.timeIntervalSince(began) >= 60 else {
            candidate = nil; return finish(.warming, "积累至少 60 秒实时成交")
        }
        guard let sigma = configuration.volatilityMultiplier == 0 ? 0 : volatility(at: now) else {
            candidate = nil; return finish(.warming, "等待连续的已完成 K 线波动基准")
        }
        let threshold1 = max(configuration.oneMinutePercent, configuration.volatilityMultiplier * sigma)
        let threshold3 = max(configuration.threeMinutePercent, configuration.volatilityMultiplier * sigma * sqrt(3))
        let move1 = move(seconds: 60, at: second, current: price, threshold: threshold1, minimumCoverage: 20)
        let move3 = now.timeIntervalSince(began) >= 180
            ? move(seconds: 180, at: second, current: price, threshold: threshold3, minimumCoverage: 50) : nil
        let available = [move1, move3].compactMap { $0 }
        guard !available.isEmpty else {
            candidate = nil
            return finish(.sparse, "参考时间附近或窗口内的成交覆盖不足", one: move1, three: move3,
                          threshold1: threshold1, threshold3: threshold3)
        }
        let matching = available.filter { move in
            abs(move.change) >= move.threshold && (configuration.direction == .both || configuration.direction == move.direction)
        }
        guard let selected = matching.max(by: { abs($0.change) / $0.threshold < abs($1.change) / $1.threshold }) else {
            candidate = nil
            return finish(.watching, "监测中", one: move1, three: move3, threshold1: threshold1, threshold3: threshold3)
        }
        if var prior = candidate, prior.direction == selected.direction, prior.evaluated == second - 1 {
            prior.evaluated = second; candidate = prior
        } else {
            candidate = Candidate(direction: selected.direction, started: second,
                                  startingExecutions: executions, evaluated: second)
        }
        let current = candidate!
        let confirmed = Int(second - current.started)
        guard confirmed >= configuration.confirmationSeconds,
              executions &- current.startingExecutions >= 2 else {
            return finish(.confirming, "持续确认 \(confirmed)/\(configuration.confirmationSeconds) 秒，需新增真实成交",
                          one: move1, three: move3, threshold1: threshold1, threshold3: threshold3)
        }
        var escalated = false
        if let previous = lastAlerts[selected.direction] {
            let elapsed = now.timeIntervalSince(previous.timestamp)
            if elapsed < Double(configuration.cooldownSeconds) {
                let further = (price / previous.price - 1) * 100
                let adverse = selected.direction == .up ? further : -further
                guard elapsed >= 30, adverse >= configuration.oneMinutePercent else {
                    return finish(.watching, "冷却中，避免重复提醒", one: move1, three: move3,
                                  threshold1: threshold1, threshold3: threshold3)
                }
                escalated = true
            }
        }
        let alert = MarketAlert(id: "\(symbol)-\(second)-\(selected.direction.rawValue)-\(selected.seconds)",
            symbol: symbol, timestamp: now, direction: selected.direction, windowSeconds: selected.seconds,
            changePercent: selected.change, thresholdPercent: selected.threshold, referencePrice: selected.reference,
            price: price, spreadPercent: spread, confirmedSeconds: confirmed, escalated: escalated)
        lastAlerts[selected.direction] = alert
        return finish(.watching, escalated ? "已发出进一步变化提醒" : "已发出行情提醒", alert: alert,
                      one: move1, three: move3, threshold1: threshold1, threshold3: threshold3)
    }

    private mutating func clearLive() {
        buckets.removeAll(keepingCapacity: true); firstLiveEvent = nil; prunedAt = nil; candidate = nil
    }

    private mutating func finish(_ phase: MonitorPhase, _ detail: String, alert: MarketAlert? = nil,
                                 one: Move? = nil, three: Move? = nil,
                                 threshold1: Double? = nil, threshold3: Double? = nil) -> MonitorEvaluation {
        evaluation = MonitorEvaluation(phase: phase, detail: detail, alert: alert,
            oneMinuteChange: one?.change, threeMinuteChange: three?.change,
            oneMinuteThreshold: threshold1, threeMinuteThreshold: threshold3)
        return evaluation
    }

    private func move(seconds window: Int, at now: Int64, current: Double,
                      threshold: Double, minimumCoverage: Int) -> Move? {
        let center = now - Int64(window)
        let referenceValues = values(from: center - 3, through: center + 3)
        guard referenceValues.count >= 2,
              values(from: center, through: now).count >= minimumCoverage else { return nil }
        let reference = Self.median(referenceValues)
        let change = (current / reference - 1) * 100
        return change.isFinite ? Move(seconds: window, reference: reference, change: change, threshold: threshold) : nil
    }

    private func volatility(at now: Date) -> Double? {
        // Exclude the complete three-minute candidate window. The end of the
        // newest baseline candle must be at/before that exclusion boundary.
        let cutoff = floor((now.timeIntervalSince1970 - 180) / 60) * 60
        var expected = Int64(cutoff) - 60
        var bars: [MinuteCandle] = []
        while bars.count < 31, let bar = completedBars[expected], bar.observedAt <= now.addingTimeInterval(3) {
            bars.append(bar); expected -= 60
        }
        guard bars.count >= 21 else { return nil }
        bars.reverse()
        let returns = zip(bars.dropFirst(), bars).map { ($0.close / $1.close - 1) * 100 }
        guard returns.allSatisfy(\.isFinite) else { return nil }
        let center = Self.median(returns)
        return 1.4826 * Self.median(returns.map { abs($0 - center) })
    }

    private func values(from first: Int64, through last: Int64) -> [Double] {
        guard first <= last else { return [] }
        return (first...last).compactMap { buckets[$0]?.median }
    }

    private func fresh(_ timestamp: Date, at now: Date) -> Bool {
        let age = now.timeIntervalSince(timestamp)
        return age >= -3 && age <= 5
    }

    private func validDate(_ date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite && (946_684_800..<4_102_444_800).contains(date.timeIntervalSince1970)
    }

    private func secondOf(_ date: Date) -> Int64 { Int64(floor(date.timeIntervalSince1970)) }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : sorted[middle - 1] + (sorted[middle] - sorted[middle - 1]) / 2
    }
}
