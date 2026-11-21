import Combine
import Foundation
import UserNotifications
import TickerCore

@MainActor
final class AlertMonitor: NSObject, ObservableObject {
    let symbol = "SOXL-USDT-SWAP"
    @Published private(set) var configuration: AlertConfiguration
    @Published private(set) var evaluation: MonitorEvaluation
    @Published private(set) var history: [MarketAlert] = []
    @Published private(set) var pendingAlert: MarketAlert?
    @Published private(set) var notificationStatus = "通知未启用"
    @Published private(set) var storageError: String?
    @Published private(set) var keepAwake: Bool
    @Published private(set) var coverageSummary = "等待监测数据"
    var isEnabled: Bool { configuration.enabled }

    private let defaults: UserDefaults
    private let systemEffects: Bool
    private let eventStore: AlertEventStore?
    private var detector: AnomalyDetector
    private var connected = false
    private var connectionReason = "等待行情连接"
    private var stopped = false
    private var activity: NSObjectProtocol?
    private var notificationCenter: UNUserNotificationCenter?
    private var authorizationTask: Task<Void, Never>?
    private var authorizationRequested = false
    private var loadTask: Task<Void, Never>?
    private var pendingWrite: Task<Void, Never>?
    private var storageFailures: [String: String] = [:]
    private var health = MonitorHealth()
    private var healthIncidentID: String?
    private var emittedAlerts = 0
    private var phaseCounts: [MonitorPhase: Int] = [:]
    private var lastDiagnosticPhase: MonitorPhase?
    private var lastTick: Date?

    init(defaults: UserDefaults = .standard, persistenceDirectory: URL? = nil,
         systemEffects: Bool = true) {
        self.defaults = defaults
        self.systemEffects = systemEffects
        var config = AlertConfiguration.defaults
        var configError: String?
        if let stored = defaults.data(forKey: "MarketBar.alertConfiguration") {
            if let decoded = try? JSONDecoder().decode(AlertConfiguration.self, from: stored),
               decoded.validationError == nil {
                config = decoded
                if config.strategy == .legacyMomentum {
                    // Retain the previous payload for rollback; this upgrade
                    // changes the rule to the requested bidirectional monitor.
                    if defaults.data(forKey: "MarketBar.alertConfiguration.beforeMinutePriceVolume") == nil {
                        defaults.set(stored, forKey: "MarketBar.alertConfiguration.beforeMinutePriceVolume")
                    }
                    config.strategy = .minutePriceVolume
                    config.direction = .both
                    config.oneMinutePercent = AlertConfiguration.defaults.oneMinutePercent
                    config.twoMinutePercent = AlertConfiguration.defaults.twoMinutePercent
                    config.volumeMultiplier = AlertConfiguration.defaults.volumeMultiplier
                    if let data = try? JSONEncoder().encode(config) {
                        defaults.set(data, forKey: "MarketBar.alertConfiguration")
                    }
                }
            } else {
                configError = "提醒设置无法读取，已暂时关闭提醒；原设置未覆盖。"
            }
        }
        configuration = config
        keepAwake = defaults.object(forKey: "MarketBar.alertKeepAwake") == nil
            ? true : defaults.bool(forKey: "MarketBar.alertKeepAwake")
        detector = AnomalyDetector(symbol: "SOXL-USDT-SWAP", configuration: config)
        evaluation = MonitorEvaluation(phase: config.enabled ? .warming : .off,
                                       detail: config.enabled ? "等待行情连接" : "提醒未启用")
        let directory = persistenceDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MarketBar/Alerts", isDirectory: true)
        eventStore = systemEffects ? AlertEventStore(directory: directory) : nil
        super.init()
        if let configError { setStorageError("configuration", configError) }
        if !systemEffects {
            notificationStatus = "系统通知已关闭（测试模式）"
        } else if Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil {
            let center = UNUserNotificationCenter.current()
            notificationCenter = center
            center.delegate = self
            Task { [weak self] in await self?.refreshNotificationStatus() }
        } else {
            notificationStatus = "系统通知仅在 MarketBar 应用中可用"
        }
        loadHistory()
        updateActivity()
        if config.enabled { prepareNotifications() }
    }

