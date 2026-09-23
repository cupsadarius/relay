import AVFoundation
import XCTest

@testable import Relay

@MainActor
final class AppleTTSBackendTests: XCTestCase {
    func testIdentifiesAsApple() {
        let backend = makeBackend()

        XCTAssertEqual(backend.id, "apple-tts")
        XCTAssertEqual(backend.displayName, "Apple System Voice")
    }

    func testAvailabilityIsAlwaysAvailable() async {
        let backend = makeBackend()

        let availability = await backend.availability()

        XCTAssertEqual(availability, .available)
    }

    /// A stale saved voice id (e.g. a voice the user deleted) must fall back to the default voice.
    /// Throwing `.invalidInput` there is not fallback-worthy, so it used to stop all TTS.
    func testMakeAudioSourceFallsBackToTheDefaultVoiceForAnUnknownVoiceIdentifier() async throws {
        let synthesizerCount = SynthesizerCounter()
        let backend = makeBackend(synthesizerCount: synthesizerCount)

        let source = try await backend.makeAudioSource(
            text: "hello",
            options: TTSOptions(voiceIdentifier: "not-a-real-voice")
        )

        XCTAssertTrue(source is AppleTTSAudioSource)
        XCTAssertEqual(synthesizerCount.value, 1)
    }

    func testMakeAudioSourceWithDefaultVoiceReturnsAnAppleSource() async throws {
        let backend = makeBackend()

        let source = try await backend.makeAudioSource(text: "hello", options: TTSOptions())

        XCTAssertTrue(source is AppleTTSAudioSource)
    }

    func testMakeAudioSourceBuildsAFreshSynthesizerPerCall() async throws {
        let synthesizerCount = SynthesizerCounter()
        let backend = makeBackend(synthesizerCount: synthesizerCount)

        _ = try await backend.makeAudioSource(text: "one", options: TTSOptions())
        _ = try await backend.makeAudioSource(text: "two", options: TTSOptions())

        XCTAssertEqual(synthesizerCount.value, 2, "Each speech attempt must own an isolated synthesizer")
    }

    // MARK: Helpers

    private func makeBackend(synthesizerCount: SynthesizerCounter = SynthesizerCounter()) -> AppleTTSBackend {
        AppleTTSBackend(
            makeSynthesizer: {
                synthesizerCount.value += 1
                return FakeAppleSynthesizer()
            },
            bufferConverter: FakeBufferConverter()
        )
    }
}

/// Counts synthesizer factory calls. Only ever touched on the main actor (in the factory closure
/// and test assertions), so it needs no isolation of its own - and staying non-isolated lets it be
/// a default-argument value in a nonisolated context.
private final class SynthesizerCounter {
    var value = 0
}

@MainActor
private final class FakeAppleSynthesizer: AppleSpeechSynthesizing {
    func write(_ utterance: AVSpeechUtterance, toBufferCallback bufferCallback: @escaping AVSpeechSynthesizer.BufferCallback) {}
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool { true }
}

private struct FakeBufferConverter: AppleSpeechBufferConverting {
    func frame(from buffer: AVAudioPCMBuffer) throws -> TTSAudioFrame {
        TTSAudioFrame(
            samples: [],
            format: TTSAudioFormat(sampleRate: buffer.format.sampleRate, channelCount: 1)
        )
    }
}
