import Foundation
import TickerCore

/// Public market data only. Ticker snapshots and executed trades deliberately
/// have separate callbacks: a ticker's generation time is not a trade time.
@MainActor
final class OKXClient {
    private let onTicker: (OKXTicker) -> Void
    private let onTrades: ([PriceQuote]) -> Void
    private let onStatus: (Bool, String) -> Void
    private let onError: (String, String) -> Void
    private let onReadiness: ((String, Bool, String) -> Void)?
    private let session: URLSession

    private struct Subscription: Hashable {
        let symbol: String
        let channel: String
    }

    private struct Reconnect: Error {
        let reason: String
        var minimumDelay: TimeInterval = 0
    }

    private var symbols: [String] = []
    private var requested: Set<Subscription> = []
    private var requestIDs: [String: [Subscription]] = [:]
    private var acknowledged: Set<Subscription> = []
    private var channelErrors: [Subscription: String] = [:]
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

    init(onTicker: @escaping (OKXTicker) -> Void,
         onTrades: @escaping ([PriceQuote]) -> Void,
         onStatus: @escaping (Bool, String) -> Void,
         onError: @escaping (String, String) -> Void,
         onReadiness: ((String, Bool, String) -> Void)? = nil) {
        self.onTicker = onTicker
        self.onTrades = onTrades
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
                reportError(symbol, "OKX 需要完整交易代码，例如 BTC-USDT 或 SOXL-USDT-SWAP")
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
        requested = Set(valid.flatMap { symbol in
            [Subscription(symbol: symbol, channel: "tickers"), Subscription(symbol: symbol, channel: "trades")]
        })
        // One request per instrument lets id-only errors remain scoped to that
        // instrument; each request contains both channels and is sent once.
        requestIDs = Dictionary(uniqueKeysWithValues: valid.enumerated().map { index, symbol in
            ("m\(index)", [Subscription(symbol: symbol, channel: "tickers"),
                           Subscription(symbol: symbol, channel: "trades")])
        })
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
        publishStatus(false, "OKX 已暂停")
    }

    private func current(_ token: UInt64, socket candidate: URLSessionWebSocketTask? = nil) -> Bool {
        running && generation == token && (candidate == nil || socket === candidate)
    }

    private func publishStatus(_ connected: Bool, _ text: String) {
        guard lastStatus?.connected != connected || lastStatus?.text != text else { return }
        lastStatus = (connected, text)
        onStatus(connected, text)
    }

    /// An empty message clears a previously reported warning for this symbol.
    private func reportError(_ symbol: String, _ message: String) {
        guard reportedErrors[symbol] != message else { return }
        reportedErrors[symbol] = message
        onError(symbol, message)
    }

    private func publishSubscriptionState(for symbol: String? = nil) {
        for value in symbol.map({ [$0] }) ?? symbols {
            let warnings = Set(channelErrors.filter { $0.key.symbol == value }.map(\.value)).sorted()
            if !warnings.isEmpty {
                reportError(value, warnings.joined(separator: "；"))
            } else if requested.filter({ $0.symbol == value }).allSatisfy({ acknowledged.contains($0) }) {
                reportError(value, "")
            }
            publishReadiness(value)
        }
        let ready = !acknowledged.isEmpty
        if !channelErrors.isEmpty {
            publishStatus(ready, ready ? "OKX 部分订阅异常" : "OKX 订阅失败")
        } else if ready {
            publishStatus(true, acknowledged == requested ? "OKX 推送已连接" : "OKX 已连接 · 等待部分订阅")
        }
    }

    private func markReady(_ subscription: Subscription) {
        heartbeat.observeValidFrame(at: ProcessInfo.processInfo.systemUptime)
        acknowledged.insert(subscription)
        channelErrors[subscription] = nil
        publishSubscriptionState(for: subscription.symbol)
    }

    private func isReady(_ symbol: String) -> Bool {
        TransportReadiness.isReady(required: ["tickers", "trades"],
            acknowledged: Set(acknowledged.filter { $0.symbol == symbol }.map(\.channel)),
            failed: Set(channelErrors.keys.filter { $0.symbol == symbol }.map(\.channel)))
    }

    private func publishReadiness(_ symbol: String) {
        let ready = running && isReady(symbol)
        let reason = !running ? "OKX 已暂停" : ready ? "OKX 报价与成交已就绪"
            : channelErrors.filter { $0.key.symbol == symbol }.map(\.value).sorted().first ?? "OKX 正在确认报价与成交订阅"
        guard lastReadiness[symbol]?.ready != ready || lastReadiness[symbol]?.reason != reason else { return }
        lastReadiness[symbol] = (ready, reason)
        RuntimeDiagnostics.shared.record(category: "okx_public", event: ready ? "subscription_ready" : "subscription_pending",
            fields: ["symbol": symbol, "ready": ready, "generation": generation, "attempt": connectionAttempt])
        onReadiness?(symbol, ready, reason)
    }