    @discardableResult
    func updateConfiguration(_ value: AlertConfiguration) -> Bool {
        guard value.validationError == nil, !stopped else { return false }
        do {
            let data = try JSONEncoder().encode(value)
            defaults.set(data, forKey: "MarketBar.alertConfiguration")
            setStorageError("configuration", nil)
        } catch {
            setStorageError("configuration", "提醒设置未保存：\(error.localizedDescription)")
            return false
        }
        let changed = value != configuration
        configuration = value
        detector.configure(value)
        if !value.enabled {
            pendingAlert = nil
            health = MonitorHealth()
            healthIncidentID = nil
        }
        if changed {
            evaluation = MonitorEvaluation(phase: value.enabled ? .warming : .off,
                                           detail: value.enabled ? "重新积累实时成交" : "提醒未启用")
        }
        updateActivity()
        if value.enabled { prepareNotifications() }
        return true
    }

    func setKeepAwake(_ value: Bool) {
        guard !stopped else { return }
        keepAwake = value
        defaults.set(value, forKey: "MarketBar.alertKeepAwake")
        updateActivity()
    }

    func ingestTicker(_ ticker: OKXTicker, receivedAt: Date) {
        guard !stopped, isEnabled, connected, ticker.quote.symbol == symbol else { return }
        detector.ingestTicker(ticker, receivedAt: receivedAt)
    }

    func ingestTrades(_ trades: [PriceQuote], receivedAt: Date) {
        guard !stopped, isEnabled, connected else { return }
        for trade in trades where trade.symbol == symbol { detector.ingestTrade(trade, receivedAt: receivedAt) }
    }

    func ingestCandles(_ candles: [MinuteCandle]) {
        guard !stopped else { return }
        // Completed historical bars provide volatility context only. The core
        // independently requires fresh executed trades before it can alert.
        detector.ingestCandles(candles.filter { $0.symbol == symbol })
    }

    func setConnected(_ value: Bool, reason: String) {
        guard !stopped else { return }
        if connected != value { detector.reset() }
        connected = value
        connectionReason = reason.isEmpty ? "行情未连接" : reason
        if !isEnabled {
            evaluation = MonitorEvaluation(phase: .off, detail: "提醒未启用")
        } else if !value {
            evaluation = MonitorEvaluation(phase: .stale, detail: connectionReason)
        }
    }

    func tick(at now: Date = Date()) {
        guard !stopped else { return }
        if systemEffects, isEnabled, let previous = lastTick, now.timeIntervalSince(previous) > 2.5 {
            RuntimeDiagnostics.shared.record(category: "monitor", event: "tick_gap",
                fields: ["symbol": symbol, "tickGap": now.timeIntervalSince(previous)])
        }
        lastTick = now
        guard isEnabled else {
            evaluation = MonitorEvaluation(phase: .off, detail: "提醒未启用")
            return
        }
        guard connected else {
            evaluation = MonitorEvaluation(phase: .stale, detail: connectionReason)
            checkHealth(at: now)
            return
        }
        let result = detector.evaluate(at: now)
        evaluation = result
        checkHealth(at: now)
        guard let alert = result.alert, alert.symbol == symbol,
              !history.contains(where: { $0.id == alert.id }) else { return }
        history.insert(alert, at: 0)
        history = Array(history.prefix(100))
        pendingAlert = alert
        emittedAlerts += 1
        appendEvent(alert)
        if systemEffects {
            RuntimeDiagnostics.shared.record(category: "monitor", event: "alert", fields: ["symbol": symbol])
        }
        deliverNotification(alert)
    }

    func acknowledge() { pendingAlert = nil }

    /// Stop this instance without changing the user's saved enabled setting.
    func shutdown() {
        stopped = true
        connected = false
        health = MonitorHealth()
        healthIncidentID = nil
        detector.reset()
        evaluation = MonitorEvaluation(phase: .off, detail: "监测已停止")
        authorizationTask?.cancel()
        authorizationTask = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    func flushEvents() async {
        await loadTask?.value
        await pendingWrite?.value
        if systemEffects { await RuntimeDiagnostics.shared.flush() }
    }

    func refreshNotificationStatus() async {
        guard let center = notificationCenter else { return }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: notificationStatus = "尚未允许通知"
        case .denied: notificationStatus = "通知未允许 · 菜单栏仍会提醒"
        case .authorized:
            notificationStatus = settings.alertSetting == .enabled
                ? "静默通知已允许" : "通知横幅关闭 · 请检查系统设置"
        case .provisional: notificationStatus = "通知中心已允许 · 不显示横幅"
        @unknown default: notificationStatus = "通知状态未知 · 菜单栏仍会提醒"
        }
    }

