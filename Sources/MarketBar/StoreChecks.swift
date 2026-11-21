import Foundation
import TickerCore

/// Deterministic acceptance checks for quote arbitration and local state.
/// Never starts a network connection or touches the real watchlist preferences.
@MainActor
func runStoreChecks() -> Bool {
    let suite = "MarketBar.StoreChecks.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
        print("FAIL store checks: isolated preferences unavailable")
        return false
    }
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(["AMD", "NVDA"], forKey: "MarketBar.watchlist")
    let store = MarketStore(defaults: defaults, archive: nil)
    defer { store.stop() }

    var count = 0
    var failures: [String] = []
    func check(_ condition: @autoclosure () -> Bool, _ description: String) {
        count += 1
        if !condition() { failures.append(description) }
    }
    check(runChartWindowChecks(), "chart time windows and missing-history request boundaries")
    let time = Date(timeIntervalSince1970: 1_700_000_000)
    let received = time.addingTimeInterval(2)
    func quote(_ symbol: String = "AMD", price: Double = 100,
               offset: TimeInterval = 0, source: QuoteSource = .stream) -> PriceQuote {
        PriceQuote(symbol: symbol, price: price, timestamp: time.addingTimeInterval(offset),
                   session: .pre, source: source, changePercent: 1.25)
    }

    let first = quote()
    check(store.ingest(first, received: received), "initial stream accepted")
    check(store.quotes["AMD"] == first, "initial stream retained exactly")
    check(store.deliveryLag["AMD"] == 2, "delivery age uses receipt minus quote time")

    check(!store.ingest(quote(price: 90, offset: -60, source: .snapshot), received: received),
          "older snapshot rejected")
    check(store.quotes["AMD"] == first, "older snapshot cannot rewind displayed price")
    check(!store.ingest(quote(price: 90, source: .snapshot), received: received.addingTimeInterval(5)),
          "equal-timestamp snapshot cannot replace stream")
    check(store.receivedAt["AMD"] == received, "rejected snapshot cannot refresh receipt time")
    check(store.deliveryLag["AMD"] == 2, "rejected snapshot cannot overwrite stream delivery age")

    check(store.ingest(quote("NVDA", source: .snapshot), received: received),
          "initial snapshot accepted")
    let tieStream = quote("NVDA", price: 101)
    check(store.ingest(tieStream, received: received), "stream replaces equal-timestamp snapshot")
    check(store.quotes["NVDA"] == tieStream, "equal-timestamp arbitration prefers stream")

    check(!store.ingest(quote(price: 99, offset: -1), received: received), "out-of-order stream rejected")
    check(!store.ingest(quote(offset: 33), received: received), "quote over 30 seconds in future rejected")
    check(!store.ingest(quote("AAPL"), received: received), "unsolicited symbol rejected")
    for invalidPrice in [0.0, -1.0, Double.nan, Double.infinity] {
        check(!store.ingest(quote(price: invalidPrice), received: received),
              "non-positive or non-finite price rejected: \(invalidPrice)")
    }
    let invalidTime = PriceQuote(symbol: "AMD", price: 100,
                                 timestamp: Date(timeIntervalSince1970: .nan),
                                 session: .pre, source: .stream)
    check(!store.ingest(invalidTime, received: received), "non-finite timestamp rejected")
    check(store.quotes["AMD"] == first, "invalid and out-of-order data preserve valid price")

    let newerSnapshot = quote(price: 102, offset: 60, source: .snapshot)
    let laterReceipt = time.addingTimeInterval(62)
    check(store.ingest(newerSnapshot, received: laterReceipt), "newer snapshot accepted")
    check(store.quotes["AMD"] == newerSnapshot, "newer snapshot remains labelled snapshot")
    check(store.receivedAt["AMD"] == laterReceipt, "accepted snapshot updates receipt time")
    check(store.deliveryLag["AMD"] == nil, "snapshot cannot retain misleading stream delivery age")

    store.setSymbols(["AMD"])
    check(store.symbols == ["AMD"], "watchlist removal applied")
    check(store.quotes["AMD"] == newerSnapshot, "watchlist retains selected quote")
    check(store.quotes["NVDA"] == nil && store.receivedAt["NVDA"] == nil
          && store.deliveryLag["NVDA"] == nil && store.symbolErrors["NVDA"] == nil,
          "watchlist removal filters per-symbol records")
    check(defaults.stringArray(forKey: "MarketBar.watchlist") == ["AMD"],
          "watchlist persisted to isolated preferences")
    check(!store.ingest(tieStream, received: laterReceipt), "removed symbol cannot reappear")
    store.stop()
    check(!store.connected && store.connectionText == "已暂停", "stop reports disconnected and paused")
    check(store.quotes["AMD"] == newerSnapshot, "stop preserves last valid quote")

    store.setSymbols(["AMD", "SOXLUSDT"])
    let contract = "SOXL-USDT-SWAP"
    let ticker = PriceQuote(symbol: contract, price: 33, timestamp: received,
                            session: .perpetual, source: .stream, changePercent: -25,
                            recordsPriceSample: false)
    check(store.symbols == ["AMD", contract], "OKX alias becomes an explicit perpetual instrument")
    check(store.ingest(ticker, received: received), "OKX ticker accepted")
    check(store.candles[contract]?.isEmpty ?? true, "ticker activity does not fabricate traded candles")
    let trade = PriceQuote(symbol: contract, price: 32.95, timestamp: time,
                          session: .perpetual, source: .stream)
    store.ingestTrades([trade], received: received)
    check(store.quotes[contract] == ticker, "trade history does not rewind latest ticker or its 24h percentage")
    check(store.candles[contract]?.last?.close == 32.95, "actual OKX trade records a local minute")
    let weekend = ISO8601DateFormatter().date(from: "2026-11-21T15:00:00Z")!
    check(store.menuSymbols(at: weekend) == [contract], "closed stocks are filtered before menu slots are selected")
    defaults.set(false, forKey: "hideClosedStocks")
    check(store.menuSymbols(at: weekend) == ["AMD", contract], "closed-stock hiding can be disabled")

    if failures.isEmpty {
        print("PASS store checks: \(count) deterministic checks (no network)")
        return true
    }
    print("FAIL store checks: \(failures.count)/\(count)")
    for failure in failures { print("  \(failure)") }
    return false
}

