import Foundation

public enum TradingSession: String, Codable, CaseIterable {
    case pre, regular, post, closed, unknown

    public var label: String {
        switch self {
        case .pre: return "盘前"
        case .regular: return "盘中"
        case .post: return "盘后"
        case .closed: return "休市时段"
        case .unknown: return "时段未知"
        }
    }

    /// A time-of-day fallback, not an exchange holiday/early-close calendar.
    /// Always pass the quote's timestamp, not the computer's current time.
    public static func inferred(at timestamp: Date) -> TradingSession {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: timestamp)
        guard let weekday = parts.weekday, (2...6).contains(weekday),
              let hour = parts.hour, let minute = parts.minute else { return .closed }
        switch hour * 60 + minute {
        case 240..<570: return .pre
        case 570..<960: return .regular
        case 960..<1200: return .post
        default: return .closed
        }
    }
}

public enum QuoteSource: String, Codable {
    case stream, snapshot

    public var label: String {
        switch self {
        case .stream: return "推送"
        case .snapshot: return "分钟快照"
        }
    }
}

public struct PriceQuote: Equatable {
    public let symbol: String
    public let price: Double
    public let timestamp: Date
    public let session: TradingSession
    public let source: QuoteSource
    public let changePercent: Double?

    public init(symbol: String, price: Double, timestamp: Date, session: TradingSession,
                source: QuoteSource, changePercent: Double? = nil) {
        self.symbol = symbol
        self.price = price
        self.timestamp = timestamp
        self.session = session
        self.source = source
        self.changePercent = changePercent
    }
}

public struct ChartSnapshot {
    public let quote: PriceQuote
    public let previousClose: Double?
    /// The latest regular-session price reported by Yahoo. During trading this
    /// is not yet a final close; after regular trading it is the post-market base.
    public let regularClose: Double?

    public init(quote: PriceQuote, previousClose: Double?, regularClose: Double?) {
        self.quote = quote
        self.previousClose = previousClose
        self.regularClose = regularClose
    }
}

public enum Watchlist {
    public static func parse(_ input: String) throws -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",，;；"))
        let parts = input.uppercased().components(separatedBy: separators).filter { !$0.isEmpty }
        guard !parts.isEmpty else { throw QuoteError.invalidWatchlist("请至少输入一只股票代码。") }
        var symbols: [String] = []
        for raw in parts {
            let symbol = raw == "NVIDIA" ? "NVDA" : raw
            guard symbol.range(of: "^[A-Z][A-Z0-9.-]{0,11}$", options: .regularExpression) != nil else {
                throw QuoteError.invalidWatchlist("无效股票代码：\(raw)。请使用 AMD、NVDA 等美股代码。")
            }
            if !symbols.contains(symbol) { symbols.append(symbol) }
        }
        guard symbols.count <= 12 else { throw QuoteError.invalidWatchlist("最多关注 12 只股票。") }
        return symbols
    }
}

public enum QuoteError: Error, LocalizedError {
    case malformedData
    case missingQuote
    case unexpectedSymbol
    case providerError
    case invalidWatchlist(String)

    public var errorDescription: String? {
        switch self {
        case .malformedData: return "行情数据格式无效。"
        case .missingQuote: return "暂未取得有效报价。"
        case .unexpectedSymbol: return "行情返回的股票代码与请求不一致。"
        case .providerError: return "数据源暂时无法提供这只股票的行情。"
        case .invalidWatchlist(let message): return message
        }
    }
}
