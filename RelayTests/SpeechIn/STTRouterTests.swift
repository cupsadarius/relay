import XCTest

@testable import Relay

@MainActor
final class STTRouterTests: XCTestCase {
    func testFallsBackWhenPrimaryIsUnavailable() async throws {
        try await assertFallsBack(after: .unavailable("offline"))
    }

    func testFallsBackWhenPrimaryModelIsNotDownloaded() async throws {
        try await assertFallsBack(after: .modelNotDownloaded)
    }

    func testFallsBackWhenPrimaryInitializationFails() async throws {
        try await assertFallsBack(after: .initializationFailed("failed"))
    }

    func testFallsBackWhenPrimaryExhaustsResources() async throws {
        try await assertFallsBack(after: .resourceExhausted)
    }

    func testTranscribeAnnouncesTheFallbackBackend() async throws {
        let first = FakeSTTBackend(id: .parakeet, error: .modelNotDownloaded)
        let second = FakeSTTBackend(id: .appleSpeech)
        let recorder = PipelineEventRecorder()

        _ = try await makeRouter([first, second]).transcribe(audio: audio, options: .init(), tracer: recorder.tracer(.dictation))

        let parakeet = BackendID.parakeet.displayName
        let apple = BackendID.appleSpeech.displayName
        let steps = await recorder.steps()
        XCTAssertEqual(
            steps,
            [
                .init(step: .transcribe, phase: .started("Transcribing with \(parakeet)")),
                .init(step: .transcribe, phase: .failed("\(parakeet) failed")),
                .init(step: .fallback, phase: .started("Falling back to \(apple)")),
                .init(step: .fallback, phase: .finished(apple)),
            ])
    }

    func testTranscribeAnnouncesTheBackendThatSucceeded() async throws {
        let recorder = PipelineEventRecorder()
        _ = try await makeRouter([FakeSTTBackend(id: .parakeet)]).transcribe(
            audio: audio, options: .init(), tracer: recorder.tracer(.dictation))

        let name = BackendID.parakeet.displayName
        let steps = await recorder.steps()
        XCTAssertEqual(
            steps,
            [
                .init(step: .transcribe, phase: .started("Transcribing with \(name)")),
                .init(step: .transcribe, phase: .finished(name)),
            ])
    }

    func testStopsImmediatelyWhenPrimaryDeniesPermission() async {
        await assertStopsRouting(after: .permissionDenied)
    }

    func testStopsImmediatelyWhenPrimaryAvailabilityDeniesPermission() async {
        let first = FakeSTTBackend(id: .appleSpeech)
        first.availabilityValue = .permissionDenied
        let second = FakeSTTBackend(id: .parakeet)
        let router = makeRouter([first, second])

        do {
            _ = try await router.transcribe(audio: audio, options: .init())
            XCTFail("Expected permissionDenied")
        } catch {
            XCTAssertEqual(error as? SpeechBackendError, .permissionDenied)
        }
        XCTAssertEqual(first.transcriptionCount, 0)
        XCTAssertEqual(second.transcriptionCount, 0)
    }

    func testStopsImmediatelyWhenPrimaryHasNoUsableAudio() async {
        await assertStopsRouting(after: .noUsableAudio)
    }

    func testReturnsLastFallbackWorthyErrorWhenAllBackendsFail() async {
        let first = FakeSTTBackend(id: .appleSpeech, error: .unavailable("offline"))
        let second = FakeSTTBackend(id: .parakeet, error: .resourceExhausted)
        let router = makeRouter([first, second])

        do {
            _ = try await router.transcribe(audio: audio, options: .init())
            XCTFail("Expected resourceExhausted")
        } catch {
            XCTAssertEqual(error as? SpeechBackendError, .resourceExhausted)
        }
        XCTAssertEqual(first.transcriptionCount, 1)
        XCTAssertEqual(second.transcriptionCount, 1)
    }

    func testReturnsMappedAvailabilityErrorWhenNoBackendCanTranscribe() async {
        let first = FakeSTTBackend(id: .appleSpeech)
        first.availabilityValue = .unavailable("offline")
        let second = FakeSTTBackend(id: .parakeet)
        second.availabilityValue = .failed("setup failed")
        let router = makeRouter([first, second])

        do {
            _ = try await router.transcribe(audio: audio, options: .init())
            XCTFail("Expected initializationFailed")
        } catch {
            XCTAssertEqual(error as? SpeechBackendError, .initializationFailed("setup failed"))
        }
        XCTAssertEqual(first.transcriptionCount, 0)
        XCTAssertEqual(second.transcriptionCount, 0)
    }

