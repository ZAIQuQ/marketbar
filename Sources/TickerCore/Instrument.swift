import Foundation

/// Explicit OKX IDs keep spot, perpetuals, and stock tickers separate. Bare
/// BTC and SOXL retain their stock meanings; watchlist aliases are deliberate.
public enum Instrument {
    public static func isOKX(_ symbol: String) -> Bool {
        isOKXSpot(symbol) || isOKXPerpetual(symbol)
    }

    public static func isOKXPerpetual(_ symbol: String) -> Bool {
        let value = symbol.uppercased()
        guard value.hasSuffix("-USDT-SWAP") else { return false }
        let base = value.dropLast(10).utf8
        return (1...22).contains(base.count) && base.allSatisfy { (65...90).contains($0) || (48...57).contains($0) }
    }

    public static func isOKXSpot(_ symbol: String) -> Bool {
        let value = symbol.uppercased()
        guard value.hasSuffix("-USDT") else { return false }
        let base = value.dropLast(5).utf8
        return (1...27).contains(base.count) && base.allSatisfy { (65...90).contains($0) || (48...57).contains($0) }
    }

    public static func marketSession(_ symbol: String) -> TradingSession {
        if isOKXSpot(symbol) { return .spot }
        if isOKXPerpetual(symbol) { return .perpetual }
        return .unknown
    }

    public static func displaySymbol(_ symbol: String) -> String {
        guard isOKX(symbol) else { return symbol }
        let value = isOKXPerpetual(symbol) ? String(symbol.uppercased().dropLast(5)) : symbol.uppercased()
        return value.replacingOccurrences(of: "-", with: "")
    }

    public static func currency(_ symbol: String) -> String { isOKX(symbol) ? "USDT" : "USD" }

    public static func timeZone(_ symbol: String) -> TimeZone {
        isOKX(symbol) ? TimeZone(secondsFromGMT: 0)! : TimeZone(identifier: "America/New_York")!
    }

    public static func day(_ symbol: String, at date: Date) -> String {
        guard date.timeIntervalSince1970.isFinite else { return "" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone(symbol)
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return "" }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func validSymbol(_ symbol: String) -> Bool {
        guard symbol == symbol.uppercased() else { return false }
        if isOKX(symbol) { return true }
        // Reject unsupported derivative/spot syntax rather than send it to Yahoo.
        if symbol.contains("-USDT") || symbol.hasSuffix("-SWAP") { return false }
        return symbol.range(of: "^[A-Z][A-Z0-9.-]{0,11}$", options: .regularExpression) != nil
    }
}
