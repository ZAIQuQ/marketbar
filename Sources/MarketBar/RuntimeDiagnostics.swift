import CoreFoundation
import Foundation

/// Fixed-field local diagnostics. Strings are validated enums/identifiers;
/// raw URLs, headers, frames and arbitrary server error text are not accepted.
final class RuntimeDiagnostics: @unchecked Sendable {
    static let shared = RuntimeDiagnostics()
    private let queue = DispatchQueue(label: "MarketBar.diagnostics", qos: .utility)
    private let directory: URL
    private let maxBytes: Int
    private let errorLock = NSLock()
    private var writeError: String?

    var lastError: String? {
        errorLock.lock(); defer { errorLock.unlock() }
        return writeError
    }

    init(directory: URL? = nil, maxBytes: Int = 2_097_152) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MarketBar/Diagnostics", isDirectory: true)
        self.maxBytes = max(1_024, maxBytes)
    }

    func record(category: String, event: String, fields: [String: Any] = [:]) {
        let categories: Set<String> = ["app", "okx_public", "okx_candle", "yahoo", "snapshot", "history", "storage", "monitor", "notification"]
        let events: Set<String> = ["start", "stop", "connecting", "connected", "disconnected", "reconnect",
            "subscription_pending", "subscription_ready", "subscription_error", "subscription_timeout", "decode_error",
            "heartbeat_timeout", "heartbeat_send_error", "state", "state_transition", "summary", "request_error", "request_ok",
            "clock_skew", "notification_scheduled", "notification_failed", "authorization", "health_alert", "market_alert",
            "sample_rejected", "sample_gap", "tick_gap", "write_error", "coverage", "phase", "queued", "failed", "skipped", "alert"]
        guard categories.contains(category), events.contains(event) else { return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let filtered = Self.filteredFields(fields)
        let document: [String: Any] = ["schema": 1, "timestamp": formatter.string(from: Date()),
            "uptime": ProcessInfo.processInfo.systemUptime, "pid": ProcessInfo.processInfo.processIdentifier,
            "category": category, "event": event, "fields": filtered,
            "discardedFieldCount": max(0, fields.count - filtered.count)]
        guard var data = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]) else { return }
        data.append(10)
        guard data.count <= maxBytes else { return }
        queue.async { [self, data] in
            do { try append(data) }
            catch {
                errorLock.lock()
                writeError = "诊断日志无法写入"
                errorLock.unlock()
            }
        }
    }

    func flush() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    static func filteredFields(_ input: [String: Any]) -> [String: Any] {
        let numeric: Set<String> = ["generation", "attempt", "reconnectCount", "errorCode", "closeCode", "age", "elapsed",
            "pingAge", "lastValidAge", "pongRTT", "frames", "validFrames", "invalidFrames", "tickerFrames", "tradeFrames",
            "candleFrames", "seconds", "tradeAge", "tickerAge", "tradeReceiptAge", "tickerReceiptAge", "spreadPercent",
            "oneMinuteThreshold", "threeMinuteThreshold", "warmupSeconds", "coverage5", "coverage60", "coverage180",
            "tickGap", "requests", "pendingCount", "readyCount", "baselineCount", "clockSkew", "bytes", "rows",
            "duration", "blockedSeconds", "notificationCount"]
        let booleans: Set<String> = ["enabled", "connected", "ready", "expectedCancellation", "keepAwake", "confirmed", "scheduled"]
        let enums: [String: Set<String>] = [
            "channel": ["tickers", "trades", "candle1m", "yahoo", "chart", "snapshot"],
            "phase": ["off", "warming", "watching", "confirming", "stale", "wideSpread", "sparse"],
            "previousPhase": ["off", "warming", "watching", "confirming", "stale", "wideSpread", "sparse"],
            "reason": ["transport_receive_failed", "ping_deadline", "ping_send_failed", "subscription_pending", "subscription_timeout",
                "subscription_rejected", "decoder_rejected", "service_upgrade", "rate_limited", "user_stop", "configuration_change",
                "trade_stale", "ticker_stale", "receipt_stale", "clock_ahead", "coverage_low", "spread_wide", "spread_invalid",
                "baseline_missing", "warmup", "cooldown", "threshold_not_met", "unknown"],
            "errorDomain": ["NSURLErrorDomain", "NSPOSIXErrorDomain", "NSCocoaErrorDomain", "kCFErrorDomainCFNetwork", "other"],
            "authorization": ["authorized", "denied", "notDetermined", "provisional", "unknown"],
            "result": ["queued", "accepted", "failed", "denied", "skipped", "recovered", "unknown"],
            "kind": ["market", "health"]]
        var output: [String: Any] = [:]
        for (key, value) in input {
            if (key == "phaseCounts" || key == "counts"), let counts = value as? [String: Int] {
                let accepted = enums["phase"]!
                output[key] = counts.filter { accepted.contains($0.key) && $0.value >= 0 }
            } else if numeric.contains(key), let number = value as? NSNumber,
               CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite {
                output[key] = number
            } else if booleans.contains(key), let number = value as? NSNumber,
                      CFGetTypeID(number) == CFBooleanGetTypeID() {
                output[key] = number
            } else if let text = value as? String {
                if key == "symbol", text.range(of: "^[A-Z0-9][A-Z0-9.-]{0,31}$", options: .regularExpression) != nil {
                    output[key] = text
                } else if key == "apiCode", text.range(of: "^[0-9]{1,6}$", options: .regularExpression) != nil {
                    output[key] = text
                } else if let accepted = enums[key], accepted.contains(text) {
                    output[key] = text
                }
            }
        }
        return output
    }

    static func errorFields(_ error: Error) -> [String: Any] {
        let value = error as NSError
        let domains: Set<String> = ["NSURLErrorDomain", "NSPOSIXErrorDomain", "NSCocoaErrorDomain", "kCFErrorDomainCFNetwork"]
        return ["errorDomain": domains.contains(value.domain) ? value.domain : "other", "errorCode": value.code]
    }

    private func append(_ data: Data) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let paths = ["runtime.jsonl", "runtime.1.jsonl", "runtime.2.jsonl"].map { directory.appendingPathComponent($0) }
        for path in paths where manager.fileExists(atPath: path.path) {
            let properties = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard properties.isRegularFile == true, properties.isSymbolicLink != true else { throw CocoaError(.fileWriteNoPermission) }
        }
        let size = (try? paths[0].resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size + data.count > maxBytes {
            if manager.fileExists(atPath: paths[2].path) { try manager.removeItem(at: paths[2]) }
            if manager.fileExists(atPath: paths[1].path) { try manager.moveItem(at: paths[1], to: paths[2]) }
            if manager.fileExists(atPath: paths[0].path) { try manager.moveItem(at: paths[0], to: paths[1]) }
        }
        if !manager.fileExists(atPath: paths[0].path) {
            guard manager.createFile(atPath: paths[0].path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: paths[0])
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
