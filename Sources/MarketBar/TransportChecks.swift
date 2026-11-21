import Foundation

@MainActor
func runTransportChecks() async -> Bool {
    var failures: [String] = []
    var count = 0
    func check(_ value: @autoclosure () -> Bool, _ label: String) {
        count += 1
        if !value() { failures.append(label) }
    }
    var heartbeat = TransportHeartbeat(now: 0)
    check(heartbeat.action(at: 14.9) == .wait, "no premature ping")
    check(heartbeat.action(at: 15) == .sendPing, "ping after fifteen idle seconds")
    heartbeat.beginPing(at: 15)
    check(heartbeat.action(at: 24.9) == .wait, "wait for the ping response deadline")
    check(heartbeat.action(at: 25) == .reconnect, "silent transport reaches bounded timeout")
    heartbeat.observeValidFrame(at: 24.9)
    check(heartbeat.pingSentAt == nil, "valid market frame resolves outstanding liveness ping")
    check(heartbeat.action(at: 25) == .wait, "resumed market data prevents false disconnect")
    check(heartbeat.action(at: 39.9) == .sendPing, "next idle period starts at latest valid data")
    heartbeat.beginPing(at: 40)
    heartbeat.observeValidFrame(at: 40.1)
    check(heartbeat.action(at: 50) == .wait, "valid pong or acknowledgment restores liveness")
    heartbeat.observeValidFrame(at: .nan)
    check(heartbeat.lastValidAt == 40.1, "nonfinite clock input is ignored")
    check(heartbeat.action(at: 39) == .wait, "old clock input does not disconnect")

    let required: Set<String> = ["tickers", "trades"]
    check(!TransportReadiness.isReady(required: required, acknowledged: ["tickers"], failed: []), "one ACK cannot arm the two-channel monitor")
    check(TransportReadiness.isReady(required: required, acknowledged: required, failed: []), "both channels ready")
    check(!TransportReadiness.isReady(required: required, acknowledged: required, failed: ["trades"]), "required-channel failure blocks readiness")
    check(TransportReadiness.isReady(required: required, acknowledged: required, failed: ["unrelated"]), "unrelated failures do not poison readiness")
    check(TransportReadiness.timedOut(required: required, acknowledged: ["tickers"], failed: [], elapsed: 19).isEmpty, "partial acknowledgment gets a bounded grace period")
    check(TransportReadiness.timedOut(required: required, acknowledged: ["tickers"], failed: [], elapsed: 20) == ["trades"], "timeout is scoped to the missing channel")
    check(TransportReadiness.timedOut(required: required, acknowledged: ["tickers"], failed: ["trades"], elapsed: 30).isEmpty, "explicit failure does not generate repeated timeout errors")

    let filtered = RuntimeDiagnostics.filteredFields(["symbol": "SOXL-USDT-SWAP", "phase": "stale",
        "tickerAge": Double.infinity, "errorDomain": "NSURLErrorDomain", "errorCode": -1001,
        "rawFrame": "do_not_persist", "url": "https://example.invalid/private",
        "reason": "https://example.invalid/private", "connected": true,
        "counts": ["watching": 8, "arbitrary_secret": 9]])
    check(filtered["symbol"] as? String == "SOXL-USDT-SWAP", "canonical instrument is retained")
    check(filtered["errorCode"] as? Int == -1001, "numeric transport error is retained")
    check(filtered["connected"] as? Bool == true, "boolean status is retained")
    check(filtered["rawFrame"] == nil && filtered["url"] == nil && filtered["reason"] == nil, "raw/free-text fields are rejected")
    check(filtered["tickerAge"] == nil, "nonfinite numeric fields are rejected")
    check((filtered["counts"] as? [String: Int]) == ["watching": 8], "phase-count keys are allowlisted")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MarketBar.TransportChecks.\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let logger = RuntimeDiagnostics(directory: directory, maxBytes: 1024)
    for i in 0..<40 {
        logger.record(category: "okx_public", event: "reconnect",
                      fields: ["attempt": i, "symbol": "SOXL-USDT-SWAP", "rawFrame": "do_not_persist"])
    }
    await logger.flush()
    do {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        check(files.count == 3, "diagnostic rotation retains exactly three bounded files")
        for file in files {
            let data = try Data(contentsOf: file)
            check(data.count <= 1024, "each diagnostic file remains within its byte budget")
            check(!String(decoding: data, as: UTF8.self).contains("do_not_persist"), "raw data never reaches disk")
            for line in data.split(separator: 10) {
                _ = try JSONSerialization.jsonObject(with: Data(line))
            }
        }
        check(logger.lastError == nil, "diagnostic writes completed successfully")
    } catch { failures.append("temporary diagnostic I/O failed") }
    if failures.isEmpty {
        print("PASS transport checks: \(count) checks (no network; temporary diagnostics only)")
        return true
    }
    print("FAIL transport checks: \(failures.count)/\(count)")
    failures.forEach { print("  \($0)") }
    return false
}