    func testMapsFallbackWorthyAvailabilityStatesToSpeechBackendErrors() async {
        let cases: [(BackendAvailability, SpeechBackendError)] = [
            (.unavailable("offline"), .unavailable("offline")),
            (.modelNotDownloaded, .modelNotDownloaded),
            (.unsupportedHardware, .unsupportedHardware),
            (.failed("setup failed"), .initializationFailed("setup failed")),
        ]

        for (availability, expectedError) in cases {
            let backend = FakeSTTBackend(id: .appleSpeech)
            backend.availabilityValue = availability
            let router = makeRouter([backend])

            do {
                _ = try await router.transcribe(audio: audio, options: .init())
                XCTFail("Expected \(expectedError)")
            } catch {
                XCTAssertEqual(error as? SpeechBackendError, expectedError)
            }
            XCTAssertEqual(backend.transcriptionCount, 0)
        }
    }

    func testUsesCurrentBackendOrderForEveryTranscription() async throws {
        let first = FakeSTTBackend(id: .appleSpeech)
        let second = FakeSTTBackend(id: .parakeet)
        var order: [BackendID] = [.appleSpeech, .parakeet]
        let router = STTRouter(
            backends: [.appleSpeech: first, .parakeet: second],
            backendOrder: { order }
        )

        let firstTranscript = try await router.transcribe(audio: audio, options: .init())
        order = [.parakeet, .appleSpeech]
        let secondTranscript = try await router.transcribe(audio: audio, options: .init())

        XCTAssertEqual(firstTranscript, Transcript(text: "apple-speech", backendID: .appleSpeech))
        XCTAssertEqual(secondTranscript, Transcript(text: "parakeet", backendID: .parakeet))
    }

    func testSelectBackendReturnsFirstAvailableBackend() async {
        let first = FakeSTTBackend(id: .appleSpeech)
        let second = FakeSTTBackend(id: .parakeet)
        let router = makeRouter([first, second])

        let name = await router.selectBackend()?.displayName

        XCTAssertEqual(name, BackendID.appleSpeech.displayName)
    }

    func testSelectBackendSkipsUnavailableBackends() async {
        let first = FakeSTTBackend(id: .appleSpeech)
        first.availabilityValue = .unavailable("offline")
        let second = FakeSTTBackend(id: .parakeet)
        let router = makeRouter([first, second])

        let name = await router.selectBackend()?.displayName

        XCTAssertEqual(name, BackendID.parakeet.displayName)
    }

    func testSelectBackendIsNilWhenNoneAreAvailable() async {
        let first = FakeSTTBackend(id: .appleSpeech)
        first.availabilityValue = .unavailable("offline")
        let router = makeRouter([first])

        let name = await router.selectBackend()?.displayName

        XCTAssertNil(name)
    }

    func testSelectBackendTreatsPermissionDeniedAsTerminal() async {
        let first = FakeSTTBackend(id: .appleSpeech)
        first.availabilityValue = .permissionDenied
        let second = FakeSTTBackend(id: .parakeet)
        let router = makeRouter([first, second])

        let name = await router.selectBackend()?.displayName

        XCTAssertNil(name)
        XCTAssertEqual(second.availabilityCallCount, 0)
    }

    func testSelectBackendReturnsTheRemainingCandidateOrder() async {
        let first = FakeSTTBackend(id: .appleSpeech)
        first.availabilityValue = .unavailable("offline")
        let second = FakeSTTBackend(id: .parakeet)
        let third = FakeSTTBackend(id: .whisper)
        let router = makeRouter([first, second, third])

        let selection = await router.selectBackend()

        XCTAssertEqual(selection, STTSelection(displayName: BackendID.parakeet.displayName, candidateOrder: [.parakeet, .whisper]))
    }

    func testTranscribeWithASelectionStartsAtTheSelectedBackend() async throws {
        let first = FakeSTTBackend(id: .appleSpeech)
        first.availabilityValue = .unavailable("offline")
        let second = FakeSTTBackend(id: .parakeet)
        let router = makeRouter([first, second])
        let selection = await router.selectBackend()
        first.availabilityValue = .available

        let transcript = try await router.transcribe(audio: audio, options: .init(), selection: selection)

        XCTAssertEqual(transcript, Transcript(text: "parakeet", backendID: .parakeet))
        XCTAssertEqual(first.availabilityCallCount, 1, "the selection already ruled out 'first'")
        XCTAssertEqual(first.transcriptionCount, 0)
    }