@MainActor
func runHistoryIntegrationChecks() async -> Bool {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MarketBarLifecycle-\(UUID().uuidString)")
    let suite = "MarketBar.HistoryChecks.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }
    let archive = CandleArchive(directory: folder)
    let store = MarketStore(defaults: defaults, archive: archive)
    // Queue disk loading, receive a quote, then quit before the loading task
    // has a chance to run. No network is started by this integration check.
    store.prepareHistory()
    let now = Date()
    store.ingest(PriceQuote(symbol: "AMD", price: 123, timestamp: now,
                           session: .pre, source: .stream), received: now)
    store.stop()
    await store.finishHistory()
    do {
        let saved = try await archive.load(symbol: "AMD")
        guard saved.count == 1, saved[0].close == 123, saved[0].origin == .localSample else {
            print("FAIL history lifecycle: shutdown lost the quote received during disk loading")
            return false
        }
        let reloaded = MarketStore(defaults: defaults, archive: archive)
        reloaded.prepareHistory()
        await reloaded.finishHistory()
        guard reloaded.candles["AMD"] == saved else {
            print("FAIL history lifecycle: offline restart did not restore saved candles")
            return false
        }
        print("PASS history lifecycle: immediate shutdown and offline restore (no network)")
        return true
    } catch {
        print("FAIL history lifecycle: \(error.localizedDescription)")
        return false
    }
}
