import AVFoundation
import XCTest
@testable import Relay

@MainActor
final class AppleTTSAudioSourceTests: XCTestCase {
    func testVoiceAndRateAreAppliedToTheUtteranceBeforeWrite() async throws {
        let synth = FakeWriteSynthesizer()
        let source = AppleTTSAudioSource(
            text: "hello",
            rate: 0.7,
            voiceIdentifier: nil,
            synthesizer: synth,
            converter: ScriptedConverter()
        )

        let pull = Task { try await source.next() }
        try await waitUntil { synth.hasCallback }

        XCTAssertEqual(synth.writtenUtterances.count, 1)
        XCTAssertEqual(synth.writtenUtterances.first?.rate, 0.7)
        XCTAssertEqual(synth.writtenUtterances.first?.speechString, "hello")

        synth.fireEnd()
        _ = try await pull.value
    }

    func testCallbackBuffersBecomeFramesInOrderThenFinish() async throws {
        let synth = FakeWriteSynthesizer()
        let source = AppleTTSAudioSource(
            text: "hi",
            rate: 0.5,
            voiceIdentifier: nil,
            synthesizer: synth,
            converter: ScriptedConverter()
        )

        let pullFirst = Task { try await source.next() }
        try await waitUntil { synth.hasCallback }

        synth.fire(Self.buffer(frames: 10))
        let first = try await pullFirst.value
        XCTAssertEqual(first?.samples.count, 10)

        synth.fire(Self.buffer(frames: 20))
        let second = try await source.next()
        XCTAssertEqual(second?.samples.count, 20)

        synth.fireEnd()
        let end = try await source.next()
        XCTAssertNil(end)
    }

    func testZeroLengthBufferFinishesTheSource() async throws {
        let synth = FakeWriteSynthesizer()
        let source = AppleTTSAudioSource(
            text: "hi",
            rate: 0.5,
            voiceIdentifier: nil,
            synthesizer: synth,
            converter: ScriptedConverter()
        )

        let pull = Task { try await source.next() }
        try await waitUntil { synth.hasCallback }
        synth.fireEnd()

        let frame = try await pull.value
        XCTAssertNil(frame, "a zero-length callback ends the source")
    }

    func testCancelStopsGenerationAndEndsTheSource() async throws {
        let synth = FakeWriteSynthesizer()
        let source = AppleTTSAudioSource(
            text: "hi",
            rate: 0.5,
            voiceIdentifier: nil,
            synthesizer: synth,
            converter: ScriptedConverter()
        )

        let pull = Task { try await source.next() }
        try await waitUntil { synth.hasCallback }

        await source.cancel()

        do {
            _ = try await pull.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(synth.stopCount, 1)

        // Late callbacks after cancel must not surface frames; the source stays cancelled.
        synth.fire(Self.buffer(frames: 10))
        do {
            _ = try await source.next()
            XCTFail("A cancelled source must not yield frames")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testConverterFailureSurfacesAsSourceFailure() async throws {
        let synth = FakeWriteSynthesizer()
        let source = AppleTTSAudioSource(
            text: "hi",
            rate: 0.5,
            voiceIdentifier: nil,
            synthesizer: synth,
            converter: ScriptedConverter(shouldThrow: true)
        )

        let pull = Task { try await source.next() }
        try await waitUntil { synth.hasCallback }
        synth.fire(Self.buffer(frames: 10))

        do {
            _ = try await pull.value
            XCTFail("Expected a source failure")
        } catch let error as SpeechBackendError {
            XCTAssertEqual(error, .inferenceFailed("Apple speech generation failed"))
        }
    }

    /// A stale saved voice id (e.g. a voice the user deleted) must fall back to the default
    /// voice rather than stopping all TTS. See `AppleTTSBackendTests
    /// .testMakeAudioSourceFallsBackToTheDefaultVoiceForAnUnknownVoiceIdentifier`.
    func testMakeAudioSourceFallsBackToTheDefaultVoiceForAnUnknownVoiceIdentifier() async throws {
        let backend = AppleTTSBackend(
            makeSynthesizer: { FakeWriteSynthesizer() },
            bufferConverter: ScriptedConverter()
        )
        var options = TTSOptions()
        options.voiceIdentifier = "com.example.nonexistent.voice"

        let source = try await backend.makeAudioSource(text: "hi", options: options)

        XCTAssertTrue(source is AppleTTSAudioSource)
    }

    // MARK: - Helpers

    private func waitUntil(
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            await Task.yield()
        }
    }

    private static func buffer(frames: Int, sampleRate: Double = 24_000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(frames, 1)))!
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }
}

private enum ConverterTestError: Error { case boom }

private struct ScriptedConverter: AppleSpeechBufferConverting {
    var shouldThrow = false

    func frame(from buffer: AVAudioPCMBuffer) throws -> TTSAudioFrame {
        if shouldThrow { throw ConverterTestError.boom }
        return TTSAudioFrame(
            samples: [Float](repeating: 0.5, count: Int(buffer.frameLength)),
            format: TTSAudioFormat(sampleRate: buffer.format.sampleRate, channelCount: 1)
        )
    }
}

@MainActor
private final class FakeWriteSynthesizer: AppleSpeechSynthesizing {
    var delegate: AVSpeechSynthesizerDelegate?
    private(set) var writtenUtterances: [AVSpeechUtterance] = []
    private(set) var stopCount = 0
    private var callback: AVSpeechSynthesizer.BufferCallback?

    var hasCallback: Bool { callback != nil }

    func speak(_ utterance: AVSpeechUtterance) {}

    func write(_ utterance: AVSpeechUtterance, toBufferCallback bufferCallback: @escaping AVSpeechSynthesizer.BufferCallback) {
        writtenUtterances.append(utterance)
        callback = bufferCallback
    }

    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        stopCount += 1
        return true
    }

    func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool { true }
    func continueSpeaking() -> Bool { true }

    func fire(_ buffer: AVAudioPCMBuffer) {
        callback?(buffer)
    }

    func fireEnd() {
        callback?(Self.emptyBuffer())
    }

    private static func emptyBuffer() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        buffer.frameLength = 0
        return buffer
    }
}
