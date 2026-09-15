import XCTest
@testable import Relay

final class SpeechBackendContractsTests: XCTestCase {
    func testBackendErrorFallbackClassification() {
        XCTAssertTrue(SpeechBackendError.unavailable("x").isFallbackWorthy)
        XCTAssertTrue(SpeechBackendError.modelNotDownloaded.isFallbackWorthy)
        XCTAssertTrue(SpeechBackendError.initializationFailed("x").isFallbackWorthy)
        XCTAssertTrue(SpeechBackendError.unsupportedOS.isFallbackWorthy)
        XCTAssertTrue(SpeechBackendError.unsupportedHardware.isFallbackWorthy)
        XCTAssertTrue(SpeechBackendError.inferenceFailed("x").isFallbackWorthy)
        XCTAssertTrue(SpeechBackendError.resourceExhausted.isFallbackWorthy)
        XCTAssertFalse(SpeechBackendError.permissionDenied.isFallbackWorthy)
        XCTAssertFalse(SpeechBackendError.noUsableAudio.isFallbackWorthy)
        XCTAssertFalse(SpeechBackendError.invalidInput.isFallbackWorthy)
    }

    func testSTTCapabilityMembership() {
        let capabilities = STTCapabilities([
            .streaming,
            .multilingual,
            .timestamps,
            .partialResults,
            .customVocabulary,
            .fullyOffline,
        ])

        XCTAssertTrue(capabilities.contains(.streaming))
        XCTAssertTrue(capabilities.contains(.multilingual))
        XCTAssertTrue(capabilities.contains(.timestamps))
        XCTAssertTrue(capabilities.contains(.partialResults))
        XCTAssertTrue(capabilities.contains(.customVocabulary))
        XCTAssertTrue(capabilities.contains(.fullyOffline))

        let batchOnly = STTCapabilities([.fullyOffline])
        XCTAssertFalse(batchOnly.contains(.streaming))
    }

    func testTTSCapabilityMembership() {
        let capabilities = TTSCapabilities([
            .pauseResume,
            .voiceSelection,
            .fullyOffline,
            .outputLevel,
        ])

        XCTAssertTrue(capabilities.contains(.pauseResume))
        XCTAssertTrue(capabilities.contains(.voiceSelection))
        XCTAssertTrue(capabilities.contains(.fullyOffline))
        XCTAssertTrue(capabilities.contains(.outputLevel))

        let fixedVoice = TTSCapabilities([.fullyOffline])
        XCTAssertFalse(fixedVoice.contains(.voiceSelection))
        XCTAssertFalse(fixedVoice.contains(.outputLevel))
    }

    func testBackendsExposeCapabilitiesThroughProviderNeutralContracts() async {
        let stt = ContractSTTBackend()
        XCTAssertTrue(stt.capabilities.contains(.partialResults))

        let tts = await MainActor.run { ContractTTSBackend() }
        let supportsPauseResume = await MainActor.run {
            tts.capabilities.contains(.pauseResume)
        }
        XCTAssertTrue(supportsPauseResume)
    }
}

private struct ContractSTTBackend: SpeechToTextBackend {
    let id = "contract-stt"
    let displayName = "Contract STT"
    let capabilities = STTCapabilities([.partialResults])

    func availability() async -> BackendAvailability { .available }
    func prepare() async throws {}

    func transcribe(audio: AudioInput, options: STTOptions) async throws -> Transcript {
        Transcript(text: "", backendID: id)
    }
}

@MainActor
private final class ContractTTSBackend: TextToSpeechBackend {
    let id = "contract-tts"
    let displayName = "Contract TTS"
    let capabilities = TTSCapabilities([.pauseResume])

    func availability() async -> BackendAvailability { .available }
    func setPlaybackEventHandler(_ handler: @escaping @MainActor (TTSPlaybackEvent) -> Void) {}
    func speak(text: String, options: TTSOptions, sessionID: UUID) async throws {}
    func stop() {}
    func pause() {}
    func resume() {}
}
