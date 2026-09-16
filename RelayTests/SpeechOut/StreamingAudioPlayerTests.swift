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

    /// `startPlayback` must return as soon as playback has started - never waiting for it to
    /// finish. `.finished` always arrives later, asynchronously, through `onEvent`, once the rest
    /// of the (short, 3-frame) stream has been drained and played back in the background.
    func testStartPlaybackEmitsScheduledThenStartedAndReturnsBeforeFinishedArrivesLater() async throws {
        try requireAudioOutput()
        let player = StreamingAudioPlayer()
        let events = EventBox()
        player.onEvent = { events.append($0) }
        let sessionID = UUID()

        try await player.startPlayback(Self.makeFrameStream(frameCount: 3), sampleRate: 24_000, sessionID: sessionID)

        // startPlayback has already returned here. This short stream never crosses the prebuffer
        // threshold, so `.started` fires via the stream-end fallback - by the time it returns,
        // only .scheduled/.started have been observed, never .finished.
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

    /// The other real-engine tests in this file use short streams (a handful of 80ms frames) that
    /// never accumulate the ~0.6s prebuffer threshold, so `.started` fires via the stream-end
    /// fallback in `startPlayback(_:sampleRate:sessionID:)` instead of the `bufferedSeconds >=
    /// prebufferSeconds` branch. This test feeds enough frames (20 * 80ms = 1.6s, well past the
    /// 0.6s threshold) with no inter-frame delay that the threshold is guaranteed to be crossed
    /// while the source stream is still being drained, exercising the prebuffer-flush path in
    /// `beginScheduledPlayback` instead - and proving `startPlayback` returns right there, before
    /// the rest of the (still-draining) stream has finished playing back.
    func testPlayStartsViaThePrebufferThresholdWhenEnoughAudioArrivesBeforeStreamEnd() async throws {
        try requireAudioOutput()
        let player = StreamingAudioPlayer()
        let events = EventBox()
        player.onEvent = { events.append($0) }
        let sessionID = UUID()

        try await player.startPlayback(Self.makeFrameStream(frameCount: 20), sampleRate: 24_000, sessionID: sessionID)

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
        let player = StreamingAudioPlayer()
        let events = EventBox()
        player.onEvent = { events.append($0) }
        let sessionID = UUID()

        // Enough frames, trickled in slowly, that there's still audio in flight once
        // startPlayback returns (right after .started fires via the prebuffer threshold) - so
        // there's time to call stop() before the source finishes and before all scheduled audio
        // has played back.
        try await player.startPlayback(
            Self.makeFrameStream(frameCount: 200, delayNanoseconds: 20_000_000),
            sampleRate: 24_000,
            sessionID: sessionID
        )
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

    /// Regression for a `handlePumpFailure` bug: once playback has already started (so
    /// `startPlayback` has already returned), a later failure draining the rest of the stream
    /// must be reported as exactly one `.failed` event through `onEvent` - never as a thrown
    /// error (nothing is left awaiting one) and never followed by `.finished`.
    func testPostStartFailureEmitsFailedEventInsteadOfThrowingOrFinishing() async throws {
        try requireAudioOutput()
        let player = StreamingAudioPlayer()
        let events = EventBox()
        player.onEvent = { events.append($0) }
        let sessionID = UUID()
        struct FakeStreamFailure: Error {}

        // 20 frames with no inter-frame delay cross the ~0.6s prebuffer threshold while still
        // draining (see testPlayStartsViaThePrebufferThresholdWhenEnoughAudioArrivesBeforeStreamEnd),
        // so `.started` fires before the stream then fails.
        try await player.startPlayback(
            Self.makeFrameStream(frameCount: 20, thenFailWith: FakeStreamFailure()),
            sampleRate: 24_000,
            sessionID: sessionID
        )

        // startPlayback did not throw - it already returned normally once playback started.
        XCTAssertTrue(events.values.contains(.started(sessionID: sessionID)))

        try await waitUntil { events.values.contains(.failed(sessionID: sessionID)) }

        let recorded = events.values.filter { !$0.isLevel }
        XCTAssertEqual(recorded, [
            .scheduled(sessionID: sessionID),
            .started(sessionID: sessionID),
            .failed(sessionID: sessionID),
        ])
        XCTAssertFalse(recorded.contains(.finished(sessionID: sessionID)))
    }

    /// Regression for a `handlePumpFailure` bug: session A starts and its stream is then queued
    /// to fail (buffered, not yet delivered), and only THEN does session B supersede it (a
    /// second `startPlayback` call on the same player cancels A's now-orphaned pump task and
    /// installs B's own, still-pending `startContinuation`) - so A's pump only actually observes
    /// its buffered failure once it is already stale. Before the fix, `handlePumpFailure`
    /// resumed whatever `startContinuation` was currently installed - B's - with A's stale
    /// error, spuriously throwing `startPlayback(B)` even though B's own playback was never at
    /// fault. Both streams are fed through manually-held continuations so the test controls this
    /// exact interleaving precisely.
    func testSupersedingSessionIsUnaffectedByAnOlderSessionsLaterPumpFailure() async throws {
        try requireAudioOutput()
        let player = StreamingAudioPlayer()
        let events = EventBox()
        player.onEvent = { events.append($0) }
        let sessionA = UUID()
        let sessionB = UUID()
        struct StaleSessionFailure: Error {}

        // Session A: fed manually so the test controls exactly when its stream fails.
        var continuationA: AsyncThrowingStream<[Float], Error>.Continuation?
        let streamA = AsyncThrowingStream<[Float], Error> { continuation in
            continuationA = continuation
        }
        let startA = Task { try await player.startPlayback(streamA, sampleRate: 24_000, sessionID: sessionA) }
        // 20 frames cross the prebuffer threshold, so A reaches .started and startA returns.
        for _ in 0..<20 {
            continuationA?.yield(Self.makeSineFrame())
        }
        try await startA.value
        XCTAssertTrue(events.values.contains(.started(sessionID: sessionA)))
        // Let A's pump fully drain the 20 already-buffered frames and settle into genuinely
        // awaiting its 21st, rather than superseding it mid-drain (which would instead make its
        // own per-iteration "am I still the current session" guard end it quietly, before ever
        // reaching a thrown error).
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Queue A's failure BEFORE superseding it with B, so the failure is already buffered on
        // streamA - undelivered - when supersession cancels A's pump task right after. A's pump
        // only actually processes (and throws) this buffered failure once it next gets a turn to
        // run, by which point `currentSessionID` already belongs to B.
        continuationA?.finish(throwing: StaleSessionFailure())

        // Supersede A with B - also fed manually, and given NO frames yet, so B's own
        // startPlayback stays suspended on its own (still-pending) startContinuation. This is
        // the exact window the bug lived in.
        var continuationB: AsyncThrowingStream<[Float], Error>.Continuation?
        let streamB = AsyncThrowingStream<[Float], Error> { continuation in
            continuationB = continuation
        }
        let startB = Task { try await player.startPlayback(streamB, sampleRate: 24_000, sessionID: sessionB) }
        // Let startB install its own startContinuation, and A's pump observe its now-stale
        // buffered failure.
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertFalse(events.values.contains(.failed(sessionID: sessionB)), "A stale session's failure must never fail a newer session")
        XCTAssertFalse(events.values.contains(.failed(sessionID: sessionA)), "A's own failure must not surface either - it was already superseded")

        // startB itself must not have thrown due to A's stale, unrelated failure.
        var startBThrew: (any Error)?
        do {
            // Let B proceed and finish normally, proving it's still a live, healthy session.
            for _ in 0..<20 {
                continuationB?.yield(Self.makeSineFrame())
            }
            continuationB?.finish()
            try await startB.value
        } catch {
            startBThrew = error
        }
        XCTAssertNil(startBThrew, "B's startPlayback must not throw due to A's stale, unrelated failure")
        XCTAssertTrue(events.values.contains(.started(sessionID: sessionB)), "B must still start normally, unaffected by A")
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
    /// slower than instantaneous - long enough for a mid-play `stop()` to land. Finishes
    /// normally unless `thenFailWith` is given, in which case the stream fails with that error
    /// right after its last frame instead.
    private static func makeFrameStream(
        frameCount: Int,
        delayNanoseconds: UInt64 = 0,
        thenFailWith failure: (any Error)? = nil
    ) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { continuation in
            Task {
                for _ in 0..<frameCount {
                    continuation.yield(makeSineFrame())
                    if delayNanoseconds > 0 {
                        try? await Task.sleep(nanoseconds: delayNanoseconds)
                    }
                }
                if let failure {
                    continuation.finish(throwing: failure)
                } else {
                    continuation.finish()
                }
            }
        }
    }

    /// One 1920-sample (80ms @ 24kHz) sine-wave frame, matching the shape
    /// `FluidAudioPocketTTSEngine.synthesizeStream` yields.
    private static func makeSineFrame() -> [Float] {
        var frame = [Float](repeating: 0, count: 1_920)
        for sampleIndex in 0..<frame.count {
            let radians = 2.0 * Double.pi * 440.0 * Double(sampleIndex) / 24_000
            frame[sampleIndex] = Float(sin(radians) * 0.2)
        }
        return frame
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
