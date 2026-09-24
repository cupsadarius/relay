import XCTest

@testable import Relay

final class DictationCleanupDiagnosticTests: XCTestCase {
    func testMessagesAreFixedStructuralStrings() {
        XCTAssertEqual(DictationCleanupDiagnostic.started(model: .qwen3_0_6b).message, "Dictation cleanup started (Qwen3 0.6B)")
        XCTAssertEqual(
            DictationCleanupDiagnostic.finished(model: .appleSystem, elapsed: .underOneSecond).message,
            "Dictation cleanup finished (Apple Intelligence, 0.5–1 s)"
        )
        XCTAssertEqual(
            DictationCleanupDiagnostic.fellBack(model: .qwen3_1_7b, reason: .validationRejected(.literalMissing)).message,
            "Dictation cleanup skipped (Qwen3 1.7B): validation: literal missing"
        )
        XCTAssertEqual(
            DictationCleanupDiagnostic.fellBack(model: nil, reason: .timedOut).message, "Dictation cleanup skipped (none): timed out"
        )
        XCTAssertEqual(DictationCleanupDiagnostic.cancelled(model: .qwen3_0_6b).message, "Dictation cleanup cancelled (Qwen3 0.6B)")
        XCTAssertEqual(
            DictationCleanupDiagnostic.modelLoaded(model: .qwen3_0_6b, elapsed: .over2Point5Seconds).message,
            "Cleanup model loaded (Qwen3 0.6B, >2.5 s)"
        )
        XCTAssertEqual(
            DictationCleanupDiagnostic.modelUnloaded(model: .qwen3_0_6b, cause: .memoryPressure).message,
            "Cleanup model unloaded (Qwen3 0.6B, memory pressure)"
        )
        XCTAssertEqual(DiagnosticsEvent.dictationCleanup(.started(model: .appleSystem)).message, "Dictation cleanup started (Apple Intelligence)")
    }

    func testFallbackLabels() {
        let labels: [(CleanupFallbackReason, String)] = [
            (.appleUnavailable(.appleIntelligenceNotEnabled), "Apple Intelligence is off"),
            (.unsupportedLocale, "unsupported locale"),
            (.modelNotDownloaded, "model not downloaded"),
            (.modelCold, "model cold"),
            (.runtimeBusy, "runtime busy"),
            (.loadFailed, "model load failed"),
            (.generationFailed(.guardrailViolation), "generation: guardrail violation"),
            (.timedOut, "timed out"),
            (.inputTooLong, "input too long"),
            (.validationRejected(.literalInvented), "validation: literal invented"),
        ]
        for (reason, label) in labels {
            XCTAssertEqual(reason.label, label)
        }
    }

    func testLatencyBuckets() {
        XCTAssertEqual(CleanupLatencyBucket(.milliseconds(249)), .under250Milliseconds)
        XCTAssertEqual(CleanupLatencyBucket(.milliseconds(250)), .under500Milliseconds)
        XCTAssertEqual(CleanupLatencyBucket(.milliseconds(999)), .underOneSecond)
        XCTAssertEqual(CleanupLatencyBucket(.milliseconds(2500)), .upTo2Point5Seconds)
        XCTAssertEqual(CleanupLatencyBucket(.milliseconds(2501)), .over2Point5Seconds)
        XCTAssertEqual(
            [CleanupLatencyBucket.under250Milliseconds, .under500Milliseconds, .underOneSecond, .upTo2Point5Seconds, .over2Point5Seconds].map(\.label),
            ["<250 ms", "250–500 ms", "0.5–1 s", "1–2.5 s", ">2.5 s"]
        )
    }
}
