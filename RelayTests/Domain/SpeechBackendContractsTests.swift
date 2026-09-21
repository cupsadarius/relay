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
            .voiceSelection,
            .fullyOffline,
        ])

        XCTAssertTrue(capabilities.contains(.voiceSelection))
        XCTAssertTrue(capabilities.contains(.fullyOffline))

        let fixedVoice = TTSCapabilities([.fullyOffline])
        XCTAssertFalse(fixedVoice.contains(.voiceSelection))
    }

    /// Pause/resume, output levels, and streaming are now guaranteed by the shared Relay playback
    /// pipeline rather than advertised per provider, so every backend exposes the same synthesis
    /// capabilities: voice selection and fully-offline operation.
    func testEveryTTSBackendExposesTheSameSynthesisCapabilities() async {
        let pocket = await MainActor.run { PocketTTSBackend() }
        let kokoro = await MainActor.run { KokoroTTSBackend() }
        let apple = await MainActor.run { AppleTTSBackend() }

        for backend in [pocket as any TextToSpeechBackend, kokoro, apple] {
            let capabilities = await MainActor.run { backend.capabilities }
            XCTAssertTrue(capabilities.contains(.voiceSelection))
            XCTAssertTrue(capabilities.contains(.fullyOffline))
        }
    }

    func testBackendsExposeCapabilitiesThroughProviderNeutralContracts() async {
        let stt = ContractSTTBackend()
        XCTAssertTrue(stt.capabilities.contains(.partialResults))

        let tts = await MainActor.run { ContractTTSBackend() }
        let supportsVoiceSelection = await MainActor.run {
            tts.capabilities.contains(.voiceSelection)
        }
        XCTAssertTrue(supportsVoiceSelection)
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
    let capabilities = TTSCapabilities([.voiceSelection])

    func availability() async -> BackendAvailability { .available }

    func makeAudioSource(text: String, options: TTSOptions) async throws -> any TTSAudioSource {
        FakeTTSAudioSource(backendID: id, text: text, options: options)
    }
}
