import Combine
import Foundation
import TickerCore

/// Owns one stream and bounded snapshot refreshes. Quote timestamps, rather than
/// request completion order, decide which price is allowed onto the screen.
@MainActor
final class MarketStore: ObservableObject {
    let monitor: AlertMonitor
    @Published private(set) var symbols: [String]
    /// Nil preserves the previous automatic selection until the first edit.
    /// An empty array means the user intentionally wants the compact app name.
    @Published private(set) var selectedMenuSymbols: [String]?
    @Published private(set) var quotes: [String: PriceQuote] = [:]
    @Published private(set) var connectionText = "尚未连接"
    @Published private(set) var connected = false
    @Published private(set) var receivedAt: [String: Date] = [:]
    @Published private(set) var deliveryLag: [String: TimeInterval] = [:]
    @Published private(set) var symbolErrors: [String: String] = [:]
    @Published private(set) var candles: [String: [MinuteCandle]] = [:]
    @Published private(set) var chartReferences: [String: [String: ChartReference]] = [:]
    @Published private(set) var historyErrors: [String: String] = [:]
    @Published private(set) var historyLoading = false
    @Published private(set) var candleConnected = false
    @Published private(set) var candleConnectionText = "分钟推送未连接"
    @Published private(set) var candleReceivedAt: [String: Date] = [:]
    @Published private(set) var chartHistoryLoading: Set<String> = []
    @Published private(set) var chartHistoryErrors: [String: String] = [:]
    @Published private(set) var chartHistoryRevision: UInt64 = 0

    private let defaults: UserDefaults
    private let session: URLSession
    private let archive: CandleArchive?
    private var books: [String: CandleBook] = [:]
    private var loadedHistory: Set<String> = []
    private var blockedHistory: Set<String> = []
    private var storageFailures: [String: String] = [:]
    private var loadingHistory: Set<String> = []
    private var historyTasks: [String: Task<Void, Never>] = [:]
    private var dirtyDays: [String: Set<String>] = [:]
    private var persistenceTask: Task<Void, Never>?
    private var flushing = false
    private var running = false
    private var generation: UInt64 = 0
    private var socket: URLSessionWebSocketTask?
    private var streamTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?
    private var okxClient: OKXClient?
    private var candleClient: OKXCandleClient?
    private var monitorTask: Task<Void, Never>?
    private var candleStreamErrors: [String: String] = [:]
    private var candleFallbackErrors: [String: String] = [:]
    private var tradingSchedules: [String: EquityTradingSchedule] = [:]
    private var yahooConnected = false
    private var yahooStatus = "尚未连接"
    private var okxConnected = false
    private var okxStatus = "尚未连接"
    private var okxStreamErrors: [String: String] = [:]
    private struct ChartHistoryKey: Hashable {
        let symbol: String
        let range: ChartTimeRange
    }
    private struct ChartHistoryLoad {
        let key: ChartHistoryKey
        let identifier: UUID
        let task: Task<Void, Never>
    }
    private struct ChartHistoryFailure: Error {
        let message: String
    }
    private var chartHistoryLoads: [String: ChartHistoryLoad] = [:]
    private var chartHistoryRequests: Set<ChartHistoryKey> = []
    private var nextChartRequestAt: TimeInterval = 0

    func isConnected(symbol: String) -> Bool {
        Instrument.isOKX(symbol) ? okxConnected : yahooConnected
    }

    func connectionLabel(symbol: String) -> String {
        Instrument.isOKX(symbol) ? okxStatus : yahooStatus
    }

    func isStockClosed(_ symbol: String, at now: Date) -> Bool {
        EquityMarketClock.isClosed(symbol: symbol, at: now, schedule: tradingSchedules[symbol])
    }

    func menuSymbols(at now: Date) -> [String] {
        let hideClosed = defaults.object(forKey: "hideClosedStocks") == nil || defaults.bool(forKey: "hideClosedStocks")
        let candidates = selectedMenuSymbols ?? symbols
        let visible = candidates.filter { symbols.contains($0) && (!hideClosed || !isStockClosed($0, at: now)) }
        if selectedMenuSymbols != nil { return visible }
        let configured = defaults.integer(forKey: "menuSymbolCount")
        return Array(visible.prefix(configured == 0 ? 2 : min(3, max(1, configured))))
    }

