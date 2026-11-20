import Combine
import Foundation
import TickerCore

/// Owns one stream and bounded snapshot refreshes. Quote timestamps, rather than
/// request completion order, decide which price is allowed onto the screen.
@MainActor
final class MarketStore: ObservableObject {
    @Published private(set) var symbols: [String]
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

    init(defaults: UserDefaults = .standard, archive: CandleArchive? = CandleArchive()) {
        self.defaults = defaults
        self.archive = archive
        let stored = defaults.stringArray(forKey: "MarketBar.watchlist") ?? ["AMD", "NVDA"]
        symbols = (try? Watchlist.parse(stored.joined(separator: ","))) ?? ["AMD", "NVDA"]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration)
    }

    func start() {
        guard !running else { return }
        running = true
        generation &+= 1
        let token = generation
        prepareHistory()
        streamTask = Task { [weak self] in
            await self?.runStream(generation: token)
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
        streamTask?.cancel()
        keepaliveTask?.cancel()
        pollingTask?.cancel()
        snapshotTask?.cancel()
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
                        self.symbolErrors[result.symbol] = nil
                    } else if let error = result.error {
                        // A failed fallback request is separate from transport health.
                        self.symbolErrors[result.symbol] = error
                    }
                    if let reference = result.reference {
                        self.chartReferences[result.symbol, default: [:]][reference.day] = reference
                        self.dirtyDays[result.symbol, default: []].insert(reference.day)
                    }
                    if let bars = result.candles, !bars.isEmpty {
                        var book = self.books[result.symbol] ?? CandleBook()
                        book.mergeRemote(bars)
                        self.books[result.symbol] = book
                        self.candles[result.symbol] = book.candles
                        self.markDirty(result.symbol, minutes: bars.map(\.minute))
                        self.historyErrors[result.symbol] = self.storageFailures[result.symbol]
                    } else {
                        self.historyErrors[result.symbol] = self.storageFailures[result.symbol]
                            ?? result.error ?? "线上分钟数据暂不可用，保留已有数据和本机采样。"
                    }
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
        if quote.source == .stream {
            var book = books[quote.symbol] ?? CandleBook()
            book.ingest(quote, receivedAt: received)
            books[quote.symbol] = book
            candles[quote.symbol] = book.candles
            markDirty(quote.symbol, minutes: [quote.timestamp])
        }
        if let previous = quotes[quote.symbol] {
            guard quote.timestamp >= previous.timestamp else { return false }
            if quote.timestamp == previous.timestamp,
               previous.source == .stream, quote.source == .snapshot { return false }
        }
        quotes[quote.symbol] = quote
        receivedAt[quote.symbol] = received
        if quote.source == .stream {
            deliveryLag[quote.symbol] = received.timeIntervalSince(quote.timestamp)
            symbolErrors[quote.symbol] = nil
        } else {
            deliveryLag[quote.symbol] = nil
        }
        return true
    }

    private func isCurrent(_ token: UInt64) -> Bool {
        running && generation == token
    }

    private func runStream(generation token: UInt64) async {
        var failures = 0
        while isCurrent(token), !Task.isCancelled {
            connected = false
            connectionText = failures == 0 ? "正在连接推送…" : "正在重新连接…"
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
                connected = true
                connectionText = "推送已连接 · 等待报价"
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
                                if accepted, connectionText != "推送已连接" {
                                    connectionText = "推送已连接"
                                }
                            }
                        } catch {
                            connectionText = "推送格式异常 · 使用备用快照"
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
            connected = false
            if Date().timeIntervalSince(began) >= 30 { failures = 0 }
            failures = min(failures + 1, 6)
            let delay = min(pow(2, Double(failures)), 60) + Double.random(in: 0...1)
            connectionText = "推送断开 · \(Int(delay)) 秒后重连"
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
        }
    }

    private func subscribe(on socket: URLSessionWebSocketTask) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["subscribe": symbols])
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
        let error: String?
    }

    private nonisolated static func fetchSnapshot(symbol: String, session: URLSession) async -> SnapshotResult {
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
                    return SnapshotResult(symbol: symbol, quote: result.quote, candles: bars, reference: reference, error: nil)
                } catch {
                    lastError = "备用快照无有效报价或格式异常"
                }
            } catch {
                if Task.isCancelled { break }
                lastError = "备用快照网络连接失败"
            }
        }
        return SnapshotResult(symbol: symbol, quote: nil, candles: nil, reference: nil, error: lastError)
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
                    if self.storageFailures.removeValue(forKey: symbol) != nil { self.historyErrors[symbol] = nil }
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
        for minute in minutes { dirtyDays[symbol, default: []].insert(Self.historyDay(minute)) }
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
            let bars = book.candles.filter { days.contains(Self.historyDay($0.minute)) }
            dirtyDays[symbol]?.subtract(days)
            do {
                try await archive.save(symbol: symbol, candles: bars, references: chartReferences[symbol] ?? [:])
                if storageFailures.removeValue(forKey: symbol) != nil { historyErrors[symbol] = nil }
            }
            catch {
                dirtyDays[symbol, default: []].formUnion(days)
                let message = "本地保存失败：\(error.localizedDescription)"
                storageFailures[symbol] = message
                historyErrors[symbol] = message
            }
        }
    }

    private static func historyDay(_ date: Date) -> String {
        historyDateFormatter.string(from: date)
    }

    private static let historyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")!
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
