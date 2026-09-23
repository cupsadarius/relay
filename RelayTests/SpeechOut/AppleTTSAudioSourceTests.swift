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

    func testCallbackNeverBlocksEvenWithFarMoreAudioThanTheHighWatermark() async throws {
        let synth = FakeWriteSynthesizer()
        let source = AppleTTSAudioSource(
            text: "hi",
            rate: 0.5,
            voiceIdentifier: nil,
            synthesizer: synth,
            converter: ScriptedConverter(),
            highWatermark: 0.1,
            lowWatermark: 0.05
        )

        let pull = Task { try await source.next() }
        try await waitUntil { synth.hasCallback }
        let callback = UncheckedBufferCallback(try XCTUnwrap(synth.callbackForTesting))
        let allReturned = expectation(description: "every Apple callback returned without blocking")

        // 64 x 100 ms = 6.4 s of audio against a 0.1 s high watermark, fired from a background
        // thread the way Apple does. The old count-based bridge blocked here after 8 buffers.
        DispatchQueue.global().async {
            for _ in 0..<64 {
                callback.call(Self.backgroundBuffer(frames: 2_400))
            }
            callback.call(Self.backgroundBuffer(frames: 0))
            allReturned.fulfill()
        }
        await fulfillment(of: [allReturned], timeout: 2)

        _ = try await pull.value
        var frames = 1
        while try await source.next() != nil { frames += 1 }
        XCTAssertEqual(frames, 64)
    }

    func testCancelBeforeTheFirstNextNeverStartsSynthesis() async {
        let synth = FakeWriteSynthesizer()
        let source = AppleTTSAudioSource(
            text: "hi",
            rate: 0.5,
            voiceIdentifier: nil,
            synthesizer: synth,
            converter: ScriptedConverter()
        )

        await source.cancel()

        do {
            _ = try await source.next()
            XCTFail("A source cancelled before its first pull must not produce audio")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("Unexpected \(error)")
        }
        XCTAssertTrue(synth.writtenUtterances.isEmpty, "cancel before next() must not start synthesis")
    }

    nonisolated private static func backgroundBuffer(frames: Int) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(frames, 1)))!
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
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

/// Lets a test invoke Apple's buffer callback from a background thread, as Apple does.
private final class UncheckedBufferCallback: @unchecked Sendable {
    private let callback: AVSpeechSynthesizer.BufferCallback
    init(_ callback: @escaping AVSpeechSynthesizer.BufferCallback) { self.callback = callback }
    func call(_ buffer: AVAudioBuffer) { callback(buffer) }
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
    private(set) var writtenUtterances: [AVSpeechUtterance] = []
    private(set) var stopCount = 0
    private var callback: AVSpeechSynthesizer.BufferCallback?

    var hasCallback: Bool { callback != nil }
    var callbackForTesting: AVSpeechSynthesizer.BufferCallback? { callback }

    func write(_ utterance: AVSpeechUtterance, toBufferCallback bufferCallback: @escaping AVSpeechSynthesizer.BufferCallback) {
        writtenUtterances.append(utterance)
        callback = bufferCallback
    }

    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        stopCount += 1
        return true
    }

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