    func isSelectedForMenu(_ symbol: String, at now: Date = Date()) -> Bool {
        (selectedMenuSymbols ?? menuSymbols(at: now)).contains(symbol)
    }

    func setSelectedForMenu(_ symbol: String, selected: Bool, at now: Date = Date()) {
        guard symbols.contains(symbol) else { return }
        if let saved = selectedMenuSymbols, saved.contains(symbol) == selected { return }
        var selection = selectedMenuSymbols ?? menuSymbols(at: now)
        selection.removeAll { $0 == symbol }
        if selected { selection.append(symbol) }
        guard selection != selectedMenuSymbols else { return }
        selectedMenuSymbols = selection
        defaults.set(selection, forKey: "MarketBar.menuSymbols")
    }

    func watchlistSymbols(at now: Date) -> [String] {
        var trading: [String] = []
        var closed: [String] = []
        for symbol in symbols {
            if isStockClosed(symbol, at: now) { closed.append(symbol) }
            else { trading.append(symbol) }
        }
        return trading + closed
    }

    func ensureMonitoringTarget() -> Bool {
        if symbols.contains(monitor.symbol) { return true }
        guard symbols.count < 12 else { return false }
        setSymbols(symbols + [monitor.symbol])
        return true
    }

    private func updateConnectionSummary() {
        let usesYahoo = symbols.contains { !Instrument.isOKX($0) }
        let usesOKX = symbols.contains { Instrument.isOKX($0) }
        connected = (!usesYahoo || yahooConnected) && (!usesOKX || okxConnected)
        if usesYahoo && usesOKX {
            connectionText = connected ? "行情已连接" : "Yahoo：\(yahooStatus) · OKX：\(okxStatus)"
        } else { connectionText = usesOKX ? okxStatus : yahooStatus }
    }

    private func updateYahooStatus(_ value: Bool, _ text: String) {
        yahooConnected = value
        yahooStatus = text
        updateConnectionSummary()
    }

    init(defaults: UserDefaults = .standard, archive: CandleArchive? = CandleArchive()) {
        self.defaults = defaults
        self.archive = archive
        monitor = AlertMonitor(defaults: defaults, systemEffects: defaults === UserDefaults.standard)
        let stored = defaults.stringArray(forKey: "MarketBar.watchlist") ?? ["AMD", "NVDA"]
        let normalized = (try? Watchlist.parse(stored.joined(separator: ","))) ?? ["AMD", "NVDA"]
        symbols = normalized
        if let saved = defaults.stringArray(forKey: "MarketBar.menuSymbols") {
            var seen = Set<String>()
            selectedMenuSymbols = saved.filter { normalized.contains($0) && seen.insert($0).inserted }
        } else { selectedMenuSymbols = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration)
        if !symbols.contains(monitor.symbol), monitor.isEnabled {
            var settings = monitor.configuration
            settings.enabled = false
            _ = monitor.updateConfiguration(settings)
        }
    }