    private func prepareNotifications() {
        guard systemEffects, notificationCenter != nil, authorizationTask == nil, !stopped else { return }
        authorizationTask = Task { [weak self] in
            guard let self, let center = self.notificationCenter else { return }
            defer { self.authorizationTask = nil }
            let settings = await center.notificationSettings()
            guard !Task.isCancelled, self.isEnabled, !self.stopped else { return }
            if settings.authorizationStatus == .notDetermined, !self.authorizationRequested {
                self.authorizationRequested = true
                do { _ = try await center.requestAuthorization(options: [.alert]) }
                catch {
                    self.notificationStatus = "通知授权失败 · 菜单栏仍会提醒"
                    return
                }
            }
            await self.refreshNotificationStatus()
        }
    }

    private func deliverNotification(_ alert: MarketAlert) {
        guard systemEffects, let center = notificationCenter else { return }
        Task { [weak self] in
            let settings = await center.notificationSettings()
            guard let self, !self.stopped, self.isEnabled else { return }
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                RuntimeDiagnostics.shared.record(category: "notification", event: "skipped", fields: ["symbol": self.symbol, "kind": "market"])
                await self.refreshNotificationStatus()
                return
            }
            let content = UNMutableNotificationContent()
            let move = alert.direction == .up ? "上涨" : "下跌"
            content.title = "SOXLUSDT " + (alert.volumeRatio == nil ? "" : "放量") + move
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.timeZone = .current
            formatter.dateFormat = "MM-dd HH:mm:ss"
            let direction = alert.direction == .up ? "上涨" : "下跌"
            content.body = "\(formatter.string(from: alert.timestamp)) 本地时间，\(alert.windowSeconds / 60) 分钟\(direction) "
                + String(format: "%.2f%%", abs(alert.changePercent))
                + "，确认价 " + String(format: "%.2f USDT", alert.price)
                + "，超过当前阈值 " + String(format: "%.2f%%", alert.thresholdPercent)
                + "，已连续确认 \(alert.confirmedSeconds) 秒。"
            if let ratio = alert.volumeRatio {
                content.body += "成交量为近期均量 " + String(format: "%.2f 倍。", ratio)
            }
            content.sound = nil
            content.threadIdentifier = "MarketBar.SOXLUSDT"
            content.userInfo = ["symbol": self.symbol, "alertID": alert.id]
            do {
                try await center.add(UNNotificationRequest(identifier: alert.id, content: content, trigger: nil))
                RuntimeDiagnostics.shared.record(category: "notification", event: "queued", fields: ["symbol": self.symbol, "kind": "market"])
            } catch {
                RuntimeDiagnostics.shared.record(category: "notification", event: "failed", fields: ["symbol": self.symbol, "kind": "market"])
                self.notificationStatus = "系统通知提交失败 · 菜单栏仍会提醒"
            }
        }
    }

    private func checkHealth(at now: Date) {
        guard now.timeIntervalSince1970.isFinite else { return }
        phaseCounts[evaluation.phase, default: 0] += 1
        let total = phaseCounts.values.reduce(0, +)
        if systemEffects, lastDiagnosticPhase != evaluation.phase {
            lastDiagnosticPhase = evaluation.phase
            RuntimeDiagnostics.shared.record(category: "monitor", event: "phase",
                fields: ["symbol": symbol, "phase": evaluation.phase.rawValue])
        }
        if systemEffects, total % 60 == 0 {
            RuntimeDiagnostics.shared.record(category: "monitor", event: "summary",
                fields: ["symbol": symbol, "phaseCounts": Dictionary(uniqueKeysWithValues: phaseCounts.map { ($0.key.rawValue, $0.value) })])
            setStorageError("diagnostics", RuntimeDiagnostics.shared.lastError)
        }
        if total == 1 || total % 10 == 0 {
            let ready = phaseCounts[.watching, default: 0] + phaseCounts[.confirming, default: 0]
            coverageSummary = String(format: "本次 %d 次检查 · 可评估 %.0f%% · 提醒 %d 次", total,
                                     Double(ready) / Double(total) * 100, emittedAlerts)
        }
        let failed = !connected || evaluation.phase == .stale
        guard health.observe(failed: failed, at: now) else { return }
        let incidentID = UUID().uuidString
        healthIncidentID = incidentID
        guard systemEffects, let center = notificationCenter else { return }
        let reason = evaluation.detail
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "MM-dd HH:mm:ss"
        let body = "\(formatter.string(from: now)) 本地时间，\(reason)。当前暂停异动判断，数据恢复后自动继续。"
        Task { [weak self] in
            let settings = await center.notificationSettings()
            guard let self, !self.stopped, self.isEnabled, self.healthIncidentID == incidentID,
                  !self.connected || self.evaluation.phase == .stale else { return }
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                await self.refreshNotificationStatus()
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "SOXLUSDT 盯盘已中断"
            content.body = body
            content.sound = nil
            content.threadIdentifier = "MarketBar.SOXLUSDT.health"
            content.userInfo = ["symbol": self.symbol, "kind": "health"]
            do {
                try await center.add(UNNotificationRequest(identifier: "MarketBar.health.\(incidentID)",
                                                           content: content, trigger: nil))
                RuntimeDiagnostics.shared.record(category: "notification", event: "queued",
                    fields: ["symbol": self.symbol, "kind": "health"])
            } catch {
                RuntimeDiagnostics.shared.record(category: "notification", event: "failed",
                    fields: ["symbol": self.symbol, "kind": "health"])
                self.notificationStatus = "中断通知提交失败 · 菜单栏仍显示状态"
            }
        }
    }

    private func updateActivity() {
        let needed = systemEffects && isEnabled && keepAwake && !stopped
        if needed, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "MarketBar SOXLUSDT 行情提醒")
        } else if !needed, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    private func loadHistory() {
        guard let eventStore else { return }
        loadTask = Task { [weak self] in
            do {
                let saved = try await eventStore.loadLatest()
                guard let self, !self.stopped else { return }
                var seen = Set<String>()
                self.history = Array((self.history + saved.filter { $0.symbol == self.symbol })
                    .filter { seen.insert($0.id).inserted }
                    .sorted { $0.timestamp > $1.timestamp }.prefix(100))
                // Loading history never fills pendingAlert or posts a notification.
            } catch {
                self?.setStorageError("history", "提醒历史无法读取：\(error.localizedDescription)")
            }
        }
    }

    private func appendEvent(_ alert: MarketAlert) {
        guard let eventStore else { return }
        let previous = pendingWrite
        pendingWrite = Task { [weak self] in
            await previous?.value
            do { try await eventStore.append(alert) }
            catch { self?.setStorageError("history", "提醒记录未写入：\(error.localizedDescription)") }
        }
    }

    private func setStorageError(_ key: String, _ value: String?) {
        storageFailures[key] = value
        let failures = storageFailures.keys.sorted().compactMap { storageFailures[$0] }
        storageError = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }
}

