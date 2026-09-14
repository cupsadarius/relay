import XCTest
@testable import Relay

final class AppleSpeechBackendTests: XCTestCase {
    func testAvailabilityReturnsUnsupportedOSWhenMacOS26IsUnavailable() async {
        let backend = AppleSpeechBackend(
            isMacOS26OrLater: { false },
            isSpeechTranscriberAvailable: { true }
        )

        let availability = await backend.availability()

        XCTAssertEqual(availability, .unsupportedOS)
    }

    func testAvailabilityReturnsUnsupportedHardwareWhenTranscriberIsUnavailable() async {
        let backend = AppleSpeechBackend(
            isMacOS26OrLater: { true },
            isSpeechTranscriberAvailable: { false }
        )

        let availability = await backend.availability()

        XCTAssertEqual(availability, .unsupportedHardware)
    }

    func testTranscribePreparesAssetsForRequestedLocaleBeforeTranscribing() async throws {
        let recorder = SpeechOperationRecorder()
        let backend = AppleSpeechBackend(
            isMacOS26OrLater: { true },
            isSpeechTranscriberAvailable: { true },
            prepareAssets: { locale in await recorder.recordPrepared(locale) },
            transcribeAudio: { _, locale in
                await recorder.recordTranscribed(locale)
                return "Hello"
            }
        )

        let transcript = try await backend.transcribe(
            audio: AudioInput(samples: [0.1], sampleRate: 16_000),
            options: STTOptions(localeIdentifier: "fr-FR")
        )

        XCTAssertEqual(transcript, Transcript(text: "Hello", backendID: "apple-speech"))
        let operations = await recorder.operations
        XCTAssertEqual(operations, [.prepared("fr-FR"), .transcribed("fr-FR")])
    }

    func testTranscribeMapsAssetPreparationFailureToInitializationFailure() async {
        let backend = AppleSpeechBackend(
            isMacOS26OrLater: { true },
            isSpeechTranscriberAvailable: { true },
            prepareAssets: { _ in throw TestFailure.failed },
            transcribeAudio: { _, _ in "unused" }
        )

        await assertError(
            from: backend,
            equals: .initializationFailed("Apple Speech preparation failed")
        )
    }

    func testPrepareMapsAssetPreparationFailureToInitializationFailure() async {
        let backend = AppleSpeechBackend(
            isMacOS26OrLater: { true },
            isSpeechTranscriberAvailable: { true },
            prepareAssets: { _ in throw TestFailure.failed },
            transcribeAudio: { _, _ in "unused" }
        )

        do {
            try await backend.prepare()
            XCTFail("Expected initialization failure")
        } catch {
            XCTAssertEqual(
                error as? SpeechBackendError,
                .initializationFailed("Apple Speech preparation failed")
            )
        }
    }

    func testTranscribeMapsAnalysisFailureToInferenceFailure() async {
        let backend = AppleSpeechBackend(
            isMacOS26OrLater: { true },
            isSpeechTranscriberAvailable: { true },
            prepareAssets: { _ in },
            transcribeAudio: { _, _ in throw TestFailure.failed }
        )

        await assertError(
            from: backend,
            equals: .inferenceFailed("Apple Speech analysis failed")
        )
    }

    func testTranscribePreservesCancellationFromAnalysis() async {
        let backend = AppleSpeechBackend(
            isMacOS26OrLater: { true },
            isSpeechTranscriberAvailable: { true },
            prepareAssets: { _ in },
            transcribeAudio: { _, _ in throw CancellationError() }
        )

        do {
            _ = try await backend.transcribe(
                audio: AudioInput(samples: [0.1], sampleRate: 16_000),
                options: .init()
            )
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: cancellation remains distinguishable from inference failure.
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }
    }

    func testTranscribeDoesNotReturnLateResultAfterParentTaskIsCancelled() async {
        let gate = TranscriptionGate()
        let started = expectation(description: "transcription started")
        let backend = AppleSpeechBackend(
            isMacOS26OrLater: { true },
            isSpeechTranscriberAvailable: { true },
            prepareAssets: { _ in },
            transcribeAudio: { _, _ in
                started.fulfill()
                await gate.wait()
                return "late result"
            }
        )

        let task = Task {
            try await backend.transcribe(
                audio: AudioInput(samples: [0.1], sampleRate: 16_000),
                options: .init()
            )
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        await gate.open()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation instead of a late transcript")
        } catch is CancellationError {
            // Expected: a cancelled parent task cannot publish a completed transcript.
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }
    }

    private func assertError(
        from backend: AppleSpeechBackend,
        equals expectedError: SpeechBackendError
    ) async {
        do {
            _ = try await backend.transcribe(
                audio: AudioInput(samples: [0.1], sampleRate: 16_000),
                options: .init()
            )
            XCTFail("Expected \(expectedError)")
        } catch {
            XCTAssertEqual(error as? SpeechBackendError, expectedError)
        }
    }
}

private enum TestFailure: Error {
    case failed
}

private actor SpeechOperationRecorder {
    enum Operation: Equatable {
        case prepared(String)
        case transcribed(String)
    }

    private(set) var operations: [Operation] = []

    func recordPrepared(_ locale: Locale) {
        operations.append(.prepared(locale.identifier))
    }

    func recordTranscribed(_ locale: Locale) {
        operations.append(.transcribed(locale.identifier))
    }
}

private actor TranscriptionGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}
