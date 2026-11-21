import Foundation
import TickerCore

/// Exchange-generated minute bars use OKX's business socket, separate from the
/// public ticker/trades socket. No account credentials or trading operations.
@MainActor
final class OKXCandleClient {
    private let onCandles: ([MinuteCandle]) -> Void
    private let onStatus: (Bool, String) -> Void
    private let onError: (String, String) -> Void
    private let onReadiness: ((String, Bool, String) -> Void)?
    private let session: URLSession
    private var symbols: [String] = []
    private var requestIDs: [String: String] = [:]
    private var acknowledged: Set<String> = []
    private var subscriptionErrors: [String: String] = [:]
    private var reportedErrors: [String: String] = [:]
    private var lastStatus: (connected: Bool, text: String)?
    private var running = false
    private var generation: UInt64 = 0
    private var socket: URLSessionWebSocketTask?
    private var streamTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var heartbeat = TransportHeartbeat(now: 0)
    private var disconnectReason: String?
    private var lastReadiness: [String: (ready: Bool, reason: String)] = [:]
    private var connectionAttempt = 0

    private struct Reconnect: Error {
        let reason: String
        var minimumDelay: TimeInterval = 0
    }

    init(onCandles: @escaping ([MinuteCandle]) -> Void,
         onStatus: @escaping (Bool, String) -> Void,
         onError: @escaping (String, String) -> Void,
         onReadiness: ((String, Bool, String) -> Void)? = nil) {
        self.onCandles = onCandles
        self.onStatus = onStatus
        self.onError = onError
        self.onReadiness = onReadiness
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 12
        session = URLSession(configuration: configuration)
    }

    func start(symbols incoming: [String]) {
        var valid: [String] = []
        for symbol in incoming {
            guard symbol == symbol.uppercased(), Instrument.isOKX(symbol) else {
                reportError(symbol, "OKX 分钟订阅需要完整现货或永续代码")
                continue
            }
            if !valid.contains(symbol) { valid.append(symbol) }
        }
        guard valid.count <= 12 else {
            for symbol in valid { reportError(symbol, "最多同时订阅 12 个交易对或合约") }
            stop()
            return
        }
        if running, valid == symbols { return }
        stop()
        symbols = valid
        guard !valid.isEmpty else { return }
        requestIDs = Dictionary(uniqueKeysWithValues: valid.enumerated().map { ("c\($0.offset)", $0.element) })
        running = true
        generation &+= 1
        let token = generation
        streamTask = Task { [weak self] in await self?.run(generation: token) }
    }

    func stop() {
        running = false
        generation &+= 1
        streamTask?.cancel()
        watchdogTask?.cancel()
        pingTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        streamTask = nil
        watchdogTask = nil
        pingTask = nil
        socket = nil
        acknowledged.removeAll()
        for symbol in symbols { publishReadiness(symbol) }
        publishStatus(false, "OKX 分钟推送已暂停")
    }

    private func current(_ token: UInt64, socket candidate: URLSessionWebSocketTask? = nil) -> Bool {
        running && generation == token && (candidate == nil || socket === candidate)
    }

    private func publishStatus(_ connected: Bool, _ text: String) {
        guard lastStatus?.connected != connected || lastStatus?.text != text else { return }
        lastStatus = (connected, text)
        onStatus(connected, text)
    }

    private func reportError(_ symbol: String, _ text: String) {
        // An initial empty callback also clears a warning held by the store
        // from a previous client instance. Subsequent empty callbacks dedupe.
        guard reportedErrors[symbol] != text else { return }
        reportedErrors[symbol] = text
        onError(symbol, text)
    }

    private func publishSubscriptions() {
        for symbol in symbols { publishReadiness(symbol) }
        if !subscriptionErrors.isEmpty {
            publishStatus(!acknowledged.isEmpty,
                          acknowledged.isEmpty ? "OKX 分钟订阅失败" : "OKX 部分分钟订阅异常")
        } else if !acknowledged.isEmpty {
            publishStatus(true, acknowledged.count == symbols.count
                          ? "OKX 分钟推送已连接" : "OKX 分钟推送等待部分确认")
        }
    }

    private func markReady(_ symbol: String) {
        heartbeat.observeValidFrame(at: ProcessInfo.processInfo.systemUptime)
        acknowledged.insert(symbol)
        subscriptionErrors[symbol] = nil
        reportError(symbol, "")
        publishSubscriptions()
    }

    private func isReady(_ symbol: String) -> Bool {
        TransportReadiness.isReady(required: ["candle1m"],
            acknowledged: acknowledged.contains(symbol) ? ["candle1m"] : [],
            failed: subscriptionErrors[symbol] != nil ? ["candle1m"] : [])
    }

