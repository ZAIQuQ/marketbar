import Foundation
import Darwin

// Small dependency-free test runner: usable with Apple's Command Line Tools,
// which does not ship XCTest. Failures always produce a nonzero exit status.
private var failureCount = 0

private func fail(_ message: String, file: StaticString, line: UInt) {
    failureCount += 1
    print("FAIL \(file):\(line): \(message)")
}

func XCTAssertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "",
                                  file: StaticString = #filePath, line: UInt = #line) {
    if actual != expected { fail("\(actual) != \(expected) \(message)", file: file, line: line) }
}

func XCTAssertEqual(_ actual: Double, _ expected: Double, accuracy: Double,
                    file: StaticString = #filePath, line: UInt = #line) {
    if !actual.isFinite || abs(actual - expected) > accuracy {
        fail("\(actual) != \(expected) within \(accuracy)", file: file, line: line)
    }
}

func XCTAssertNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
    if value != nil { fail("Expected nil", file: file, line: line) }
}

func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
    do {
        _ = try expression()
        fail("Expected error \(message)", file: file, line: line)
    } catch { }
}

private struct UnwrapError: Error {}
func XCTUnwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else {
        fail("Expected non-nil value", file: file, line: line)
        throw UnwrapError()
    }
    return value
}

@main
struct CoreTestRunner {
    static func main() {
        let decoder = YahooDecoderTests()
        let watchlist = WatchlistTests()
        let candles = CandleTests()
        let references = ChartReferenceTests()
        let okx = OKXTests()
        let tests: [(String, () throws -> Void)] = [
            ("observed premarket stream", decoder.testObservedPremarketFrameAndJSONEnvelope),
            ("stream session flags", decoder.testPremarketRegularAndPostmarketFlags),
            ("unknown protobuf fields and heartbeats", decoder.testUnknownFieldsAreSkippedAndHeartbeatIgnored),
            ("malformed and truncated frames", decoder.testMalformedAndTruncatedFramesThrowWithoutTrapping),
            ("premarket snapshot overrides prior regular quote", decoder.testSnapshotChoosesNewerPremarketBarOverYesterdayRegularQuote),
            ("postmarket snapshot reference", decoder.testSnapshotChoosesPostmarketAndUsesRegularReference),
            ("regular metadata session stays regular", decoder.testRegularMetadataNeverAcquiresCurrentExtendedSession),
            ("sparse bars and unequal lengths", decoder.testSparseUnsortedBarsAndUnequalLengths),
            ("provider early-close schedule", decoder.testProviderTradingPeriodsHandleEarlyClose),
            ("prior early-close uncertainty", decoder.testPriorEarlyCloseIsUnknownWhenOnlyNextDayScheduleExists),
            ("New York DST and boundaries", decoder.testNewYorkDSTAndExactBoundaries),
            ("invalid charts and symbol mismatch", decoder.testInvalidChartAndSymbolMismatchFailClosed),
            ("watchlist aliases and deduplication", watchlist.testNormalizesAliasesAndDeduplicatesInOrder),
            ("watchlist invalid input", watchlist.testRejectsEmptyInvalidAndOversizedLists),
            ("candles preserve gaps and reject malformed OHLC", candles.testChartKeepsGapsAndSkipsMalformedOHLC),
            ("candles merge duplicate current minute", candles.testDuplicateCurrentMinuteAggregatesWithoutDoubleVolume),
            ("candles validate currency symbol and interval", candles.testChartRejectsWrongCurrencySymbolAndGranularity),
            ("candles session boundaries and DST", candles.testSessionBoundariesAndDST),
            ("candles old premarket and early-close uncertainty", candles.testPriorDayPremarketAndEarlyCloseUncertainty),
            ("candles local event order and no snapshot samples", candles.testLocalSamplesPreserveEventOrderAndIgnoreSnapshots),
            ("candles remote/local refresh precedence", candles.testRemoteLocalPrecedenceAndOldRefreshRejected),
            ("candles partial refresh preserves extrema", candles.testPartialRemoteCannotEraseExistingMinuteExtremes),
            ("candles restore validation and mixed provenance", candles.testRestoreValidatesAndPreservesLiveSamplesAndMixedProvenance),
            ("candles restored samples without fake volume", candles.testRestoredLocalSamplesCombineWithoutInventingVolume),
            ("candles completed minute late events", candles.testCompletedMinuteRetainsOHLCWhenLateEventsArrive),
            ("candles reject future remote rows", candles.testFutureRemoteBarsAreSkipped),
            ("candles HTTP receipt does not rewind local event", candles.testLaterHTTPResponseDoesNotRewindNewerLocalEvent),
            ("candles source event order beats HTTP order", candles.testOlderPartialSourceTimeCannotReplaceNewerPartial),
            ("candles completed coverage remains explicit", candles.testLatePartialCannotReopenCompletedMinuteOrClaimCompletion),
            ("reference premarket uses prior regular price", references.testPremarketUsesYesterdayRegularPriceInsteadOfOlderPreviousClose),
            ("reference regular and postmarket prior close", references.testRegularAndPostmarketUseSameDayPriorClose),
            ("reference rejects mismatched days and ranges", references.testMismatchedDaysAndLongRangeHaveNoReference),
            ("reference validates baseline currency and symbol", references.testMissingBaselineInvalidPriceCurrencyAndSymbol),
            ("reference ignores null future bar", references.testNullFutureBarCannotSelectWrongTradingDay),
            ("reference percent calculation and persistence", references.testPercentChangeAndCodable),
            ("OKX explicit perpetual symbols and alias", okx.testPerpetualWatchlistAliasesDoNotChangeEquityMeaning),
            ("OKX display units and UTC partition", okx.testPerpetualDisplayCurrencyAndUTCPartition),
            ("OKX observed ticker and UTC open", okx.testObservedTickerHasMessageTimestampAndUTCOpenReference),
            ("OKX tickers never generate candle samples", okx.testBidAskTickerUpdatesNeverGeneratePriceSamples),
            ("OKX errors and instrument mismatches", okx.testTickerRejectsProviderErrorsAndWrongInstrument),
            ("OKX executions generate local samples", okx.testTradesUseExecutionTimeAndCreateLocalSamples),
            ("OKX candle confirmation and invalid rows", okx.testCandlesDecodeConfirmationAndSkipInvalidRows),
            ("OKX final candle precedence and restore", okx.testOKXFinalFlagControlsCompletionAndLaterPartialCannotReopen),
            ("OKX current candle upserts", okx.testOKXCurrentMinuteUpsertsAndOlderResponseIsIgnored),
            ("OKX model additions preserve legacy JSON", okx.testLegacyReferenceAndCandleJSONStillDecode)
        ]
        for (name, test) in tests {
            let before = failureCount
            do { try test() }
            catch { fail("\(name): \(error)", file: #filePath, line: #line) }
            if failureCount == before { print("PASS \(name)") }
        }
        print("\(tests.count) checks; \(failureCount) failure(s)")
        if failureCount > 0 { exit(1) }
    }
}
