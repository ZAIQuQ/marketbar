import Foundation
import TickerCore

enum CandleArchiveError: Error, LocalizedError {
    case invalidSymbol
    case invalidCandle(String)
    case invalidFile(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidSymbol:
            return "本地行情缓存的股票代码无效。"
        case .invalidCandle(let detail):
            return "本地行情缓存未写入：\(detail)"
        case .invalidFile(let name):
            return "本地行情缓存 \(name) 无法读取或内容不匹配；原文件已保留。"
        case .unavailable(let detail):
            return "本地行情缓存暂不可用：\(detail)"
        }
    }
}

/// Serializes disk access away from the main actor. Files are never pruned:
/// only the newest ten NY trading dates are loaded into the running app.
actor CandleArchive {
    private struct DayFile: Codable {
        let schemaVersion: Int
        let symbol: String
        let day: String
        let candles: [MinuteCandle]
        let previousClose: Double?
    }

    private let directory: URL
    private let manager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private let dayFormatter: DateFormatter

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MarketBar/Candles", isDirectory: true)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = TimeZone(identifier: "America/New_York")!
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.isLenient = false
    }

    func load(symbol: String) throws -> [MinuteCandle] {
        try loadBundle(symbol: symbol).candles
    }

    func loadBundle(symbol: String) throws -> (candles: [MinuteCandle], references: [String: ChartReference]) {
        let folder = try symbolDirectory(symbol)
        guard manager.fileExists(atPath: folder.path) else { return ([], [:]) }
        try checkDirectory(folder)
        let files: [URL]
        do {
            files = try manager.contentsOfDirectory(at: folder,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles])
        } catch {
            throw CandleArchiveError.unavailable("无法列出 \(symbol) 缓存目录。")
        }
        let selected = files.filter { file in
            file.pathExtension == "json" && validDay(file.deletingPathExtension().lastPathComponent)
        }.sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(10)
        var result: [MinuteCandle] = []
        var references: [String: ChartReference] = [:]
        for file in selected {
            let day = file.deletingPathExtension().lastPathComponent
            let document = try read(file, symbol: symbol, day: day)
            result += document.candles
            if let previousClose = document.previousClose {
                references[day] = ChartReference(day: day, previousClose: previousClose)
            }
        }
        return (result.sorted { $0.minute < $1.minute }, references)
    }

    /// Retains pre-existing entries omitted by the caller, and uses the newest
    /// observation for matching minutes. Every target file is validated before
    /// any write; a corrupt file is never silently replaced with fresh data.
    /// Each day's replacement is atomic, but a multi-day save is not a transaction.
    func save(symbol: String, candles: [MinuteCandle], references: [String: ChartReference] = [:]) throws {
        let folder = try symbolDirectory(symbol)
        guard !candles.isEmpty else { return }
        if manager.fileExists(atPath: folder.path) { try checkDirectory(folder) }
        var grouped: [String: [MinuteCandle]] = [:]
        for candle in candles {
            try validate(candle, symbol: symbol)
            grouped[dayFormatter.string(from: candle.minute), default: []].append(candle)
        }
        var prepared: [(URL, Data)] = []
        for day in grouped.keys.sorted() {
            let file = folder.appendingPathComponent(day + ".json", isDirectory: false)
            var merged: [Date: MinuteCandle] = [:]
            var previousClose: Double?
            if manager.fileExists(atPath: file.path) {
                let existing = try read(file, symbol: symbol, day: day)
                previousClose = existing.previousClose
                for candle in existing.candles {
                    merged[candle.minute] = candle
                }
            }
            if let reference = references[day] {
                guard reference.day == day, reference.previousClose.isFinite, reference.previousClose > 0 else {
                    throw CandleArchiveError.invalidCandle("昨收基准与 K 线日期不匹配，或价格无效。")
                }
                previousClose = reference.previousClose
            }
            for candle in grouped[day]! {
                if let prior = merged[candle.minute], prior.observedAt > candle.observedAt { continue }
                merged[candle.minute] = candle
            }
            guard merged.count <= 1_500 else {
                throw CandleArchiveError.invalidCandle("同一纽约日期的分钟数量超出范围。")
            }
            let document = DayFile(schemaVersion: 1, symbol: symbol, day: day,
                candles: merged.values.sorted { $0.minute < $1.minute }, previousClose: previousClose)
            do { prepared.append((file, try encoder.encode(document))) }
            catch { throw CandleArchiveError.invalidCandle("\(symbol) 的数值无法编码。") }
        }
        do { try manager.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { throw CandleArchiveError.unavailable("无法创建 \(symbol) 缓存目录。") }
        for (file, data) in prepared {
            do { try data.write(to: file, options: .atomic) }
            catch { throw CandleArchiveError.unavailable("无法保存 \(file.lastPathComponent)；已有文件未被主动删除。") }
        }
    }

    private func symbolDirectory(_ symbol: String) throws -> URL {
        guard let parsed = try? Watchlist.parse(symbol), parsed == [symbol] else {
            throw CandleArchiveError.invalidSymbol
        }
        return directory.appendingPathComponent(symbol, isDirectory: true)
    }

    private func checkDirectory(_ url: URL) throws {
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw CandleArchiveError.unavailable("股票缓存路径不是普通目录。")
            }
        } catch let error as CandleArchiveError { throw error }
        catch { throw CandleArchiveError.unavailable("无法读取股票缓存目录。") }
    }

    private func validDay(_ value: String) -> Bool {
        guard value.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil,
              let date = dayFormatter.date(from: value) else { return false }
        return dayFormatter.string(from: date) == value
    }

    private func read(_ file: URL, symbol: String, day: String) throws -> DayFile {
        do {
            let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                  let size = attributes.fileSize, size <= 4_194_304 else {
                throw CandleArchiveError.invalidFile(file.lastPathComponent)
            }
            let document = try decoder.decode(DayFile.self, from: Data(contentsOf: file))
            guard document.schemaVersion == 1, document.symbol == symbol, document.day == day,
                  document.candles.count <= 1_500,
                  document.previousClose.map({ $0.isFinite && $0 > 0 }) ?? true else {
                throw CandleArchiveError.invalidFile(file.lastPathComponent)
            }
            var seen = Set<Date>()
            for candle in document.candles {
                try validate(candle, symbol: symbol)
                guard dayFormatter.string(from: candle.minute) == day,
                      seen.insert(candle.minute).inserted else {
                    throw CandleArchiveError.invalidFile(file.lastPathComponent)
                }
            }
            return document
        } catch {
            throw CandleArchiveError.invalidFile(file.lastPathComponent)
        }
    }

    private func validate(_ candle: MinuteCandle, symbol: String) throws {
        guard candle.symbol == symbol,
              candle.minute.timeIntervalSince1970.isFinite,
              (946_684_800..<4_102_444_800).contains(candle.minute.timeIntervalSince1970),
              abs(candle.minute.timeIntervalSince1970.truncatingRemainder(dividingBy: 60)) < 0.001 else {
            throw CandleArchiveError.invalidCandle("股票代码或分钟时间戳不匹配。")
        }
        let prices = [candle.open, candle.high, candle.low, candle.close]
        guard prices.allSatisfy({ $0.isFinite && $0 > 0 }),
              candle.high >= max(candle.open, candle.close),
              candle.low <= min(candle.open, candle.close), candle.low <= candle.high else {
            throw CandleArchiveError.invalidCandle("K 线价格不满足 OHLC 约束。")
        }
        let eventDates = [candle.firstEvent, candle.lastEvent, candle.observedAt]
        guard eventDates.allSatisfy({ $0.timeIntervalSince1970.isFinite
            && (946_684_800..<4_102_444_800).contains($0.timeIntervalSince1970) }),
              candle.firstEvent >= candle.minute,
              candle.lastEvent < candle.minute.addingTimeInterval(60),
              candle.firstEvent <= candle.lastEvent,
              (0...10_000_000).contains(candle.sampleCount),
              candle.volume.map({ $0.isFinite && $0 >= 0 }) ?? true else {
            throw CandleArchiveError.invalidCandle("K 线时间、成交量或样本计数无效。")
        }
        switch candle.origin {
        case .yahoo:
            guard candle.sampleCount == 0 else {
                throw CandleArchiveError.invalidCandle("远端 K 线不能包含本地样本计数。")
            }
        case .localSample, .mixed:
            guard candle.sampleCount > 0, candle.volume == nil else {
                throw CandleArchiveError.invalidCandle("本地或混合 K 线缺少样本，或混入未验证成交量。")
            }
        }
    }
}