    private func publishReadiness(_ symbol: String) {
        let ready = running && isReady(symbol)
        let reason = !running ? "OKX 分钟推送已暂停" : ready ? "OKX 分钟推送已就绪"
            : subscriptionErrors[symbol] ?? "OKX 正在确认分钟订阅"
        guard lastReadiness[symbol]?.ready != ready || lastReadiness[symbol]?.reason != reason else { return }
        lastReadiness[symbol] = (ready, reason)
        RuntimeDiagnostics.shared.record(category: "okx_candle", event: ready ? "subscription_ready" : "subscription_pending",
            fields: ["symbol": symbol, "channel": "candle1m", "ready": ready, "generation": generation, "attempt": connectionAttempt])
        onReadiness?(symbol, ready, reason)
    }

    private func notePendingTimeouts(elapsed: TimeInterval) {
        guard elapsed >= 20 else { return }
        for symbol in symbols where !acknowledged.contains(symbol) && subscriptionErrors[symbol] == nil {
            subscriptionErrors[symbol] = "OKX 分钟订阅确认超时"
            reportError(symbol, "OKX 分钟订阅确认超时")
            RuntimeDiagnostics.shared.record(category: "okx_candle", event: "subscription_timeout",
                fields: ["symbol": symbol, "channel": "candle1m", "elapsed": elapsed, "attempt": connectionAttempt])
        }
        publishSubscriptions()
    }

    private func run(generation token: UInt64) async {
        var failures = 0
        while current(token), !Task.isCancelled {
            acknowledged.removeAll()
            subscriptionErrors.removeAll()
            disconnectReason = nil
            connectionAttempt += 1
            for symbol in symbols { publishReadiness(symbol) }
            RuntimeDiagnostics.shared.record(category: "okx_candle", event: "connecting",
                fields: ["generation": token, "attempt": connectionAttempt])
            publishStatus(false, failures == 0 ? "OKX 分钟推送正在连接…" : "OKX 分钟推送正在重连…")
            let connection = session.webSocketTask(with: URL(string: "wss://ws.okx.com/ws/v5/business")!)
            connection.maximumMessageSize = 2_097_152
            socket = connection
            let began = ProcessInfo.processInfo.systemUptime
            heartbeat = TransportHeartbeat(now: began)
            connection.resume()
            startWatchdog(socket: connection, generation: token, began: began)
            var failure = Reconnect(reason: "OKX 分钟推送断开")
            do {
                for (identifier, symbol) in requestIDs.sorted(by: { $0.key < $1.key }) {
                    guard current(token, socket: connection), !Task.isCancelled else { return }
                    let data = try JSONSerialization.data(withJSONObject: [
                        "id": identifier, "op": "subscribe",
                        "args": [["channel": "candle1m", "instId": symbol]]
                    ])
                    try await connection.send(.string(String(decoding: data, as: UTF8.self)))
                }
                guard current(token, socket: connection), !Task.isCancelled else { return }
                publishStatus(false, "OKX 分钟推送等待订阅确认…")
                while current(token, socket: connection), !Task.isCancelled {
                    let frame = try await connection.receive()
                    guard current(token, socket: connection), !Task.isCancelled else { return }
                    let data: Data
                    switch frame {
                    case .string(let text):
                        if text == "pong" { heartbeat.observeValidFrame(at: ProcessInfo.processInfo.systemUptime); continue }
                        data = Data(text.utf8)
                    case .data(let value):
                        if value == Data("pong".utf8) { heartbeat.observeValidFrame(at: ProcessInfo.processInfo.systemUptime); continue }
                        data = value
                    @unknown default: continue
                    }
                    try handle(data)
                }
            } catch let reason as Reconnect { failure = reason }
            catch {
                failure = Reconnect(reason: disconnectReason ?? "OKX 分钟推送断开")
                if current(token, socket: connection), !Task.isCancelled {
                    var fields = RuntimeDiagnostics.errorFields(error)
                    fields["attempt"] = connectionAttempt
                    fields["closeCode"] = connection.closeCode.rawValue
                    RuntimeDiagnostics.shared.record(category: "okx_candle", event: "disconnected", fields: fields)
                }
            }
            guard current(token, socket: connection), !Task.isCancelled else { return }
            watchdogTask?.cancel()
            pingTask?.cancel()
            watchdogTask = nil
            pingTask = nil
            connection.cancel(with: .goingAway, reason: nil)
            socket = nil
            if ProcessInfo.processInfo.systemUptime - began >= 60, !acknowledged.isEmpty { failures = 0 }
            acknowledged.removeAll()
            for symbol in symbols { publishReadiness(symbol) }
            failures = min(failures + 1, 6)
            let delay = max(failure.minimumDelay, min(pow(2, Double(failures)), 60)) + Double.random(in: 0...1)
            RuntimeDiagnostics.shared.record(category: "okx_candle", event: "reconnect",
                fields: ["attempt": connectionAttempt, "seconds": delay,
                         "lastValidAge": ProcessInfo.processInfo.systemUptime - heartbeat.lastValidAt])
            publishStatus(false, "\(failure.reason) · \(Int(delay)) 秒后重连")
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
        }
    }

