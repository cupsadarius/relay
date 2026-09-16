import AVFoundation
import XCTest
@testable import Relay

/// `SynthesizedAudioPlayer` decode and error-mapping tests run unconditionally: they never start
/// an `AVAudioPlayer` and so never depend on the test host having a usable audio output device.
/// Tests that exercise real playback (which requires an `AVAudioPlayer` to actually play) are
/// gated behind `requireAudioOutput()` and skip themselves with `XCTSkip` on a host that can't
/// start one, per the plan's "keep audio-producing assertions capability-gated" guidance.
@MainActor
final class SynthesizedAudioPlayerTests: XCTestCase {
    // MARK: - Unconditional: decode

    func testDecodeValidWavDoesNotThrow() throws {
        let wav = Self.makeWavData()

        let buffer = try SynthesizedAudioPlayer.decode(wav)

        XCTAssertGreaterThan(buffer.frameLength, 0)
    }

    func testDecodeMalformedDataThrows() {
        let malformed = Data([0x00, 0x01, 0x02, 0x03])

        XCTAssertThrowsError(try SynthesizedAudioPlayer.decode(malformed))
    }

    func testLevelEnvelopeOfSilentBufferIsNearZero() {
        let buffer = Self.makePCMBuffer(amplitude: 0, durationSeconds: 0.2)

        let envelope = SynthesizedAudioPlayer.levelEnvelope(from: buffer, windowSeconds: 0.04)

        XCTAssertFalse(envelope.isEmpty)
        XCTAssertTrue(envelope.allSatisfy { $0 < 0.01 }, "Expected near-zero levels, got \(envelope)")
    }

    func testLevelEnvelopeOfFullScaleBufferIsNearOne() {
        let buffer = Self.makePCMBuffer(amplitude: 1, durationSeconds: 0.2)

        let envelope = SynthesizedAudioPlayer.levelEnvelope(from: buffer, windowSeconds: 0.04)

        XCTAssertFalse(envelope.isEmpty)
        XCTAssertTrue(envelope.allSatisfy { $0 > 0.99 }, "Expected near-one levels, got \(envelope)")
    }

    func testStartPlaybackWithMalformedDataThrowsWithoutStartingPlayback() async {
        let player = SynthesizedAudioPlayer()
        var events: [TTSPlaybackEvent] = []
        player.onEvent = { events.append($0) }
        let sessionID = UUID()

        do {
            try await player.startPlayback(Data([0x00, 0x01, 0x02, 0x03]), sessionID: sessionID)
            XCTFail("Expected a decode error")
        } catch {
            // Expected: any decode error. Mapped to a fallback-worthy SpeechBackendError and a
            // .failed playback event by KokoroTTSBackend, not by the player itself.
        }

        XCTAssertTrue(events.isEmpty, "A decode failure must not emit any playback lifecycle event")
    }

    // MARK: - Audio-producing: requires a working audio output device

    /// `startPlayback` must return as soon as playback has started - never waiting for it to
    /// finish. `.finished` always arrives later, asynchronously, through `onEvent`.
    func testStartPlaybackEmitsScheduledThenStartedAndReturnsBeforeFinishedArrivesLater() async throws {
        try requireAudioOutput()
        let player = SynthesizedAudioPlayer()
        let events = EventBox()
        player.onEvent = { events.append($0) }
        let sessionID = UUID()

        try await player.startPlayback(Self.makeWavData(), sessionID: sessionID)

        // startPlayback has already returned here: only .scheduled/.started so far, never
        // .finished - proving this call did not wait for playback to terminate.
        XCTAssertEqual(events.values.filter { !$0.isLevel }, [
            .scheduled(sessionID: sessionID),
            .started(sessionID: sessionID),
        ])

        try await waitUntil { events.values.contains(.finished(sessionID: sessionID)) }

        let recorded = events.values.filter { !$0.isLevel }
        XCTAssertEqual(recorded, [
            .scheduled(sessionID: sessionID),
            .started(sessionID: sessionID),
            .finished(sessionID: sessionID),
        ])
        XCTAssertTrue(recorded.allSatisfy { $0.sessionID == sessionID })
    }

    func testStopMidPlayEmitsCancelledInsteadOfFinished() async throws {
        try requireAudioOutput()
        let player = SynthesizedAudioPlayer()
        let events = EventBox()
        player.onEvent = { events.append($0) }
        let sessionID = UUID()

        // A few seconds of audio so playback is still in flight once startPlayback returns.
        try await player.startPlayback(Self.makeWavData(durationSeconds: 3), sessionID: sessionID)
        XCTAssertTrue(events.values.contains(.started(sessionID: sessionID)))

        player.stop()

        let recorded = events.values.filter { !$0.isLevel }
        XCTAssertEqual(recorded, [
            .scheduled(sessionID: sessionID),
            .started(sessionID: sessionID),
            .cancelled(sessionID: sessionID),
        ])
        XCTAssertFalse(recorded.contains(.finished(sessionID: sessionID)))
    }