    private func notePendingTimeouts(elapsed: TimeInterval) {
        for symbol in symbols {
            let missing = TransportReadiness.timedOut(required: ["tickers", "trades"],
                acknowledged: Set(acknowledged.filter { $0.symbol == symbol }.map(\.channel)),
                failed: Set(channelErrors.keys.filter { $0.symbol == symbol }.map(\.channel)), elapsed: elapsed)
            for channel in missing {
                channelErrors[Subscription(symbol: symbol, channel: channel)] = "OKX \(channel == "trades" ? "成交" : "报价")订阅确认超时"
                RuntimeDiagnostics.shared.record(category: "okx_public", event: "subscription_timeout",
                    fields: ["symbol": symbol, "channel": channel, "elapsed": elapsed, "attempt": connectionAttempt])
            }
            if !missing.isEmpty { publishSubscriptionState(for: symbol) }
        }
    }

    private func run(generation token: UInt64) async {
        var failures = 0
        while current(token), !Task.isCancelled {
            acknowledged.removeAll()
            channelErrors.removeAll()
            disconnectReason = nil
            connectionAttempt += 1
            for symbol in symbols { publishReadiness(symbol) }
            RuntimeDiagnostics.shared.record(category: "okx_public", event: "connecting",
                fields: ["generation": token, "attempt": connectionAttempt])
            publishStatus(false, failures == 0 ? "OKX 正在连接…" : "OKX 正在重连…")
            let currentSocket = session.webSocketTask(with: URL(string: "wss://ws.okx.com/ws/v5/public")!)
            currentSocket.maximumMessageSize = 2_097_152
            socket = currentSocket
            let began = ProcessInfo.processInfo.systemUptime
            heartbeat = TransportHeartbeat(now: began)
            currentSocket.resume()
            startWatchdog(socket: currentSocket, generation: token, began: began)
            var failure = Reconnect(reason: "OKX 连接断开")
            do {
                for (identifier, args) in requestIDs.sorted(by: { $0.key < $1.key }) {
                    guard current(token, socket: currentSocket), !Task.isCancelled else { return }
                    let data = try JSONSerialization.data(withJSONObject: [
                        "id": identifier, "op": "subscribe",
                        "args": args.map { ["channel": $0.channel, "instId": $0.symbol] }
                    ])
                    try await currentSocket.send(.string(String(decoding: data, as: UTF8.self)))
                }
                guard current(token, socket: currentSocket), !Task.isCancelled else { return }
                publishStatus(false, "OKX 等待订阅确认…")
                while current(token, socket: currentSocket), !Task.isCancelled {
                    let message = try await currentSocket.receive()
                    guard current(token, socket: currentSocket), !Task.isCancelled else { return }
                    let data: Data
                    switch message {
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
            } catch let reason as Reconnect {
                failure = reason
            } catch {
                failure = Reconnect(reason: disconnectReason ?? "OKX 连接断开")
                if current(token, socket: currentSocket), !Task.isCancelled {
                    var fields = RuntimeDiagnostics.errorFields(error)
                    fields["attempt"] = connectionAttempt
                    fields["closeCode"] = currentSocket.closeCode.rawValue
                    RuntimeDiagnostics.shared.record(category: "okx_public", event: "disconnected", fields: fields)
                }
            }
            guard current(token, socket: currentSocket), !Task.isCancelled else { return }
            watchdogTask?.cancel()
            pingTask?.cancel()
            watchdogTask = nil
            pingTask = nil
            currentSocket.cancel(with: .goingAway, reason: nil)
            socket = nil
            if ProcessInfo.processInfo.systemUptime - began >= 60, !acknowledged.isEmpty { failures = 0 }
            acknowledged.removeAll()
            for symbol in symbols { publishReadiness(symbol) }
            failures = min(failures + 1, 6)
            let delay = max(failure.minimumDelay, min(pow(2, Double(failures)), 60)) + Double.random(in: 0...1)
            RuntimeDiagnostics.shared.record(category: "okx_public", event: "reconnect",
                fields: ["attempt": connectionAttempt, "seconds": delay,
                         "lastValidAge": ProcessInfo.processInfo.systemUptime - heartbeat.lastValidAt])
            publishStatus(false, "\(failure.reason) · \(Int(delay)) 秒后重连")
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
        }
    }

    private func startWatchdog(socket currentSocket: URLSessionWebSocketTask, generation token: UInt64,
                               began: TimeInterval) {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                catch { return }
                guard let self, self.current(token, socket: currentSocket) else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if self.heartbeat.action(at: now) == .reconnect {
                    self.disconnectReason = "OKX 心跳超时"
                    RuntimeDiagnostics.shared.record(category: "okx_public", event: "heartbeat_timeout",
                        fields: ["attempt": self.connectionAttempt, "lastValidAge": now - self.heartbeat.lastValidAt,
                                 "pingAge": now - (self.heartbeat.pingSentAt ?? now), "reason": "ping_deadline"])
                    currentSocket.cancel(with: .goingAway, reason: nil)
                    return
                }
                let hadUnconfirmed = self.requested.contains { !self.acknowledged.contains($0) && self.channelErrors[$0] == nil }
                self.notePendingTimeouts(elapsed: now - began)
                if hadUnconfirmed, now - began >= 20, !self.symbols.contains(where: { self.isReady($0) }) {
                    self.disconnectReason = "OKX 订阅确认超时"
                    currentSocket.cancel(with: .goingAway, reason: nil)
                    return
                }
                if self.heartbeat.action(at: now) == .sendPing {
                    self.heartbeat.beginPing(at: now)
                    // The watchdog must keep running even if sending is stalled.
                    self.pingTask = Task { [weak self] in
                        do { try await currentSocket.send(.string("ping")) }
                        catch {
                            guard let self, self.current(token, socket: currentSocket) else { return }
                            self.disconnectReason = "OKX 心跳发送失败"
                            RuntimeDiagnostics.shared.record(category: "okx_public", event: "heartbeat_send_error",
                                fields: RuntimeDiagnostics.errorFields(error))
                            currentSocket.cancel(with: .goingAway, reason: nil)
                        }
                    }
                }
            }
        }
    }

