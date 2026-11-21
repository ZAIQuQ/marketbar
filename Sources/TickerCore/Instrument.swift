import Foundation

/// Explicit OKX perpetual IDs stay separate from stock tickers. SOXL by itself
/// is the US ETF; only SOXLUSDT or SOXL-USDT-SWAP selects the perpetual.
public enum Instrument {
    public static func isOKX(_ symbol: String) -> Bool {
        symbol.uppercased().range(of: "^[A-Z0-9]{1,22}-USDT-SWAP$", options: .regularExpression) != nil
    }

    public static func displaySymbol(_ symbol: String) -> String {
        guard isOKX(symbol) else { return symbol }
        return String(symbol.uppercased().dropLast(5)).replacingOccurrences(of: "-", with: "")
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
