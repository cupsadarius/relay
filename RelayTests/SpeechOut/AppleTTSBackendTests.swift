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

    func testAppleBackendReportsSupportedCapabilities() {
        let backend = makeBackend()

        XCTAssertTrue(backend.capabilities.contains(.voiceSelection))
        XCTAssertTrue(backend.capabilities.contains(.fullyOffline))
    }

    func testAvailabilityIsAlwaysAvailable() async {
        let backend = makeBackend()

        let availability = await backend.availability()

        XCTAssertEqual(availability, .available)
    }

    func testMakeAudioSourceRejectsAnUnknownVoiceIdentifierWithoutBuildingASynthesizer() async {
        let synthesizerCount = SynthesizerCounter()
        let backend = makeBackend(synthesizerCount: synthesizerCount)

        do {
            _ = try await backend.makeAudioSource(
                text: "hello",
                options: TTSOptions(voiceIdentifier: "not-a-real-voice")
            )
            XCTFail("Expected invalidInput")
        } catch {
            XCTAssertEqual(error as? SpeechBackendError, .invalidInput)
        }
        XCTAssertEqual(synthesizerCount.value, 0, "An invalid voice must be rejected before any synthesizer is built")
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
    weak var delegate: AVSpeechSynthesizerDelegate?

    func speak(_ utterance: AVSpeechUtterance) {}
    func write(_ utterance: AVSpeechUtterance, toBufferCallback bufferCallback: @escaping AVSpeechSynthesizer.BufferCallback) {}
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool { true }
    func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool { true }
    func continueSpeaking() -> Bool { true }
}

private struct FakeBufferConverter: AppleSpeechBufferConverting {
    func frame(from buffer: AVAudioPCMBuffer) throws -> TTSAudioFrame {
        TTSAudioFrame(
            samples: [],
            format: TTSAudioFormat(sampleRate: buffer.format.sampleRate, channelCount: 1)
        )
    }
}