    func testStopWithNoActivePlaybackIsANoOp() {
        let player = SynthesizedAudioPlayer()
        let events = EventBox()
        player.onEvent = { events.append($0) }

        player.stop()

        XCTAssertTrue(events.values.isEmpty)
    }

    /// Skips the calling test unless explicitly opted in via an environment variable.
    ///
    /// Playback used to go through a hand-built `AVAudioEngine` graph, and starting that engine
    /// did not merely throw on a sandboxed automated test host with no usable audio output
    /// device - confirmed experimentally, it hard-crashed the whole test process with a fatal
    /// Objective-C assertion inside CoreAudio (`AVAudioEngineGraph.mm:1322:Initialize:
    /// (inputNode != nullptr || outputNode != nullptr)`), even for a bare `AVAudioEngine()` with
    /// nothing attached, and that crash was not catchable from Swift. Playback now goes through
    /// `AVAudioPlayer` instead, which does not have that failure mode, but these tests are kept
    /// behind the same `RELAY_TEST_REAL_AUDIO_ENGINE=1` gate (rather than assumed safe by
    /// default) since a sandboxed CI host may still have no usable output device at all. Set the
    /// variable on a normal interactive Mac with a real audio output device to run these
    /// assertions; real playback is otherwise exercised manually, per the implementation plan's
    /// acceptance pass ("Test Voice speaks in the Kokoro voice... the overlay pill shows a live
    /// speaking waveform").
    private func requireAudioOutput() throws {
        guard ProcessInfo.processInfo.environment["RELAY_TEST_REAL_AUDIO_ENGINE"] == "1" else {
            throw XCTSkip(
                "Skipping: starting a real AVAudioEngine crashes (not throws) in this sandboxed "
                    + "test host. Set RELAY_TEST_REAL_AUDIO_ENGINE=1 on a machine with a real "
                    + "audio output device to run this assertion; otherwise it is covered by the "
                    + "plan's manual acceptance pass."
            )
        }
    }

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

    /// Builds a mono `AVAudioPCMBuffer` of constant `amplitude` (a square wave, so its RMS equals
    /// `amplitude` exactly) for exercising `levelEnvelope(from:windowSeconds:)` without decoding
    /// a WAV or touching `AVAudioEngine`.
    private static func makePCMBuffer(amplitude: Float, durationSeconds: Double, sampleRate: Double = 24_000) -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(max(1, Int(durationSeconds * sampleRate)))
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let samples = buffer.floatChannelData![0]
        for frame in 0..<Int(frameCount) {
            samples[frame] = frame.isMultiple(of: 2) ? amplitude : -amplitude
        }
        return buffer
    }

    /// Generates a minimal, valid 16-bit PCM mono WAV file in memory (a short sine wave) so
    /// tests never touch a real audio asset or the network.
    private static func makeWavData(durationSeconds: Double = 0.1, sampleRate: Double = 24_000) -> Data {
        let sampleCount = max(1, Int(durationSeconds * sampleRate))
        var samples: [Int16] = []
        samples.reserveCapacity(sampleCount)
        for index in 0..<sampleCount {
            let radians = 2.0 * Double.pi * 440.0 * Double(index) / sampleRate
            let value = sin(radians) * 0.2 * Double(Int16.max)
            samples.append(Int16(value))
        }

        let dataSize = samples.count * MemoryLayout<Int16>.size
        var data = Data()

        func appendASCII(_ string: String) {
            data.append(contentsOf: Array(string.utf8))
        }
        func appendUInt32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func appendUInt16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        appendASCII("RIFF")
        appendUInt32(UInt32(36 + dataSize))
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16)
        appendUInt16(1) // PCM
        appendUInt16(1) // mono
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate) * 2)
        appendUInt16(2)
        appendUInt16(16)
        appendASCII("data")
        appendUInt32(UInt32(dataSize))
        for sample in samples {
            appendUInt16(UInt16(bitPattern: sample))
        }
        return data
    }
}

private extension TTSPlaybackEvent {
    var isLevel: Bool {
        if case .level = self { return true }
        return false
    }
}

/// Accumulates playback events from a `@MainActor`-isolated `onEvent` callback so a test can poll
/// them from an `async` context.
@MainActor
private final class EventBox {
    private(set) var values: [TTSPlaybackEvent] = []
    func append(_ event: TTSPlaybackEvent) { values.append(event) }
}