extension AlertMonitor: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let symbol = info["symbol"] as? String, symbol == "SOXL-USDT-SWAP" else {
            completionHandler()
            return
        }
        let alertID = info["alertID"] as? String ?? response.notification.request.identifier
        Task { @MainActor in
            NotificationCenter.default.post(name: Notification.Name("MarketBar.openSymbol"), object: nil,
                                            userInfo: ["symbol": symbol, "alertID": alertID])
            completionHandler()
        }
    }
}

/// Serial off-main I/O. Only the tail is read; previous log rows are never
/// pruned or rewritten. An incomplete tail is preserved and blocks further append.
private actor AlertEventStore {
    private let directory: URL
    private let file: URL

    init(directory: URL) {
        self.directory = directory
        file = directory.appendingPathComponent("events.jsonl")
    }

    func loadLatest() throws -> [MarketAlert] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        try validateFile()
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var position = try handle.seekToEnd()
        var data = Data()
        while position > 0, data.reduce(0, { $0 + ($1 == 10 ? 1 : 0) }) <= 100 {
            let size = min(position, 65_536)
            position -= size
            try handle.seek(toOffset: position)
            guard let block = try handle.read(upToCount: Int(size)), block.count == Int(size) else {
                throw LogError.unreadable
            }
            data.insert(contentsOf: block, at: 0)
            guard data.count <= 2_097_152 else { throw LogError.oversized }
        }
        guard data.isEmpty || data.last == 10 else { throw LogError.incomplete }
        let lines = data.split(separator: 10).suffix(100)
        return Array(try lines.map { try JSONDecoder().decode(MarketAlert.self, from: Data($0)) }.reversed())
    }

    func append(_ alert: MarketAlert) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        if !manager.fileExists(atPath: file.path) {
            guard manager.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw LogError.unreadable
            }
        }
        try validateFile()
        let handle = try FileHandle(forUpdating: file)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        if size > 0 {
            try handle.seek(toOffset: size - 1)
            guard try handle.read(upToCount: 1) == Data([10]) else { throw LogError.incomplete }
            try handle.seekToEnd()
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(alert)
        data.append(10)
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private func validateFile() throws {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw LogError.unreadable }
    }

    private enum LogError: Error, LocalizedError {
        case unreadable, incomplete, oversized
        var errorDescription: String? {
            switch self {
            case .unreadable: return "事件文件不可读写，原文件已保留。"
            case .incomplete: return "事件文件末尾不完整，原文件已保留。"
            case .oversized: return "事件记录长度异常，原文件已保留。"
            }
        }
    }
}