    func testSelectBackendLeavesNoHiddenStateForALaterTranscribe() async throws {
        let first = FakeSTTBackend(id: .appleSpeech)
        first.availabilityValue = .unavailable("offline")
        let second = FakeSTTBackend(id: .parakeet)
        let router = makeRouter([first, second])
        _ = await router.selectBackend()
        first.availabilityValue = .available

        let transcript = try await router.transcribe(audio: audio, options: .init())

        XCTAssertEqual(transcript, Transcript(text: "apple-speech", backendID: .appleSpeech))
    }

    func testInterimUsesOnlyTheFirstAvailableBackendAndNeverFallsBack() async {
        let first = FakeSTTBackend(id: .appleSpeech, error: .initializationFailed("cold"))
        let second = FakeSTTBackend(id: .parakeet)
        let router = makeRouter([first, second])

        do {
            _ = try await router.transcribeForInterim(audio: audio, options: .init())
            XCTFail("Interim must surface the first backend's error")
        } catch {
            XCTAssertEqual(error as? SpeechBackendError, .initializationFailed("cold"))
        }
        XCTAssertEqual(second.transcriptionCount, 0, "a fallback would load a second model on every interim tick")
        XCTAssertEqual(second.availabilityCallCount, 0)
    }

    func testInterimSkipsUnavailableBackendsToFindTheFirstAvailableOne() async throws {
        let first = FakeSTTBackend(id: .appleSpeech)
        first.availabilityValue = .modelNotDownloaded
        let second = FakeSTTBackend(id: .parakeet)
        let router = makeRouter([first, second])

        let transcript = try await router.transcribeForInterim(audio: audio, options: .init())

        XCTAssertEqual(transcript, Transcript(text: "parakeet", backendID: .parakeet))
    }