    private func handle(_ data: Data) throws {
        guard data.count <= 2_097_152,
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Reconnect(reason: "OKX 返回格式异常")
        }
        let argument = message["arg"] as? [String: Any]
        let subscription: Subscription? = {
            guard let symbol = argument?["instId"] as? String,
                  let channel = argument?["channel"] as? String else { return nil }
            let key = Subscription(symbol: symbol, channel: channel)
            return requested.contains(key) ? key : nil
        }()
        if let event = message["event"] as? String {
            switch event {
            case "subscribe":
                if let subscription { markReady(subscription) }
            case "error":
                let code = message["code"] as? String ?? "未知"
                let related = subscription.map { [$0] }
                    ?? (message["id"] as? String).flatMap { requestIDs[$0] }
                    ?? Array(requested)
                let detail: String
                switch code {
                case "60018": detail = "OKX 未找到该品种或频道（60018）"
                case "60014": detail = "OKX 请求过于频繁（60014）"
                default: detail = "OKX 订阅失败（\(code)）"
                }
                for key in related {
                    acknowledged.remove(key)
                    channelErrors[key] = detail
                    RuntimeDiagnostics.shared.record(category: "okx_public", event: "subscription_error",
                        fields: ["symbol": key.symbol, "channel": key.channel, "apiCode": code, "attempt": connectionAttempt])
                }
                publishSubscriptionState()
                if code == "60014" { throw Reconnect(reason: "OKX 请求限流", minimumDelay: 30) }
                // Invalid instruments/arguments are not repaired by reconnecting.
                // Keep other valid subscriptions alive and retain their prices.
                let permanent = ["60008", "60011", "60012", "60013", "60018", "60019", "60027", "60028", "60033", "64000", "64001"]
                if !permanent.contains(code) { throw Reconnect(reason: "OKX 服务暂不可用") }
            case "notice":
                if message["code"] as? String == "64008" {
                    throw Reconnect(reason: "OKX 服务升级", minimumDelay: 3)
                }
            default: break
            }
            return
        }
        guard let subscription else { return }
        do {
            switch subscription.channel {
            case "tickers":
                if let ticker = try OKXDecoder.ticker(data, expectedSymbol: subscription.symbol, source: .stream) {
                    markReady(subscription)
                    onTicker(ticker)
                }
            case "trades":
                let trades = try OKXDecoder.trades(data, expectedSymbol: subscription.symbol)
                if !trades.isEmpty {
                    markReady(subscription)
                    onTrades(trades)
                }
            default: break
            }
        } catch {
            let message = "OKX \(subscription.channel == "trades" ? "成交" : "报价")格式异常"
            if channelErrors[subscription] != message {
                RuntimeDiagnostics.shared.record(category: "okx_public", event: "decode_error",
                    fields: ["symbol": subscription.symbol, "channel": subscription.channel, "reason": "decoder_rejected"])
            }
            channelErrors[subscription] = message
            publishSubscriptionState(for: subscription.symbol)
        }
    }
}