    func start() {
        guard !running else { return }
        running = true
        generation &+= 1
        chartHistoryRevision = generation
        let token = generation
        prepareHistory()
        if symbols.contains(where: { !Instrument.isOKX($0) }) {
            streamTask = Task { [weak self] in await self?.runStream(generation: token) }
        }
        let okxSymbols = symbols.filter { Instrument.isOKX($0) }
        if !okxSymbols.isEmpty {
            let client = OKXClient(onTicker: { [weak self] ticker in
                guard let self, self.isCurrent(token) else { return }
                let now = Date()
                self.ingest(ticker.quote, received: now)
                self.monitor.ingestTicker(ticker, receivedAt: now)
                if let reference = ticker.reference {
                    self.chartReferences[ticker.quote.symbol, default: [:]][reference.day] = reference
                    self.dirtyDays[ticker.quote.symbol, default: []].insert(reference.day)
                }
            }, onTrades: { [weak self] trades in
                guard let self, self.isCurrent(token) else { return }
                self.ingestTrades(trades, received: Date())
            }, onStatus: { [weak self] connected, message in
                guard let self, self.isCurrent(token) else { return }
                self.okxConnected = connected
                self.okxStatus = message
                self.updateConnectionSummary()
                if !connected { self.monitor.setConnected(false, reason: message) }
            }, onError: { [weak self] symbol, message in
                guard let self, self.isCurrent(token) else { return }
                self.okxStreamErrors[symbol] = message.isEmpty ? nil : message
                self.symbolErrors[symbol] = self.okxStreamErrors[symbol]
            }, onReadiness: { [weak self] symbol, ready, message in
                guard let self, self.isCurrent(token), symbol == self.monitor.symbol else { return }
                self.monitor.setConnected(ready, reason: message)
            })
            okxClient = client
            client.start(symbols: okxSymbols)
            let candleClient = OKXCandleClient(onCandles: { [weak self] bars in
                guard let self, self.isCurrent(token) else { return }
                self.ingestRemoteCandles(bars)
                let now = Date()
                for symbol in Set(bars.map(\.symbol)) {
                    self.candleReceivedAt[symbol] = now
                    self.candleFallbackErrors[symbol] = nil
                    self.updateHistoryError(symbol)
                }
            }, onStatus: { [weak self] connected, message in
                guard let self, self.isCurrent(token) else { return }
                self.candleConnected = connected
                self.candleConnectionText = message
            }, onError: { [weak self] symbol, message in
                guard let self, self.isCurrent(token) else { return }
                self.candleStreamErrors[symbol] = message.isEmpty ? nil : message
                self.updateHistoryError(symbol)
            })
            self.candleClient = candleClient
            candleClient.start(symbols: okxSymbols)
        }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isCurrent(token) else { return }
                self.monitor.tick(at: Date())
                do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                catch { return }
            }
        }
        refreshSnapshots()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 60_000_000_000) }
                catch { return }
                guard let self, self.isCurrent(token) else { return }
                self.refreshSnapshots()
            }
        }
        persistenceTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 10_000_000_000) }
                catch { return }
                guard let self, self.isCurrent(token) else { return }
                await self.flushHistory()
            }
        }
    }

    func stop() {
        running = false
        generation &+= 1
        chartHistoryRevision = generation
        for load in chartHistoryLoads.values { load.task.cancel() }
        chartHistoryLoads.removeAll()
        chartHistoryRequests.removeAll()
        chartHistoryLoading.removeAll()
        streamTask?.cancel()
        keepaliveTask?.cancel()
        pollingTask?.cancel()
        snapshotTask?.cancel()
        okxClient?.stop()
        okxClient = nil
        candleClient?.stop()
        candleClient = nil
        monitorTask?.cancel()
        monitorTask = nil
        monitor.setConnected(false, reason: "行情已暂停，恢复后重新预热")
        candleConnected = false
        candleConnectionText = "分钟推送已暂停"
        persistenceTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        streamTask = nil
        keepaliveTask = nil
        pollingTask = nil
        snapshotTask = nil
        persistenceTask = nil
        historyLoading = false
        socket = nil
        connected = false
        yahooConnected = false
        okxConnected = false
        yahooStatus = "已暂停"
        okxStatus = "已暂停"
        connectionText = "已暂停"
        Task { await flushHistory() }
    }

    func reconnect() {
        stop()
        start()
    }

    func setSymbols(_ values: [String]) {
        guard let normalized = try? Watchlist.parse(values.joined(separator: ",")),
              normalized != symbols else { return }
        let wasRunning = running
        stop()
        symbols = normalized
        defaults.set(normalized, forKey: "MarketBar.watchlist")
        if let selection = selectedMenuSymbols {
            let retained = selection.filter { normalized.contains($0) }
            selectedMenuSymbols = retained
            defaults.set(retained, forKey: "MarketBar.menuSymbols")
        }
        if !symbols.contains(monitor.symbol), monitor.isEnabled {
            var configuration = monitor.configuration
            configuration.enabled = false
            _ = monitor.updateConfiguration(configuration)
        }
        let selected = Set(normalized)
        quotes = quotes.filter { selected.contains($0.key) }
        receivedAt = receivedAt.filter { selected.contains($0.key) }
        deliveryLag = deliveryLag.filter { selected.contains($0.key) }
        symbolErrors = symbolErrors.filter { selected.contains($0.key) }
        if wasRunning { start() }
    }

    func refreshSnapshots() {
        guard running, snapshotTask == nil else { return }
        let token = generation
        let requestedSymbols = symbols
        let client = session
        historyLoading = true
        snapshotTask = Task { [weak self] in
            await withTaskGroup(of: SnapshotResult.self) { group in
                for symbol in requestedSymbols {
                    group.addTask { await Self.fetchSnapshot(symbol: symbol, session: client) }
                }
                for await result in group {
                    guard let self, self.isCurrent(token), !Task.isCancelled else {
                        group.cancelAll()
                        return
                    }
                    if let quote = result.quote {
                        self.ingest(quote, received: Date())
                        self.symbolErrors[result.symbol] = self.okxStreamErrors[result.symbol]
                    } else if let error = result.error {
                        // A failed fallback request is separate from transport health.
                        self.symbolErrors[result.symbol] = error
                    }
                    if let schedule = result.schedule { self.tradingSchedules[result.symbol] = schedule }
                    if let reference = result.reference {
                        self.chartReferences[result.symbol, default: [:]][reference.day] = reference
                        self.dirtyDays[result.symbol, default: []].insert(reference.day)
                    }
                    if let bars = result.candles, !bars.isEmpty {
                        self.ingestRemoteCandles(bars)
                        self.candleFallbackErrors[result.symbol] = nil
                    } else {
                        let freshStream = self.candleReceivedAt[result.symbol].map { Date().timeIntervalSince($0) <= 5 } ?? false
                        self.candleFallbackErrors[result.symbol] = freshStream ? nil
                            : result.error ?? "线上分钟数据暂不可用，保留已有数据和本机采样。"
                    }
                    self.updateHistoryError(result.symbol)
                }
            }
            guard let self, self.isCurrent(token) else { return }
            self.snapshotTask = nil
            self.historyLoading = false
        }
    }

    /// False for stale, future-dated or unsolicited quotes. Snapshot responses
    /// must never rewind a more recent streamed price.
    @discardableResult
    func ingest(_ quote: PriceQuote, received: Date) -> Bool {
        guard symbols.contains(quote.symbol), quote.price.isFinite, quote.price > 0,
              quote.timestamp.timeIntervalSince1970.isFinite,
              quote.timestamp <= received.addingTimeInterval(30) else { return false }
        if quote.source == .stream && quote.recordsPriceSample { recordSample(quote, received: received) }
        if let previous = quotes[quote.symbol] {
            guard quote.timestamp >= previous.timestamp else { return false }
            if quote.timestamp == previous.timestamp,
               previous.source == .stream, quote.source == .snapshot { return false }
        }
        quotes[quote.symbol] = quote
        receivedAt[quote.symbol] = received
        if quote.source == .stream {
            deliveryLag[quote.symbol] = received.timeIntervalSince(quote.timestamp)
            symbolErrors[quote.symbol] = okxStreamErrors[quote.symbol]
        } else {
            deliveryLag[quote.symbol] = nil
        }
        return true
    }

    private func isCurrent(_ token: UInt64) -> Bool {
        running && generation == token
    }

    private func updateHistoryError(_ symbol: String) {
        historyErrors[symbol] = storageFailures[symbol] ?? candleStreamErrors[symbol] ?? candleFallbackErrors[symbol]
    }

    private func recordSample(_ quote: PriceQuote, received: Date) {
        guard symbols.contains(quote.symbol), quote.recordsPriceSample,
              quote.timestamp <= received.addingTimeInterval(30) else { return }
        var book = books[quote.symbol] ?? CandleBook()
        book.ingest(quote, receivedAt: received)
        books[quote.symbol] = book
        candles[quote.symbol] = book.candles
        markDirty(quote.symbol, minutes: [quote.timestamp])
    }

    func ingestTrades(_ trades: [PriceQuote], received: Date) {
        for trade in trades where Instrument.isOKX(trade.symbol) { recordSample(trade, received: received) }
        monitor.ingestTrades(trades, receivedAt: received)
    }

    func ingestRemoteCandles(_ bars: [MinuteCandle]) {
        for (symbol, rows) in Dictionary(grouping: bars, by: \.symbol) where symbols.contains(symbol) {
            var book = books[symbol] ?? CandleBook()
            book.mergeRemote(rows)
            books[symbol] = book
            candles[symbol] = book.candles
            markDirty(symbol, minutes: rows.map(\.minute))
            monitor.ingestCandles(rows)
        }
    }

    /// One bounded backfill for the selected absolute chart window. It never
    /// changes the latest ticker, 24h change or the per-day reference prices.
    func loadChartHistory(symbol: String, minutes: Int, anchor: Date) async {
        guard running, symbols.contains(symbol), Instrument.isOKX(symbol),
              ChartWindow.range(minutes: minutes, anchor: anchor) != nil else { return }
        let token = generation
        let day = Instrument.day(symbol, at: anchor)
        // Let startup cache/snapshot loading establish the newest known minute
        // on this date before freezing a request. Later ticks do not relaunch it.
        if let task = historyTasks[symbol] { await task.value }
        if let task = snapshotTask { await task.value }
        guard isCurrent(token), !Task.isCancelled, symbols.contains(symbol) else { return }
        let latest = candles[symbol]?.last(where: { Instrument.day(symbol, at: $0.minute) == day })?.minute ?? anchor
        guard let range = ChartWindow.range(minutes: minutes, anchor: latest) else { return }
        let key = ChartHistoryKey(symbol: symbol, range: range)
        if ChartWindow.missingMinutes(in: range, symbol: symbol, candles: candles[symbol] ?? []).isEmpty {
            chartHistoryErrors[symbol] = nil
            chartHistoryRequests.insert(key)
            return
        }
        if chartHistoryRequests.contains(key) { return }
        if let active = chartHistoryLoads[symbol], active.key == key {
            await withTaskCancellationHandler(operation: { await active.task.value },
                                              onCancel: { active.task.cancel() })
            return
        }
        chartHistoryLoads[symbol]?.task.cancel()
        let identifier = UUID()
        chartHistoryErrors[symbol] = nil
        chartHistoryLoading.insert(symbol)
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.backfillChart(key: key, identifier: identifier, generation: token)
        }
        chartHistoryLoads[symbol] = ChartHistoryLoad(key: key, identifier: identifier, task: task)
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    /// A deliberate refresh can retry a previously searched but unavailable gap.
    func allowChartHistoryRetry(symbol: String) {
        chartHistoryRequests = chartHistoryRequests.filter { $0.symbol != symbol }
        chartHistoryErrors[symbol] = nil
    }

    private func backfillChart(key: ChartHistoryKey, identifier: UUID, generation token: UInt64) async {
        let symbol = key.symbol
        func current() -> Bool {
            isCurrent(token) && symbols.contains(symbol)
                && chartHistoryLoads[symbol]?.identifier == identifier && !Task.isCancelled
        }
        defer {
            if chartHistoryLoads[symbol]?.identifier == identifier {
                chartHistoryLoads[symbol] = nil
                chartHistoryLoading.remove(symbol)
            }
        }
        var searched: [ChartTimeRange] = []
        let limit = min(16, Int(ceil(key.range.duration / 6_000)) + 1)
        do {
            for _ in 0..<limit {
                guard current() else { return }
                guard let cursor = ChartWindow.nextHistoryCursor(in: key.range, symbol: symbol,
                    candles: candles[symbol] ?? [], searched: searched) else { break }
                // Main-actor reservations also bound requests when the user
                // switches instruments while an old request is being cancelled.
                while ProcessInfo.processInfo.systemUptime < nextChartRequestAt {
                    let delay = max(0, nextChartRequestAt - ProcessInfo.processInfo.systemUptime)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard current() else { return }
                }
                guard current() else { return }
                nextChartRequestAt = ProcessInfo.processInfo.systemUptime + 0.55
                let bars = try await Self.fetchChartHistoryPage(symbol: symbol, before: cursor, session: session)
                guard current() else { return }
                guard !bars.contains(where: { $0.minute >= cursor }) else {
                    throw ChartHistoryFailure(message: "历史数据时间范围异常，已有行情已保留。")
                }
                guard let first = bars.first?.minute else { break }
                searched.append(ChartTimeRange(start: first, end: cursor))
                let relevant = bars.filter { key.range.contains($0.minute) }
                if !relevant.isEmpty { ingestRemoteCandles(relevant) }
            }
            guard current() else { return }
            chartHistoryRequests.insert(key)
            let missing = ChartWindow.missingMinutes(in: key.range, symbol: symbol, candles: candles[symbol] ?? [])
            if !missing.isEmpty {
                chartHistoryErrors[symbol] = "部分历史分钟未能回填；已有行情保留，缺口不补造。"
            } else { chartHistoryErrors[symbol] = nil }
        } catch {
            guard current() else { return }
            chartHistoryErrors[symbol] = (error as? ChartHistoryFailure)?.message
                ?? "历史分钟回填失败，已有行情已保留。可稍后手动刷新。"
        }
    }

    private nonisolated static func fetchChartHistoryPage(symbol: String, before cursor: Date,
                                                         session: URLSession) async throws -> [MinuteCandle] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.okx.com"
        components.path = "/api/v5/market/history-candles"
        components.queryItems = [URLQueryItem(name: "instId", value: symbol),
            URLQueryItem(name: "bar", value: "1m"), URLQueryItem(name: "limit", value: "100"),
            URLQueryItem(name: "after", value: String(Int64(cursor.timeIntervalSince1970 * 1_000)))]
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if response.statusCode == 429 {
            throw ChartHistoryFailure(message: "历史分钟请求被限流，请稍后手动刷新。")
        }
        guard response.statusCode == 200, data.count <= 4_194_304 else { throw URLError(.badServerResponse) }
        return try OKXDecoder.candles(data, expectedSymbol: symbol, receivedAt: Date())
    }

    private func runStream(generation token: UInt64) async {
        var failures = 0
        while isCurrent(token), !Task.isCancelled {
            updateYahooStatus(false, failures == 0 ? "正在连接推送…" : "正在重新连接…")
            var request = URLRequest(url: URL(string: "wss://streamer.finance.yahoo.com/?version=2")!)
            request.setValue("Mozilla/5.0 MarketBar/1.0", forHTTPHeaderField: "User-Agent")
            let currentSocket = session.webSocketTask(with: request)
            socket = currentSocket
            currentSocket.resume()
            let began = Date()
            do {
                try await subscribe(on: currentSocket)
                guard isCurrent(token), !Task.isCancelled else {
                    currentSocket.cancel(with: .goingAway, reason: nil)
                    return
                }
                updateYahooStatus(true, "推送已连接 · 等待报价")
                startKeepalive(on: currentSocket, generation: token)
                while isCurrent(token), !Task.isCancelled {
                    let message = try await currentSocket.receive()
                    let text: String?
                    switch message {
                    case .string(let value): text = value
                    case .data(let data): text = String(data: data, encoding: .utf8)
                    @unknown default: text = nil
                    }
                    guard isCurrent(token), !Task.isCancelled else { return }
                    if let text {
                        do {
                            if let quote = try YahooDecoder.stream(text) {
                                let accepted = ingest(quote, received: Date())
                                if accepted, yahooStatus != "推送已连接" { updateYahooStatus(true, "推送已连接") }
                            }
                        } catch {
                            updateYahooStatus(true, "推送格式异常 · 使用备用快照")
                        }
                    }
                }
            } catch {
                guard isCurrent(token), !Task.isCancelled else { return }
            }
            guard isCurrent(token), !Task.isCancelled else { return }
            keepaliveTask?.cancel()
            keepaliveTask = nil
            currentSocket.cancel(with: .goingAway, reason: nil)
            if socket === currentSocket { socket = nil }
            if Date().timeIntervalSince(began) >= 30 { failures = 0 }
            failures = min(failures + 1, 6)
            let delay = min(pow(2, Double(failures)), 60) + Double.random(in: 0...1)
            updateYahooStatus(false, "推送断开 · \(Int(delay)) 秒后重连")
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
        }
    }

    private func subscribe(on socket: URLSessionWebSocketTask) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["subscribe": symbols.filter { !Instrument.isOKX($0) }])
        try await socket.send(.string(String(decoding: body, as: UTF8.self)))
    }

    private func startKeepalive(on currentSocket: URLSessionWebSocketTask, generation token: UInt64) {
        keepaliveTask?.cancel()
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 15_000_000_000) }
                catch { return }
                guard let self, self.isCurrent(token), self.socket === currentSocket else { return }
                do {
                    try await self.subscribe(on: currentSocket)
                    try await Self.ping(currentSocket)
                } catch {
                    guard self.isCurrent(token), self.socket === currentSocket else { return }
                    // Cancelling wakes the receive loop, the sole owner of retries.
                    currentSocket.cancel(with: .goingAway, reason: nil)
                    return
                }
            }
        }
    }

    private nonisolated static func ping(_ socket: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion = PingCompletion(continuation)
            socket.sendPing { error in
                completion.finish(error)
            }
            // A half-open connection must not remain labelled connected forever.
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                completion.finish(URLError(.timedOut))
            }
        }
    }

    private final class PingCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?

        init(_ continuation: CheckedContinuation<Void, Error>) {
            self.continuation = continuation
        }

        func finish(_ error: Error?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            guard let pending else { return }
            if let error { pending.resume(throwing: error) }
            else { pending.resume() }
        }
    }

    private struct SnapshotResult: @unchecked Sendable {
        let symbol: String
        let quote: PriceQuote?
        let candles: [MinuteCandle]?
        let reference: ChartReference?
        let schedule: EquityTradingSchedule?
        let error: String?
    }

    private nonisolated static func fetchSnapshot(symbol: String, session: URLSession) async -> SnapshotResult {
        if Instrument.isOKX(symbol) { return await fetchOKXSnapshot(symbol: symbol, session: session) }
        var lastError = "备用快照暂不可用"
        for host in ["query2.finance.yahoo.com", "query1.finance.yahoo.com"] {
            guard !Task.isCancelled else { break }
            var components = URLComponents()
            components.scheme = "https"
            components.host = host
            components.path = "/v8/finance/chart/\(symbol)"
            components.queryItems = [
                URLQueryItem(name: "interval", value: "1m"),
                URLQueryItem(name: "range", value: "1d"),
                URLQueryItem(name: "includePrePost", value: "true")
            ]
            guard let url = components.url else { continue }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse else { continue }
                guard response.statusCode == 200 else {
                    switch response.statusCode {
                    case 404: lastError = "未找到此股票的快照"
                    case 429: lastError = "备用快照被限流 · 稍后重试"
                    default: lastError = "备用快照请求失败（\(response.statusCode)）"
                    }
                    continue
                }
                do {
                    let result = try YahooDecoder.chart(data, expectedSymbol: symbol)
                    let bars = try? CandleDecoder.chart(data, expectedSymbol: symbol, receivedAt: Date())
                    let reference = try? ChartReferenceDecoder.chart(data, expectedSymbol: symbol)
                    let schedule = EquityMarketClock.schedule(from: data, fetchedAt: Date())
                    return SnapshotResult(symbol: symbol, quote: result.quote, candles: bars,
                                          reference: reference, schedule: schedule, error: nil)
                } catch {
                    lastError = "备用快照无有效报价或格式异常"
                }
            } catch {
                if Task.isCancelled { break }
                lastError = "备用快照网络连接失败"
            }
        }
        return SnapshotResult(symbol: symbol, quote: nil, candles: nil, reference: nil, schedule: nil, error: lastError)
    }

    private nonisolated static func fetchOKXSnapshot(symbol: String, session: URLSession) async -> SnapshotResult {
        async let tickerData = okxData(path: "/api/v5/market/ticker", symbol: symbol, candles: false, session: session)
        async let candleData = okxData(path: "/api/v5/market/candles", symbol: symbol, candles: true, session: session)
        let (tickerResult, candleResult) = await (tickerData, candleData)
        var ticker: OKXTicker?
        var bars: [MinuteCandle]?
        var failure: String?
        do { ticker = try OKXDecoder.ticker(tickerResult.get(), expectedSymbol: symbol, source: .snapshot) }
        catch { failure = "OKX 报价暂不可用：\(error.localizedDescription)" }
        do { bars = try OKXDecoder.candles(candleResult.get(), expectedSymbol: symbol, receivedAt: Date()) }
        catch { if failure == nil { failure = "OKX 分钟数据暂不可用" } }
        return SnapshotResult(symbol: symbol, quote: ticker?.quote, candles: bars,
                              reference: ticker?.reference, schedule: nil, error: failure)
    }

    private nonisolated static func okxData(path: String, symbol: String, candles: Bool,
                                           session: URLSession) async -> Result<Data, Error> {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.okx.com"
        components.path = path
        components.queryItems = [URLQueryItem(name: "instId", value: symbol)]
        if candles {
            components.queryItems! += [URLQueryItem(name: "bar", value: "1m"), URLQueryItem(name: "limit", value: "300")]
        }
        guard let url = components.url else { return .failure(URLError(.badURL)) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 4_194_304 else {
                return .failure(URLError(.badServerResponse))
            }
            return .success(data)
        } catch { return .failure(error) }
    }

    func prepareHistory() {
        guard let archive else { return }
        for symbol in symbols where !loadedHistory.contains(symbol) && !loadingHistory.contains(symbol) {
            loadingHistory.insert(symbol)
            historyTasks[symbol] = Task { [weak self] in
                do {
                    let saved = try await archive.loadBundle(symbol: symbol)
                    guard let self else { return }
                    var book = self.books[symbol] ?? CandleBook()
                    book.restore(saved.candles)
                    self.books[symbol] = book
                    self.candles[symbol] = book.candles
                    self.chartReferences[symbol, default: [:]].merge(saved.references) { current, _ in current }
                    self.loadedHistory.insert(symbol)
                    self.blockedHistory.remove(symbol)
                    if self.storageFailures.removeValue(forKey: symbol) != nil { self.updateHistoryError(symbol) }
                } catch {
                    guard let self else { return }
                    self.blockedHistory.insert(symbol)
                    let message = "本地历史读取失败，已保留原文件：\(error.localizedDescription)"
                    self.storageFailures[symbol] = message
                    self.historyErrors[symbol] = message
                }
                self?.loadingHistory.remove(symbol)
                self?.historyTasks[symbol] = nil
            }
        }
    }

    private func markDirty(_ symbol: String, minutes: [Date]) {
        for minute in minutes { dirtyDays[symbol, default: []].insert(Instrument.day(symbol, at: minute)) }
    }

    func finishHistory() async {
        for task in Array(historyTasks.values) { await task.value }
        await flushHistory()
    }

    /// Runs off-main-thread disk writes through the archive actor; a failed
    /// save remains dirty for retry, and corrupted archives are never replaced.
    func flushHistory() async {
        guard let archive else { return }
        while flushing {
            do { try await Task.sleep(nanoseconds: 30_000_000) }
            catch { return }
        }
        flushing = true
        defer { flushing = false }
        let pending = dirtyDays
        for (symbol, days) in pending {
            guard loadedHistory.contains(symbol), !blockedHistory.contains(symbol),
                  let book = books[symbol] else { continue }
            let bars = book.candles.filter { days.contains(Instrument.day(symbol, at: $0.minute)) }
            dirtyDays[symbol]?.subtract(days)
            do {
                try await archive.save(symbol: symbol, candles: bars, references: chartReferences[symbol] ?? [:])
                if storageFailures.removeValue(forKey: symbol) != nil { updateHistoryError(symbol) }
            }
            catch {
                dirtyDays[symbol, default: []].formUnion(days)
                let message = "本地保存失败：\(error.localizedDescription)"
                storageFailures[symbol] = message
                historyErrors[symbol] = message
            }
        }
    }

}
