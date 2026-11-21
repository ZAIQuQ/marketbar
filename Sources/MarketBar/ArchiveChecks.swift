import Foundation
import TickerCore

/// Exercises real encoding, filesystem writes and corruption boundaries using
/// a disposable directory. Never touches the user's production cache.
func runArchiveChecks() async -> Bool {
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("MarketBar.ArchiveChecks.\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let archive = CandleArchive(directory: temporary.appendingPathComponent("primary"))
    let base = ISO8601DateFormatter().date(from: "2026-11-20T12:30:00Z")!
    var count = 0
    var failures: [String] = []
    func check(_ value: Bool, _ description: String) {
        count += 1
        if !value { failures.append(description) }
    }
    func fixture(offset: TimeInterval = 0, close: Double = 102,
                 origin: CandleOrigin = .mixed, observedOffset: TimeInterval = 50) -> MinuteCandle {
        let minute = base.addingTimeInterval(offset)
        return MinuteCandle(symbol: "AMD", minute: minute, open: 100, high: 105,
            low: 99, close: close, volume: origin == .yahoo ? 123 : nil,
            session: .pre, origin: origin, firstEvent: minute.addingTimeInterval(2),
            lastEvent: minute.addingTimeInterval(48), observedAt: minute.addingTimeInterval(observedOffset),
            sampleCount: origin == .yahoo ? 0 : 3)
    }
    do {
        let empty = try await archive.load(symbol: "AMD")
        check(empty.isEmpty, "missing cache loads as empty without creating a directory")
        check(!FileManager.default.fileExists(atPath: temporary.path), "read-only empty load does not write")
        for symbol in ["../AMD", "AMD/NVDA", "amd", "NVIDIA", "AMD,NVDA"] {
            do {
                _ = try await archive.load(symbol: symbol)
                check(false, "unsafe or noncanonical symbol rejected: \(symbol)")
            } catch CandleArchiveError.invalidSymbol {
                check(true, "unsafe or noncanonical symbol rejected: \(symbol)")
            }
        }
        let original = fixture()
        let next = fixture(offset: 60, origin: .localSample)
        let perpetualTime = ISO8601DateFormatter().date(from: "2026-11-21T00:30:00Z")!
        let perpetual = MinuteCandle(symbol: "SOXL-USDT-SWAP", minute: perpetualTime,
            open: 33, high: 33.2, low: 32.8, close: 33.1, volume: nil, session: .perpetual,
            origin: .okx, firstEvent: perpetualTime, lastEvent: perpetualTime,
            observedAt: perpetualTime.addingTimeInterval(60), sampleCount: 0, isFinal: true)
        let utcReference = ChartReference(day: "2026-11-21", previousClose: 32, basis: .utcOpen)
        try await archive.save(symbol: perpetual.symbol, candles: [perpetual], references: [utcReference.day: utcReference])
        let restoredPerpetual = try await archive.loadBundle(symbol: perpetual.symbol)
        check(restoredPerpetual.candles == [perpetual], "OKX finality and session roundtrip")
        check(restoredPerpetual.references[utcReference.day] == utcReference, "UTC opening basis survives archive reload")
        check(FileManager.default.fileExists(atPath: temporary.appendingPathComponent("primary/SOXL-USDT-SWAP/2026-11-21.json").path),
              "OKX archives use UTC date rather than previous New York day")
        let spot = MinuteCandle(symbol: "BTC-USDT", minute: perpetualTime,
            open: 100_000, high: 100_100, low: 99_900, close: 100_050, volume: nil, session: .spot,
            origin: .okx, firstEvent: perpetualTime, lastEvent: perpetualTime,
            observedAt: perpetualTime.addingTimeInterval(60), sampleCount: 0, isFinal: true, volumeBase: 0.25)
        let spotReference = ChartReference(day: "2026-11-21", previousClose: 99_000, basis: .utcOpen)
        try await archive.save(symbol: spot.symbol, candles: [spot], references: [spotReference.day: spotReference])
        let restoredSpot = try await archive.loadBundle(symbol: spot.symbol)
        check(restoredSpot.candles == [spot], "spot OHLC, base volume, finality and session survive disk roundtrip")
        check(restoredSpot.references[spotReference.day] == spotReference, "spot UTC opening baseline remains separate")
        let spotFile = temporary.appendingPathComponent("primary/BTC-USDT/2026-11-21.json")
        check(FileManager.default.fileExists(atPath: spotFile.path), "spot archives use a separate canonical instrument folder and UTC day")
        let beforeInvalidSpot = try Data(contentsOf: spotFile)
        for (session, contracts, origin, sampleCount) in [
            (TradingSession.perpetual, Optional<Double>.none, CandleOrigin.okx, 0),
            (TradingSession.spot, Optional(3.0), CandleOrigin.okx, 0),
            (TradingSession.spot, Optional<Double>.none, CandleOrigin.mixed, 2)
        ] {
            let invalidSpot = MinuteCandle(symbol: spot.symbol, minute: perpetualTime,
                open: 100_000, high: 100_100, low: 99_900, close: 100_050, volume: nil, session: session,
                origin: origin, firstEvent: perpetualTime, lastEvent: perpetualTime,
                observedAt: perpetualTime.addingTimeInterval(60), sampleCount: sampleCount, isFinal: true,
                volumeContracts: contracts, volumeBase: 0.25)
            do {
                try await archive.save(symbol: spot.symbol, candles: [invalidSpot])
                check(false, "spot cannot be persisted as perpetual, contract volume or mixed-volume data")
            } catch CandleArchiveError.invalidCandle {
                check(true, "spot cannot be persisted as perpetual, contract volume or mixed-volume data")
            }
        }
        check(try Data(contentsOf: spotFile) == beforeInvalidSpot, "invalid spot writes preserve the existing file byte-for-byte")
        let sampleMinute = perpetualTime.addingTimeInterval(60)
        let spotSample = MinuteCandle(symbol: spot.symbol, minute: sampleMinute,
            open: 100_050, high: 100_070, low: 100_050, close: 100_070, volume: nil, session: .spot,
            origin: .localSample, firstEvent: sampleMinute, lastEvent: sampleMinute.addingTimeInterval(5),
            observedAt: sampleMinute.addingTimeInterval(6), sampleCount: 2, volumeBase: 0.01)
        try await archive.save(symbol: spot.symbol, candles: [spotSample])
        check(try await archive.load(symbol: spot.symbol) == [spot, spotSample],
              "local spot samples retain explicit base volume without inventing contract counts")
        let missingFinality = MinuteCandle(symbol: perpetual.symbol, minute: perpetualTime,
            open: 33, high: 34, low: 32, close: 33, volume: nil, session: .perpetual,
            origin: .okx, firstEvent: perpetualTime, lastEvent: perpetualTime,
            observedAt: perpetualTime.addingTimeInterval(60), sampleCount: 0)
        do {
            try await archive.save(symbol: perpetual.symbol, candles: [missingFinality])
            check(false, "OKX cache without finality must not be silently dropped on restore")
        } catch CandleArchiveError.invalidCandle { check(true, "OKX finality is required before persistence") }
        try await archive.save(symbol: "AMD", candles: [original, next])
        let restored = try await archive.load(symbol: "AMD")
        check(restored == [original, next], "roundtrip preserves OHLC, volume, provenance and event timestamps exactly")
        let legacyFile = temporary.appendingPathComponent("primary/AMD/2026-11-20.json")
        var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: legacyFile)) as! [String: Any]
        legacy.removeValue(forKey: "previousClose")
        try JSONSerialization.data(withJSONObject: legacy).write(to: legacyFile)
        let legacyBundle = try await archive.loadBundle(symbol: "AMD")
        check(legacyBundle.candles == restored && legacyBundle.references.isEmpty,
              "schema 1 legacy file without a baseline loads unchanged")
        let baseline = ChartReference(day: "2026-11-20", previousClose: 98)
        try await archive.save(symbol: "AMD", candles: [original], references: [baseline.day: baseline])
        let withBaseline = try await archive.loadBundle(symbol: "AMD")
        check(withBaseline.references == [baseline.day: baseline], "day-specific previous close survives disk roundtrip")

        let correction = fixture(close: 104, origin: .yahoo)
        try await archive.save(symbol: "AMD", candles: [correction])
        let updated = try await archive.load(symbol: "AMD")
        check(updated == [correction, next], "same-minute update preserves omitted same-day minutes")
        let refreshedBundle = try await archive.loadBundle(symbol: "AMD")
        check(refreshedBundle.references == [baseline.day: baseline], "candle-only refresh retains stored previous close")
        try await archive.save(symbol: "AMD", candles: [fixture(close: 101, observedOffset: 49)])
        let afterStaleWrite = try await archive.load(symbol: "AMD")
        check(afterStaleWrite == updated, "older observation cannot overwrite newer same-minute cache")

        // UTC has changed day, but this remains November 20 in New York.
        let evening = fixture(offset: 12 * 3600)
        try await archive.save(symbol: "AMD", candles: [evening])
        let dayFolder = temporary.appendingPathComponent("primary/AMD", isDirectory: true)
        let dayFiles = try FileManager.default.contentsOfDirectory(atPath: dayFolder.path)
        check(dayFiles == ["2026-11-20.json"], "file boundaries use New York date rather than UTC date")
        try await archive.save(symbol: "AMD", candles: [fixture(offset: 86_400)],
                               references: [baseline.day: baseline])
        let twoDays = try await archive.loadBundle(symbol: "AMD")
        check(twoDays.references["2026-11-21"] == nil && twoDays.references[baseline.day] == baseline,
              "previous close is never copied into another date")
        let beforeMismatch = try Data(contentsOf: legacyFile)
        do {
            try await archive.save(symbol: "AMD", candles: [original], references: [
                baseline.day: ChartReference(day: "2026-11-21", previousClose: 99)
            ])
            check(false, "reference payload date must match its cache date")
        } catch CandleArchiveError.invalidCandle {
            check(true, "reference payload date must match its cache date")
        }
        check(try Data(contentsOf: legacyFile) == beforeMismatch, "invalid baseline cannot rewrite existing cache")

        let retention = CandleArchive(directory: temporary.appendingPathComponent("retention"))
        let elevenDays = (0..<11).map { fixture(offset: TimeInterval($0) * 86_400) }
        try await retention.save(symbol: "AMD", candles: elevenDays)
        let recent = try await retention.load(symbol: "AMD")
        check(recent == Array(elevenDays.dropFirst()), "load returns only the most recent ten stored dates")
        let retainedFiles = try FileManager.default.contentsOfDirectory(atPath:
            temporary.appendingPathComponent("retention/AMD").path)
        check(retainedFiles.count == 11, "loading recent dates never deletes old data")

        let target = dayFolder.appendingPathComponent("2026-11-20.json")
        let corrupted = Data("{damaged fixture".utf8)
        try corrupted.write(to: target)
        do {
            _ = try await archive.load(symbol: "AMD")
            check(false, "corrupted cache fails whole load")
        } catch CandleArchiveError.invalidFile {
            check(true, "corrupted cache fails whole load")
        }
        do {
            try await archive.save(symbol: "AMD", candles: [original])
            check(false, "save refuses to overwrite corrupted target file")
        } catch CandleArchiveError.invalidFile {
            check(true, "save refuses to overwrite corrupted target file")
        }
        check(try Data(contentsOf: target) == corrupted, "corrupted original remains byte-for-byte unchanged")

        do {
            try await archive.save(symbol: "NVDA", candles: [original])
            check(false, "wrong-symbol candle rejected before write")
        } catch CandleArchiveError.invalidCandle {
            check(true, "wrong-symbol candle rejected before write")
        }
        let invalidProvenance = MinuteCandle(symbol: "NVDA", minute: base,
            open: 100, high: 100, low: 100, close: 100, volume: 500,
            session: .pre, origin: .localSample, firstEvent: base, lastEvent: base,
            observedAt: base, sampleCount: 2)
        do {
            try await archive.save(symbol: "NVDA", candles: [invalidProvenance])
            check(false, "local sample with fabricated market volume rejected")
        } catch CandleArchiveError.invalidCandle {
            check(true, "local sample with fabricated market volume rejected")
        }
        let invalidEvents = MinuteCandle(symbol: "NVDA", minute: base,
            open: 100, high: 100, low: 100, close: 100, volume: nil,
            session: .pre, origin: .localSample,
            firstEvent: base.addingTimeInterval(-1), lastEvent: base,
            observedAt: base, sampleCount: 2)
        do {
            try await archive.save(symbol: "NVDA", candles: [invalidEvents])
            check(false, "event outside its minute rejected")
        } catch CandleArchiveError.invalidCandle {
            check(true, "event outside its minute rejected")
        }
    } catch {
        failures.append("unexpected archive check error: \(error.localizedDescription)")
    }
    if failures.isEmpty {
        print("PASS archive checks: \(count) deterministic checks (temporary files, no network)")
        return true
    }
    print("FAIL archive checks: \(failures.count) failures / \(count) checks")
    failures.forEach { print("  \($0)") }
    return false
}
