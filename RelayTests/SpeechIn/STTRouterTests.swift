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
            (.initializing, .unavailable("Backend is initializing")),
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

    func testPreferredBackendDisplayNameReturnsFirstAvailableBackend() async {
        let first = FakeSTTBackend(id: "first")
        let second = FakeSTTBackend(id: "second")
        let router = makeRouter([first, second])

        let name = await router.preferredBackendDisplayName()

        XCTAssertEqual(name, "first")
    }

    func testPreferredBackendDisplayNameSkipsUnavailableBackends() async {
        let first = FakeSTTBackend(id: "first")
        first.availabilityValue = .unavailable("offline")
        let second = FakeSTTBackend(id: "second")
        let router = makeRouter([first, second])

        let name = await router.preferredBackendDisplayName()

        XCTAssertEqual(name, "second")
    }

    func testPreferredBackendDisplayNameIsNilWhenNoneAreAvailable() async {
        let first = FakeSTTBackend(id: "first")
        first.availabilityValue = .unavailable("offline")
        let router = makeRouter([first])

        let name = await router.preferredBackendDisplayName()

        XCTAssertNil(name)
    }

    func testPreferredBackendDisplayNameTreatsPermissionDeniedAsTerminal() async {
        let first = FakeSTTBackend(id: "first")
        first.availabilityValue = .permissionDenied
        let second = FakeSTTBackend(id: "second")
        let router = makeRouter([first, second])

        let name = await router.preferredBackendDisplayName()

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

    func testTranscribeReusesTheSelectionCachedByPreferredBackendDisplayNameWithoutReprobingSkippedBackends() async throws {
        let first = FakeSTTBackend(id: "first")
        first.availabilityValue = .unavailable("offline")
        let second = FakeSTTBackend(id: "second")
        let router = makeRouter([first, second])

        let name = await router.preferredBackendDisplayName()
        XCTAssertEqual(name, "second")
        XCTAssertEqual(first.availabilityCallCount, 1)
        XCTAssertEqual(second.availabilityCallCount, 1)

        let transcript = try await router.transcribe(audio: audio, options: .init())

        XCTAssertEqual(transcript, Transcript(text: "second", backendID: "second"))
        // "first" was already ruled out by the lookup above and must not be re-probed; "second"
        // is re-checked once more (the one backend the cache actually resumes from).
        XCTAssertEqual(first.availabilityCallCount, 1)
        XCTAssertEqual(second.availabilityCallCount, 2)
    }

    func testCachedSelectionIsClearedAfterOneTranscribeCallSoALaterCallReprobesFromScratch() async throws {
        let first = FakeSTTBackend(id: "first")
        first.availabilityValue = .unavailable("offline")
        let second = FakeSTTBackend(id: "second")
        let router = makeRouter([first, second])

        _ = await router.preferredBackendDisplayName()
        _ = try await router.transcribe(audio: audio, options: .init())

        first.availabilityValue = .available
        let transcript = try await router.transcribe(audio: audio, options: .init())

        XCTAssertEqual(transcript, Transcript(text: "first", backendID: "first"))
    }

    func testInterimTranscribeCallsDoNotConsumeOrDisturbTheCachedSelectionForTheFinalCall() async throws {
        let first = FakeSTTBackend(id: "first")
        first.availabilityValue = .unavailable("offline")
        let second = FakeSTTBackend(id: "second")
        let router = makeRouter([first, second])

        let name = await router.preferredBackendDisplayName()
        XCTAssertEqual(name, "second")
        XCTAssertEqual(first.availabilityCallCount, 1)

        // Each interim tick does its own fresh full walk (by design, so it never touches the
        // cache), so it re-checks "first" every time - that's expected. What matters is that
        // none of these calls consume or clear the cache the lookup above populated.
        for _ in 0..<3 {
            let interim = try await router.transcribeForInterim(audio: audio, options: .init())
            XCTAssertEqual(interim, Transcript(text: "second", backendID: "second"))
        }
        XCTAssertEqual(first.availabilityCallCount, 4)

        let final = try await router.transcribe(audio: audio, options: .init())

        XCTAssertEqual(final, Transcript(text: "second", backendID: "second"))
        XCTAssertEqual(first.availabilityCallCount, 4)
    }

    func testTranscribeForInterimAlwaysWalksTheFullCurrentBackendOrder() async throws {
        let first = FakeSTTBackend(id: "first")
        first.availabilityValue = .unavailable("offline")
        let second = FakeSTTBackend(id: "second")
        let router = makeRouter([first, second])

        let interim = try await router.transcribeForInterim(audio: audio, options: .init())

        XCTAssertEqual(interim, Transcript(text: "second", backendID: "second"))
        XCTAssertEqual(first.availabilityCallCount, 1)
        XCTAssertEqual(second.availabilityCallCount, 1)
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

    private func makeRouter(_ backends: [FakeSTTBackend]) -> STTRouter {
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
    let capabilities = STTCapabilities([])
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
    func prepare() async throws {}

    func transcribe(audio: AudioInput, options: STTOptions) async throws -> Transcript {
        transcriptionCount += 1
        if let error { throw error }
        return Transcript(text: id, backendID: id)
    }
}
