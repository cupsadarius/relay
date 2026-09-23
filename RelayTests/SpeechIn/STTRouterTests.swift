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

    func testStopsImmediatelyWhenPrimaryDeniesPermission() async {
        await assertStopsRouting(after: .permissionDenied)
    }

    func testStopsImmediatelyWhenPrimaryAvailabilityDeniesPermission() async {
        let first = FakeSTTBackend(id: "first")
        first.availabilityValue = .permissionDenied
        let second = FakeSTTBackend(id: "second")
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
        let first = FakeSTTBackend(id: "first", error: .unavailable("offline"))
        let second = FakeSTTBackend(id: "second", error: .resourceExhausted)
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
        let first = FakeSTTBackend(id: "first")
        first.availabilityValue = .unavailable("offline")
        let second = FakeSTTBackend(id: "second")
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
            (.unsupportedOS, .unsupportedOS),
            (.unsupportedHardware, .unsupportedHardware),
            (.failed("setup failed"), .initializationFailed("setup failed")),
        ]

        for (availability, expectedError) in cases {
            let backend = FakeSTTBackend(id: "only")
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
        let first = FakeSTTBackend(id: "first")
        let second = FakeSTTBackend(id: "second")
        var order = ["first", "second"]
        let router = STTRouter(
            backends: ["first": first, "second": second],
            backendOrder: { order }
        )

        let firstTranscript = try await router.transcribe(audio: audio, options: .init())
        order = ["second", "first"]
        let secondTranscript = try await router.transcribe(audio: audio, options: .init())

        XCTAssertEqual(firstTranscript, Transcript(text: "first", backendID: "first"))
        XCTAssertEqual(secondTranscript, Transcript(text: "second", backendID: "second"))
    }

    func testSelectBackendReturnsFirstAvailableBackend() async {
        let first = FakeSTTBackend(id: "first")
        let second = FakeSTTBackend(id: "second")
        let router = makeRouter([first, second])

        let name = await router.selectBackend()?.displayName

        XCTAssertEqual(name, "first")
    }

    func testSelectBackendSkipsUnavailableBackends() async {
        let first = FakeSTTBackend(id: "first")
        first.availabilityValue = .unavailable("offline")
        let second = FakeSTTBackend(id: "second")
        let router = makeRouter([first, second])

        let name = await router.selectBackend()?.displayName

        XCTAssertEqual(name, "second")
    }

    func testSelectBackendIsNilWhenNoneAreAvailable() async {
        let first = FakeSTTBackend(id: "first")
        first.availabilityValue = .unavailable("offline")
        let router = makeRouter([first])

        let name = await router.selectBackend()?.displayName

        XCTAssertNil(name)
    }

    func testSelectBackendTreatsPermissionDeniedAsTerminal() async {
        let first = FakeSTTBackend(id: "first")
        first.availabilityValue = .permissionDenied
        let second = FakeSTTBackend(id: "second")
        let router = makeRouter([first, second])

        let name = await router.selectBackend()?.displayName

        XCTAssertNil(name)
        XCTAssertEqual(second.availabilityCallCount, 0)
    }

    func testDisplayNameForBackendIDReturnsTheConfiguredBackendsName() {
        let first = FakeSTTBackend(id: "first")
        let second = FakeSTTBackend(id: "second")
        let router = makeRouter([first, second])

        XCTAssertEqual(router.displayName(forBackendID: "first"), "first")
        XCTAssertEqual(router.displayName(forBackendID: "second"), "second")
        XCTAssertNil(router.displayName(forBackendID: "missing"))
    }

    func testSelectBackendReturnsTheRemainingCandidateOrder() async {
        let first = FakeSTTBackend(id: "first")
        first.availabilityValue = .unavailable("offline")
        let second = FakeSTTBackend(id: "second")
        let third = FakeSTTBackend(id: "third")
        let router = makeRouter([first, second, third])

        let selection = await router.selectBackend()

        XCTAssertEqual(selection, STTSelection(backendID: "second", displayName: "second", candidateOrder: ["second", "third"]))
    }

    func testTranscribeWithASelectionStartsAtTheSelectedBackend() async throws {
        let first = FakeSTTBackend(id: "first")
        first.availabilityValue = .unavailable("offline")
        let second = FakeSTTBackend(id: "second")
        let router = makeRouter([first, second])
        let selection = await router.selectBackend()
        first.availabilityValue = .available

        let transcript = try await router.transcribe(audio: audio, options: .init(), selection: selection)

        XCTAssertEqual(transcript, Transcript(text: "second", backendID: "second"))
        XCTAssertEqual(first.availabilityCallCount, 1, "the selection already ruled out 'first'")
        XCTAssertEqual(first.transcriptionCount, 0)
    }

    func testSelectBackendLeavesNoHiddenStateForALaterTranscribe() async throws {
        let first = FakeSTTBackend(id: "first")
        first.availabilityValue = .unavailable("offline")
        let second = FakeSTTBackend(id: "second")
        let router = makeRouter([first, second])
        _ = await router.selectBackend()
        first.availabilityValue = .available

        let transcript = try await router.transcribe(audio: audio, options: .init())

        XCTAssertEqual(transcript, Transcript(text: "first", backendID: "first"))
    }

    func testInterimUsesOnlyTheFirstAvailableBackendAndNeverFallsBack() async {
        let first = FakeSTTBackend(id: "first", error: .initializationFailed("cold"))
        let second = FakeSTTBackend(id: "second")
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
        let first = FakeSTTBackend(id: "first")
        first.availabilityValue = .modelNotDownloaded
        let second = FakeSTTBackend(id: "second")
        let router = makeRouter([first, second])

        let transcript = try await router.transcribeForInterim(audio: audio, options: .init())

        XCTAssertEqual(transcript, Transcript(text: "second", backendID: "second"))
    }

    func testTranscribeStopsAtTheNextBackendWhenTheTaskIsCancelled() async {
        let first = FakeSTTBackend(id: "first")
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
        let cancelling = CancellingSTTBackend(id: "first")
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
        let first = FakeSTTBackend(id: "first")
        first.availabilityValue = .unavailable("offline")
        let second = FakeSTTBackend(id: "second")
        let router = makeRouter([first, second])

        let transcript = try await router.transcribe(audio: audio, options: .init())

        XCTAssertEqual(transcript, Transcript(text: "second", backendID: "second"))
        XCTAssertEqual(first.availabilityCallCount, 1)
        XCTAssertEqual(second.availabilityCallCount, 1)
    }

    // MARK: lastFailedBackendDisplayName

    func testRecordsTheBackendWhoseErrorWasThrown() async {
        let first = FakeSTTBackend(id: "first", error: .unavailable("offline"))
        let second = FakeSTTBackend(id: "second", error: .resourceExhausted)
        let router = makeRouter([first, second])

        _ = try? await router.transcribe(audio: audio, options: .init())

        XCTAssertEqual(router.lastFailedBackendDisplayName, "second")
    }

    func testRecordsASkippedBackendWhenItsAvailabilityErrorIsThrown() async {
        let first = FakeSTTBackend(id: "first")
        first.availabilityValue = .modelNotDownloaded
        let router = makeRouter([first])

        _ = try? await router.transcribe(audio: audio, options: .init())

        XCTAssertEqual(router.lastFailedBackendDisplayName, "first")
    }

    func testClearsTheFailedBackendAfterASuccessfulTranscription() async throws {
        let first = FakeSTTBackend(id: "first", error: .unavailable("offline"))
        let router = makeRouter([first])
        _ = try? await router.transcribe(audio: audio, options: .init())
        XCTAssertEqual(router.lastFailedBackendDisplayName, "first")

        first.error = nil
        _ = try await router.transcribe(audio: audio, options: .init())

        XCTAssertNil(router.lastFailedBackendDisplayName)
    }

    func testInterimFailuresNeverTouchTheFailedBackend() async {
        let first = FakeSTTBackend(id: "first", error: .unavailable("offline"))
        let router = makeRouter([first])

        _ = try? await router.transcribeForInterim(audio: audio, options: .init())

        XCTAssertNil(router.lastFailedBackendDisplayName)
    }

    func testTranscribeWithASelectionRecordsTheBackendWhoseErrorWasThrown() async {
        let first = FakeSTTBackend(id: "first", error: .resourceExhausted)
        let router = makeRouter([first])
        let selection = await router.selectBackend()

        _ = try? await router.transcribe(audio: audio, options: .init(), selection: selection)

        XCTAssertEqual(router.lastFailedBackendDisplayName, "first")
    }

    func testUnknownIDsInTheOrderAreSkipped() async throws {
        let known = FakeSTTBackend(id: "known")
        let router = STTRouter(backends: ["known": known], backendOrder: { ["ghost", "known"] })

        _ = try await router.transcribe(audio: audio, options: .init())

        XCTAssertEqual(known.transcriptionCount, 1)
    }

    private let audio = AudioInput(samples: [0.1], sampleRate: 16_000)

    private func assertFallsBack(after error: SpeechBackendError) async throws {
        let first = FakeSTTBackend(id: "first", error: error)
        let second = FakeSTTBackend(id: "second")
        let router = makeRouter([first, second])

        let transcript = try await router.transcribe(audio: audio, options: .init())

        XCTAssertEqual(transcript, Transcript(text: "second", backendID: "second"))
        XCTAssertEqual(first.transcriptionCount, 1)
        XCTAssertEqual(second.transcriptionCount, 1)
    }

    private func assertStopsRouting(after expectedError: SpeechBackendError) async {
        let first = FakeSTTBackend(id: "first", error: expectedError)
        let second = FakeSTTBackend(id: "second")
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
    let id: String
    let displayName: String
    var availabilityValue: BackendAvailability = .available
    var error: SpeechBackendError?
    private(set) var transcriptionCount = 0
    private(set) var availabilityCallCount = 0

    init(id: String, error: SpeechBackendError? = nil) {
        self.id = id
        self.error = error
        displayName = id
    }

    func availability() async -> BackendAvailability {
        availabilityCallCount += 1
        return availabilityValue
    }

    func transcribe(audio: AudioInput, options: STTOptions) async throws -> Transcript {
        transcriptionCount += 1
        if let error { throw error }
        return Transcript(text: id, backendID: id)
    }
}

/// A backend whose `transcribe` always throws `CancellationError` directly, simulating the task
/// being cancelled mid-transcription (as opposed to `Task.checkCancellation()` at the top of the
/// router's loop, which `testTranscribeStopsAtTheNextBackendWhenTheTaskIsCancelled` already
/// covers).
@MainActor
private final class CancellingSTTBackend: SpeechToTextBackend {
    let id: String
    let displayName: String

    init(id: String) {
        self.id = id
        displayName = id
    }

    func availability() async -> BackendAvailability { .available }

    func transcribe(audio: AudioInput, options: STTOptions) async throws -> Transcript {
        throw CancellationError()
    }
}
