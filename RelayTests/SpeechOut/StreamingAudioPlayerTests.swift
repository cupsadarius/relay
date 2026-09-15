import AVFoundation
import XCTest
@testable import Relay

/// `level(forFrame:)` tests run unconditionally: they're pure and never touch `AVAudioEngine`.
/// Tests that exercise real playback are gated behind `requireAudioOutput()` and skip themselves
/// with `XCTSkip` on a host with no usable audio output device, mirroring
/// `SynthesizedAudioPlayerTests`'s "keep audio-producing assertions capability-gated" approach.
@MainActor
final class StreamingAudioPlayerTests: XCTestCase {
    // MARK: - Unconditional: level(forFrame:)

    func testLevelOfSilentFrameIsZero() {
        let level = StreamingAudioPlayer.level(forFrame: [Float](repeating: 0, count: 1_920))

        XCTAssertEqual(level, 0)
    }

    func testLevelOfEmptyFrameIsZero() {
        XCTAssertEqual(StreamingAudioPlayer.level(forFrame: []), 0)
    }

    func testLevelOfFullScaleFrameClampsToOne() {
        let level = StreamingAudioPlayer.level(forFrame: [Float](repeating: 1, count: 1_920))

        XCTAssertEqual(level, 1)
    }

    func testLevelOfMidAmplitudeFrameScalesByGainFour() {
        // RMS of a constant-amplitude signal equals the amplitude itself, so the result should be
        // exactly amplitude * 4 (the same gain SynthesizedAudioPlayer.levelEnvelope applies).
        let amplitude: Float = 0.2
        let level = StreamingAudioPlayer.level(forFrame: [Float](repeating: amplitude, count: 1_920))

        XCTAssertEqual(level, amplitude * 4, accuracy: 0.0001)
    }

    // MARK: - Audio-producing: requires a working audio output device

    func testPlayEmitsScheduledThenStartedThenFinishedForTheGivenSession() async throws {
        try requireAudioOutput()
        let player = StreamingAudioPlayer()
        let events = EventBox()
        player.onEvent = { events.append($0) }
        let sessionID = UUID()

        try await player.play(Self.makeFrameStream(frameCount: 3), sampleRate: 24_000, sessionID: sessionID)

        let recorded = events.values
        XCTAssertEqual(recorded.filter { !$0.isLevel }, [
            .scheduled(sessionID: sessionID),
            .started(sessionID: sessionID),
            .finished(sessionID: sessionID),
        ])
        XCTAssertTrue(recorded.allSatisfy { $0.sessionID == sessionID })
    }

    /// The other real-engine tests in this file use short streams (a handful of 80ms frames) that
    /// never accumulate the ~0.6s prebuffer threshold, so `.started` fires via the stream-end
    /// fallback in `play(_:sampleRate:sessionID:)` instead of the `bufferedSeconds >=
    /// prebufferSeconds` branch. This test feeds enough frames (20 * 80ms = 1.6s, well past the
    /// 0.6s threshold) with no inter-frame delay that the threshold is guaranteed to be crossed
    /// while the source stream is still being drained, exercising the prebuffer-flush path in
    /// `startPlayback` instead.
    func testPlayStartsViaThePrebufferThresholdWhenEnoughAudioArrivesBeforeStreamEnd() async throws {
        try requireAudioOutput()
        let player = StreamingAudioPlayer()
        let events = EventBox()
        player.onEvent = { events.append($0) }
        let sessionID = UUID()

        try await player.play(Self.makeFrameStream(frameCount: 20), sampleRate: 24_000, sessionID: sessionID)

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
        let player = StreamingAudioPlayer()
        let events = EventBox()
        player.onEvent = { events.append($0) }
        let sessionID = UUID()

        // Enough frames, trickled in slowly, that there's time to call stop() before the source
        // finishes and before all scheduled audio has played back.
        let playTask = Task {
            try await player.play(
                Self.makeFrameStream(frameCount: 200, delayNanoseconds: 20_000_000),
                sampleRate: 24_000,
                sessionID: sessionID
            )
        }
        try await waitUntil { events.values.contains(.started(sessionID: sessionID)) }

        player.stop()
        try await playTask.value

        let recorded = events.values.filter { !$0.isLevel }
        XCTAssertEqual(recorded, [
            .scheduled(sessionID: sessionID),
            .started(sessionID: sessionID),
            .cancelled(sessionID: sessionID),
        ])
        XCTAssertFalse(recorded.contains(.finished(sessionID: sessionID)))
    }

    func testStopWithNoActivePlaybackIsANoOp() {
        let player = StreamingAudioPlayer()
        let events = EventBox()
        player.onEvent = { events.append($0) }

        player.stop()

        XCTAssertTrue(events.values.isEmpty)
    }

    /// Skips the calling test unless explicitly opted in via an environment variable. See
    /// `SynthesizedAudioPlayerTests.requireAudioOutput` for why: starting a real `AVAudioEngine`
    /// can hard-crash (not throw) a sandboxed test host with no usable audio output device.
    private func requireAudioOutput() throws {
        guard ProcessInfo.processInfo.environment["RELAY_TEST_REAL_AUDIO_ENGINE"] == "1" else {
            throw XCTSkip(
                "Skipping: starting a real AVAudioEngine crashes (not throws) in this sandboxed "
                    + "test host. Set RELAY_TEST_REAL_AUDIO_ENGINE=1 on a machine with a real "
                    + "audio output device to run this assertion."
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

    /// Builds a short sine-wave frame stream of `frameCount` 1920-sample (80ms @ 24kHz) frames,
    /// optionally sleeping `delayNanoseconds` between frames to simulate a source trickling in
    /// slower than instantaneous - long enough for a mid-play `stop()` to land.
    private static func makeFrameStream(
        frameCount: Int,
        delayNanoseconds: UInt64 = 0
    ) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { continuation in
            Task {
                for _ in 0..<frameCount {
                    var frame = [Float](repeating: 0, count: 1_920)
                    for sampleIndex in 0..<frame.count {
                        let radians = 2.0 * Double.pi * 440.0 * Double(sampleIndex) / 24_000
                        frame[sampleIndex] = Float(sin(radians) * 0.2)
                    }
                    continuation.yield(frame)
                    if delayNanoseconds > 0 {
                        try? await Task.sleep(nanoseconds: delayNanoseconds)
                    }
                }
                continuation.finish()
            }
        }
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