    func testTranscribeStopsAtTheNextBackendWhenTheTaskIsCancelled() async {
        let first = FakeSTTBackend(id: .appleSpeech)
        let router = makeRouter([first])

        let task = Task { @MainActor in try await router.transcribe(audio: audio, options: .init()) }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("Unexpected \(error)")
        }
        XCTAssertEqual(first.availabilityCallCount, 0)
        XCTAssertEqual(first.transcriptionCount, 0)
    }

    func testCancellationDuringTranscriptionPropagatesWithoutRecordingAFailedBackend() async {
        let cancelling = CancellingSTTBackend(id: .appleSpeech)
        let router = makeRouter([cancelling])

        do {
            _ = try await router.transcribe(audio: audio, options: .init())
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("Unexpected \(error)")
        }
        XCTAssertNil(router.lastFailedBackendDisplayName, "a cancellation is not a backend failure")
    }

    func testTranscribeWithoutAPrecedingLookupPerformsItsOwnFullWalk() async throws {
        let first = FakeSTTBackend(id: .appleSpeech)
        first.availabilityValue = .unavailable("offline")
        let second = FakeSTTBackend(id: .parakeet)
        let router = makeRouter([first, second])

        let transcript = try await router.transcribe(audio: audio, options: .init())

        XCTAssertEqual(transcript, Transcript(text: "parakeet", backendID: .parakeet))
        XCTAssertEqual(first.availabilityCallCount, 1)
        XCTAssertEqual(second.availabilityCallCount, 1)
    }

    // MARK: lastFailedBackendDisplayName

    func testRecordsTheBackendWhoseErrorWasThrown() async {
        let first = FakeSTTBackend(id: .appleSpeech, error: .unavailable("offline"))
        let second = FakeSTTBackend(id: .parakeet, error: .resourceExhausted)
        let router = makeRouter([first, second])

        _ = try? await router.transcribe(audio: audio, options: .init())

        XCTAssertEqual(router.lastFailedBackendDisplayName, BackendID.parakeet.displayName)
    }

    func testRecordsASkippedBackendWhenItsAvailabilityErrorIsThrown() async {
        let first = FakeSTTBackend(id: .appleSpeech)
        first.availabilityValue = .modelNotDownloaded
        let router = makeRouter([first])

        _ = try? await router.transcribe(audio: audio, options: .init())

        XCTAssertEqual(router.lastFailedBackendDisplayName, BackendID.appleSpeech.displayName)
    }

    func testClearsTheFailedBackendAfterASuccessfulTranscription() async throws {
        let first = FakeSTTBackend(id: .appleSpeech, error: .unavailable("offline"))
        let router = makeRouter([first])
        _ = try? await router.transcribe(audio: audio, options: .init())
        XCTAssertEqual(router.lastFailedBackendDisplayName, BackendID.appleSpeech.displayName)

        first.error = nil
        _ = try await router.transcribe(audio: audio, options: .init())

        XCTAssertNil(router.lastFailedBackendDisplayName)
    }

    func testInterimFailuresNeverTouchTheFailedBackend() async {
        let first = FakeSTTBackend(id: .appleSpeech, error: .unavailable("offline"))
        let router = makeRouter([first])

        _ = try? await router.transcribeForInterim(audio: audio, options: .init())

        XCTAssertNil(router.lastFailedBackendDisplayName)
    }

    func testTranscribeWithASelectionRecordsTheBackendWhoseErrorWasThrown() async {
        let first = FakeSTTBackend(id: .appleSpeech, error: .resourceExhausted)
        let router = makeRouter([first])
        let selection = await router.selectBackend()

        _ = try? await router.transcribe(audio: audio, options: .init(), selection: selection)

        XCTAssertEqual(router.lastFailedBackendDisplayName, BackendID.appleSpeech.displayName)
    }

    func testUnregisteredIDsInTheOrderAreSkipped() async throws {
        let known = FakeSTTBackend(id: .parakeet)
        let router = STTRouter(backends: [.parakeet: known], backendOrder: { [.appleSpeech, .parakeet] })

        _ = try await router.transcribe(audio: audio, options: .init())

        XCTAssertEqual(known.transcriptionCount, 1)
    }

    private let audio = AudioInput(samples: [0.1], sampleRate: 16_000)

    private func assertFallsBack(after error: SpeechBackendError) async throws {
        let first = FakeSTTBackend(id: .appleSpeech, error: error)
        let second = FakeSTTBackend(id: .parakeet)
        let router = makeRouter([first, second])

        let transcript = try await router.transcribe(audio: audio, options: .init())

        XCTAssertEqual(transcript, Transcript(text: "parakeet", backendID: .parakeet))
        XCTAssertEqual(first.transcriptionCount, 1)
        XCTAssertEqual(second.transcriptionCount, 1)
    }

    private func assertStopsRouting(after expectedError: SpeechBackendError) async {
        let first = FakeSTTBackend(id: .appleSpeech, error: expectedError)
        let second = FakeSTTBackend(id: .parakeet)
        let router = makeRouter([first, second])

        do {
            _ = try await router.transcribe(audio: audio, options: .init())
            XCTFail("Expected \(expectedError)")
        } catch {
            XCTAssertEqual(error as? SpeechBackendError, expectedError)
        }
        XCTAssertEqual(first.transcriptionCount, 1)
        XCTAssertEqual(second.transcriptionCount, 0)
    }

    private func makeRouter(_ backends: [any SpeechToTextBackend]) -> STTRouter {
        STTRouter(
            backends: Dictionary(uniqueKeysWithValues: backends.map { ($0.id, $0) }),
            backendOrder: { backends.map(\.id) }
        )
    }
}

@MainActor
private final class FakeSTTBackend: SpeechToTextBackend {
    let id: BackendID
    var availabilityValue: BackendAvailability = .available
    var error: SpeechBackendError?
    private(set) var transcriptionCount = 0
    private(set) var availabilityCallCount = 0

    init(id: BackendID, error: SpeechBackendError? = nil) {
        self.id = id
        self.error = error
    }

    func availability() async -> BackendAvailability {
        availabilityCallCount += 1
        return availabilityValue
    }

    func transcribe(audio: AudioInput, options: STTOptions) async throws -> Transcript {
        transcriptionCount += 1
        if let error { throw error }
        return Transcript(text: id.rawValue, backendID: id)
    }
}

/// A backend whose `transcribe` always throws `CancellationError` directly, simulating the task
/// being cancelled mid-transcription (as opposed to `Task.checkCancellation()` at the top of the
/// router's loop, which `testTranscribeStopsAtTheNextBackendWhenTheTaskIsCancelled` already
/// covers).
@MainActor
private final class CancellingSTTBackend: SpeechToTextBackend {
    let id: BackendID

    init(id: BackendID) {
        self.id = id
    }

    func availability() async -> BackendAvailability { .available }

    func transcribe(audio: AudioInput, options: STTOptions) async throws -> Transcript {
        throw CancellationError()
    }
}