    private func startWatchdog(socket connection: URLSessionWebSocketTask, generation token: UInt64,
                               began: TimeInterval) {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                catch { return }
                guard let self, self.current(token, socket: connection) else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if self.heartbeat.action(at: now) == .reconnect {
                    self.disconnectReason = "OKX 分钟推送心跳超时"
                    RuntimeDiagnostics.shared.record(category: "okx_candle", event: "heartbeat_timeout",
                        fields: ["attempt": self.connectionAttempt, "lastValidAge": now - self.heartbeat.lastValidAt,
                                 "pingAge": now - (self.heartbeat.pingSentAt ?? now), "reason": "ping_deadline"])
                    connection.cancel(with: .goingAway, reason: nil)
                    return
                }
                let hadUnconfirmed = self.symbols.contains { !self.acknowledged.contains($0) && self.subscriptionErrors[$0] == nil }
                self.notePendingTimeouts(elapsed: now - began)
                if hadUnconfirmed, now - began >= 20, !self.symbols.contains(where: { self.isReady($0) }) {
                    self.disconnectReason = "OKX 分钟订阅确认超时"
                    connection.cancel(with: .goingAway, reason: nil)
                    return
                }
                if self.heartbeat.action(at: now) == .sendPing {
                    self.heartbeat.beginPing(at: now)
                    // Do not suspend the watchdog while a send is stalled.
                    self.pingTask = Task { [weak self] in
                        do { try await connection.send(.string("ping")) }
                        catch {
                            guard let self, self.current(token, socket: connection) else { return }
                            self.disconnectReason = "OKX 分钟推送心跳发送失败"
                            RuntimeDiagnostics.shared.record(category: "okx_candle", event: "heartbeat_send_error",
                                fields: RuntimeDiagnostics.errorFields(error))
                            connection.cancel(with: .goingAway, reason: nil)
                        }
                    }
                }
            }
        }
    }

    private func handle(_ data: Data) throws {
        guard data.count <= 2_097_152,
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Reconnect(reason: "OKX 分钟推送返回格式异常")
        }
        let argument = message["arg"] as? [String: Any]
        let symbol = (argument?["instId"] as? String).flatMap { symbols.contains($0) ? $0 : nil }
        let expectedChannel = argument?["channel"] as? String == "candle1m"
        if let event = message["event"] as? String {
            switch event {
            case "subscribe":
                if let symbol, expectedChannel { markReady(symbol) }
            case "error":
                let code = message["code"] as? String ?? "未知"
                let target = symbol ?? (message["id"] as? String).flatMap { requestIDs[$0] }
                let affected = target.map { [$0] } ?? symbols
                let text = code == "60018" ? "OKX 未找到该品种的分钟频道（60018）" : "OKX 分钟订阅失败（\(code)）"
                for value in affected {
                    acknowledged.remove(value)
                    subscriptionErrors[value] = text
                    reportError(value, text)
                    RuntimeDiagnostics.shared.record(category: "okx_candle", event: "subscription_error",
                        fields: ["symbol": value, "channel": "candle1m", "apiCode": code, "attempt": connectionAttempt])
                }
                publishSubscriptions()
                if code == "60014" { throw Reconnect(reason: "OKX 分钟订阅限流", minimumDelay: 30) }
                let permanent = ["60008", "60011", "60012", "60013", "60018", "60019", "60027", "60028", "60033", "64000", "64001"]
                if !permanent.contains(code) { throw Reconnect(reason: "OKX 分钟服务暂不可用") }
            case "notice":
                if message["code"] as? String == "64008" {
                    throw Reconnect(reason: "OKX 分钟服务升级", minimumDelay: 3)
                }
            default: break
            }
            return
        }
        guard let symbol, expectedChannel else { return }
        do {
            let candles = try OKXDecoder.candles(data, expectedSymbol: symbol, receivedAt: Date())
            if !candles.isEmpty {
                markReady(symbol)
                // No minute deduplication: partial updates and the final
                // confirm=1 update must all reach the store's merge policy.
                onCandles(candles)
            } else if let rows = message["data"] as? [Any], !rows.isEmpty {
                if subscriptionErrors[symbol] != "OKX 分钟数据没有有效 K 线" {
                    RuntimeDiagnostics.shared.record(category: "okx_candle", event: "decode_error",
                        fields: ["symbol": symbol, "channel": "candle1m", "reason": "decoder_rejected"])
                }
                subscriptionErrors[symbol] = "OKX 分钟数据没有有效 K 线"
                reportError(symbol, subscriptionErrors[symbol]!)
                publishSubscriptions()
            }
        } catch {
            if subscriptionErrors[symbol] != "OKX 分钟数据格式异常" {
                RuntimeDiagnostics.shared.record(category: "okx_candle", event: "decode_error",
                    fields: ["symbol": symbol, "channel": "candle1m", "reason": "decoder_rejected"])
            }
            subscriptionErrors[symbol] = "OKX 分钟数据格式异常"
            reportError(symbol, subscriptionErrors[symbol]!)
            publishSubscriptions()
        }
    }
}
