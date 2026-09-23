import AVFoundation
import XCTest
@testable import Relay

/// Tests that exercise real playback are gated behind `requireAudioOutput()` and skip themselves
/// with `XCTSkip` on a host with no usable audio output device: keep audio-producing assertions
/// capability-gated.
@MainActor
final class StreamingAudioPlayerTests: XCTestCase {
    // MARK: - Source + demand semantics (headless, via a fake output node)

    func testShortSourceEmitsStartedThenFinishedAfterPlayback() async throws {
        let node = FakeOutputNode()
        let player = StreamingAudioPlayer(makeOutputNode: { node })
        let events = EventBox()
        player.onEvent = { events.append($0) }
        let sessionID = UUID()
        let source = ScriptedAudioSource(steps: [
            .frame(Self.frame(samples: 1_920)),
            .frame(Self.frame(samples: 1_920)),
            .frame(Self.frame(samples: 1_920)),
        ])

        try await player.startPlayback(source, sessionID: sessionID)

        XCTAssertEqual(events.values.filter { !$0.isLevel }, [
            .started(sessionID: sessionID),
        ])
        XCTAssertEqual(node.scheduledCount, 3)

        node.firePlayed(3)
        try await waitUntilAsync { events.values.contains(.finished(sessionID: sessionID)) }

        XCTAssertEqual(events.values.filter { !$0.isLevel }, [
            .started(sessionID: sessionID),
            .finished(sessionID: sessionID),
        ])
    }

    func testLevelsAreEmittedAsBuffersPlayNotWhenTheyAreScheduled() async throws {
        let node = FakeOutputNode()
        let player = StreamingAudioPlayer(makeOutputNode: { node })
        let events = EventBox()
        player.onEvent = { events.append($0) }
        let sessionID = UUID()
        // 10 x 80 ms crosses the 0.6 s prebuffer, so every frame is flushed to the node at once.
        let source = ScriptedAudioSource(steps: (0..<10).map { _ in .frame(Self.frame(samples: 1_920)) })

        try await player.startPlayback(source, sessionID: sessionID)
        try await waitUntilAsync { node.scheduledCount == 10 }

        XCTAssertEqual(events.values.filter(\.isLevel).count, 0, "no level may run ahead of audible audio")

        node.firePlayed(3)
        XCTAssertEqual(events.values.filter(\.isLevel).count, 3, "one level per buffer that actually played")
    }

    func testRouteChangeAfterStartFailsTheSessionOnceAndCancelsTheSource() async throws {
        let node = FakeOutputNode()
        let player = StreamingAudioPlayer(makeOutputNode: { node })
        let events = EventBox()
        player.onEvent = { events.append($0) }
        let sessionID = UUID()
        let source = ScriptedAudioSource(repeating: Self.frame(samples: 1_920))
        try await player.startPlayback(source, sessionID: sessionID)
        XCTAssertTrue(events.values.contains(.started(sessionID: sessionID)))

        node.simulateConfigurationChange()

        let terminal = events.values.filter { !$0.isLevel && $0 != .started(sessionID: sessionID) }
        XCTAssertEqual(terminal, [.failed(sessionID: sessionID)])
        try await waitUntilAsync { await source.wasCancelled() }
        node.firePlayed(node.scheduledCount)
        XCTAssertFalse(events.values.contains(.finished(sessionID: sessionID)))
    }

    func testRouteChangeBeforeStartThrowsFromStartPlaybackWithoutATerminalEvent() async throws {
        let nodes = NodeBox()
        let player = StreamingAudioPlayer(makeOutputNode: {
            let node = FakeOutputNode()
            nodes.append(node)
            return node
        })
        let events = EventBox()
        player.onEvent = { events.append($0) }
        let sessionID = UUID()
        let source = FirstFrameThenHangSource(frame: Self.frame(samples: 1_920))

        let start = Task { try await player.startPlayback(source, sessionID: sessionID) }
        try await waitUntilAsync { !nodes.values.isEmpty }
        nodes.values[0].simulateConfigurationChange()

        do {
            try await start.value
            XCTFail("Expected startPlayback to throw")
        } catch {
            XCTAssertEqual(error as? StreamingAudioPlayerError, .outputConfigurationChanged)
        }
        XCTAssertFalse(events.values.contains(.failed(sessionID: sessionID)))
        try await waitUntilAsync { await source.cancelled }
    }

    func testSourceFailureBeforeStartThrowsAndEmitsNoTerminalEvent() async {
        let node = FakeOutputNode()
        let player = StreamingAudioPlayer(makeOutputNode: { node })
        let events = EventBox()
        player.onEvent = { events.append($0) }
        let sessionID = UUID()
        struct ImmediateFailure: Error {}
        // Fails before the ~0.6s prebuffer threshold is ever reached.
        let source = ScriptedAudioSource(steps: [
            .frame(Self.frame(samples: 1_920)),
            .fail(ImmediateFailure()),
        ])

        do {
            try await player.startPlayback(source, sessionID: sessionID)
            XCTFail("Expected the pre-start source failure to propagate")
        } catch is ImmediateFailure {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let recorded = events.values.filter { !$0.isLevel }
        XCTAssertTrue(recorded.isEmpty)
        XCTAssertFalse(recorded.contains(.started(sessionID: sessionID)))
        XCTAssertFalse(recorded.contains(.failed(sessionID: sessionID)))
    }

    func testPostStartSourceFailureDrainsScheduledAudioThenEmitsFailedOnce() async throws {
        let node = FakeOutputNode()
        let player = StreamingAudioPlayer(makeOutputNode: { node })
        let events = EventBox()
        player.onEvent = { events.append($0) }
        let sessionID = UUID()
        struct LateFailure: Error {}
        // 10 * 80ms crosses the 0.6s prebuffer threshold, so .started fires before the failure.
        var steps: [ScriptedAudioSource.Step] = (0..<10).map { _ in .frame(Self.frame(samples: 1_920)) }
        steps.append(.fail(LateFailure()))
        let source = ScriptedAudioSource(steps: steps)

        try await player.startPlayback(source, sessionID: sessionID)
        XCTAssertTrue(events.values.contains(.started(sessionID: sessionID)))

        // Drain everything already scheduled; failure must surface only after that.
        try await waitUntilAsync { node.scheduledCount >= 10 }
        XCTAssertFalse(events.values.contains(.failed(sessionID: sessionID)), "failure must not precede draining")
        node.firePlayed(node.scheduledCount)

        try await waitUntilAsync { events.values.contains(.failed(sessionID: sessionID)) }
        let recorded = events.values.filter { !$0.isLevel }
        XCTAssertEqual(recorded.filter { $0 == .failed(sessionID: sessionID) }.count, 1)
        XCTAssertFalse(recorded.contains(.finished(sessionID: sessionID)))
    }

    func testStopCancelsActiveSourceAndEmitsCancelledOnce() async throws {
        let node = FakeOutputNode()
        let player = StreamingAudioPlayer(makeOutputNode: { node })
        let events = EventBox()
        player.onEvent = { events.append($0) }
        let sessionID = UUID()
        let source = ScriptedAudioSource(repeating: Self.frame(samples: 1_920))

        try await player.startPlayback(source, sessionID: sessionID)
        XCTAssertTrue(events.values.contains(.started(sessionID: sessionID)))

        player.stop()

        let recorded = events.values.filter { !$0.isLevel }
        XCTAssertEqual(recorded.last, .cancelled(sessionID: sessionID))
        XCTAssertEqual(recorded.filter { $0 == .cancelled(sessionID: sessionID) }.count, 1)
        XCTAssertFalse(recorded.contains(.finished(sessionID: sessionID)))
        try await waitUntilAsync { await source.wasCancelled() }
    }

    /// A source cancelled by something other than `player.stop()` (e.g. its producer was
    /// cancelled) throws `CancellationError` after playback started. That is a cancellation, not
    /// a failure: the session ends `.cancelled` at once, never `.failed` or `.finished`.
    func testPostStartSourceCancellationEndsSessionAsCancelledNotFailed() async throws {
        let node = FakeOutputNode()
        let player = StreamingAudioPlayer(makeOutputNode: { node })
        let events = EventBox()
        player.onEvent = { events.append($0) }
        let sessionID = UUID()
        // 10 * 80ms crosses the 0.6s prebuffer threshold, so .started fires before the cancel.
        var steps: [ScriptedAudioSource.Step] = (0..<10).map { _ in .frame(Self.frame(samples: 1_920)) }
        steps.append(.fail(CancellationError()))
        let source = ScriptedAudioSource(steps: steps)

        try await player.startPlayback(source, sessionID: sessionID)
        XCTAssertTrue(events.values.contains(.started(sessionID: sessionID)))

        // No buffers are marked played: cancellation must not wait for a drain.
        try await waitUntilAsync { events.values.contains(.cancelled(sessionID: sessionID)) }
        XCTAssertEqual(events.values.filter { !$0.isLevel }, [
            .started(sessionID: sessionID),
            .cancelled(sessionID: sessionID),
        ])
    }

    /// Before `.started`, a cancelled source makes `startPlayback` throw `CancellationError` with
    /// no terminal event, so `TTSRouter` treats it as cancellation, not a fallback-worthy failure.
    func testPreStartSourceCancellationThrowsCancellationErrorWithoutTerminalEvent() async {
        let node = FakeOutputNode()
        let player = StreamingAudioPlayer(makeOutputNode: { node })
        let events = EventBox()
        player.onEvent = { events.append($0) }
        let sessionID = UUID()
        let source = ScriptedAudioSource(steps: [
            .frame(Self.frame(samples: 1_920)),
            .fail(CancellationError()),
        ])

        do {
            try await player.startPlayback(source, sessionID: sessionID)
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(events.values.filter { !$0.isLevel }.isEmpty)
    }

    func testStereoFrameDurationUsesChannelCountNotRawSampleCount() async throws {
        let node = FakeOutputNode(sampleRate: 24_000, channels: 1)
        let player = StreamingAudioPlayer(makeOutputNode: { node })
        player.onEvent = { _ in }
        let sessionID = UUID()
        // 3840 interleaved samples, 2 channels => 1920 frames-per-channel => 80ms, not 160ms.
        let stereo = TTSAudioFrame(
            samples: [Float](repeating: 0.1, count: 3_840),
            format: TTSAudioFormat(sampleRate: 24_000, channelCount: 2)
        )
        let source = ScriptedAudioSource(steps: [.frame(stereo)])

        try await player.startPlayback(source, sessionID: sessionID)

        XCTAssertEqual(node.scheduledDurations.count, 1)
        XCTAssertEqual(node.scheduledDurations[0], 0.08, accuracy: 0.005)
    }

    func testPlayerStopsPullingOnceScheduledAheadWindowIsFull() async throws {
        let node = FakeOutputNode()
        let player = StreamingAudioPlayer(makeOutputNode: { node })
        player.onEvent = { _ in }
        let sessionID = UUID()
        let source = ScriptedAudioSource(repeating: Self.frame(samples: 1_920))

        try await player.startPlayback(source, sessionID: sessionID)

        // The node never reports playback progress, so once ~1.5s is scheduled ahead the pump must
        // stop pulling. Let it settle to a plateau.
        var plateau = await Self.settle(source)
        XCTAssertGreaterThan(plateau, 15, "should schedule roughly a prebuffer + 1.5s of 80ms frames")
        XCTAssertLessThan(plateau, 35, "must not greedily drain an unbounded amount ahead")

        // Reporting playback frees capacity, so the pump resumes pulling.
        node.firePlayed(5)
        try await waitUntilAsync { await source.callCount() > plateau }
        plateau = await source.callCount()

        player.stop()
    }

    func testReplacementSessionIgnoresLatePlayedCallbackFromPriorSession() async throws {
        let nodes = NodeBox()
        let player = StreamingAudioPlayer(makeOutputNode: {
            let node = FakeOutputNode()
            nodes.append(node)
            return node
        })
        let events = EventBox()
        player.onEvent = { events.append($0) }
        let sessionA = UUID()
        let sessionB = UUID()

        let sourceA = ScriptedAudioSource(steps: [
            .frame(Self.frame(samples: 1_920)),
            .frame(Self.frame(samples: 1_920)),
        ])
        try await player.startPlayback(sourceA, sessionID: sessionA)
        XCTAssertTrue(events.values.contains(.started(sessionID: sessionA)))

        // Supersede A with B before A's scheduled audio "plays".
        let sourceB = ScriptedAudioSource(steps: [.frame(Self.frame(samples: 1_920))])
        try await player.startPlayback(sourceB, sessionID: sessionB)
        XCTAssertTrue(events.values.contains(.started(sessionID: sessionB)))

        // Fire A's node's now-stale completion callbacks: they must not finish A or affect B.
        nodes.values[0].firePlayed(nodes.values[0].scheduledCount)
        for _ in 0..<10 { await Task.yield() }

        XCTAssertFalse(events.values.contains(.finished(sessionID: sessionA)))
        XCTAssertFalse(events.values.contains(.failed(sessionID: sessionA)))
        XCTAssertFalse(events.values.contains(.finished(sessionID: sessionB)), "B must not be finished by A's stale callback")

        // B still finishes normally when its own audio plays.
        nodes.values[1].firePlayed(nodes.values[1].scheduledCount)
        try await waitUntilAsync { events.values.contains(.finished(sessionID: sessionB)) }
    }

    // MARK: - Audio-producing: requires a working audio output device

    /// `startPlayback` must return as soon as playback has started - never waiting for it to
    /// finish. `.finished` always arrives later, asynchronously, through `onEvent`, once the rest
    /// of the (short, 3-frame) stream has been drained and played back in the background.
    func testStartPlaybackEmitsStartedAndReturnsBeforeFinishedArrivesLater() async throws {
        try requireAudioOutput()
        let player = StreamingAudioPlayer()
        let events = EventBox()
        player.onEvent = { events.append($0) }
        let sessionID = UUID()

        try await player.startPlayback(Self.makeFrameStream(frameCount: 3), sampleRate: 24_000, sessionID: sessionID)

        // startPlayback has already returned here. This short stream never crosses the prebuffer
        // threshold, so `.started` fires via the stream-end fallback - by the time it returns,
        // only .started has been observed, never .finished.
        XCTAssertEqual(events.values.filter { !$0.isLevel }, [
            .started(sessionID: sessionID),
        ])

        try await waitUntil { events.values.contains(.finished(sessionID: sessionID)) }

        let recorded = events.values.filter { !$0.isLevel }
        XCTAssertEqual(recorded, [
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
            .started(sessionID: sessionID),
        ])

        try await waitUntil { events.values.contains(.finished(sessionID: sessionID)) }

        let recorded = events.values.filter { !$0.isLevel }
        XCTAssertEqual(recorded, [
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

    /// Regression/confirmation for the exactly-one-terminal invariant's OTHER `handlePumpFailure`
    /// branch (the post-start one is `testPostStartFailureEmitsFailedEventInsteadOfThrowingOrFinishing`
    /// above): a source that fails before playback ever starts (never crosses the prebuffer
    /// threshold or reaches stream end) must make `startPlayback` throw directly, with NO
    /// `.failed`/`.started` event ever emitted - there is nothing else left to report a terminal
    /// event through. `engine.start()`
    /// throwing inside `beginScheduledPlayback` (reached from `pump`'s own do/catch once the
    /// source stream ends or crosses the prebuffer threshold) is caught by this exact same
    /// `handlePumpFailure` call, with `started` still `false` at that point - so this test
    /// exercises the identical single completion point an `engine.start()` throw would hit. A
    /// dedicated test that forces `AVAudioEngine.start()` itself to throw isn't included: nothing
    /// short of removing the host's audio output can make a real `AVAudioEngine.start()` fail
    /// deterministically, which is exactly why these tests are gated behind
    /// `RELAY_TEST_REAL_AUDIO_ENGINE` in the first place.
    func testPreStartSourceFailureThrowsWithoutEmittingTerminalEvent() async throws {
        try requireAudioOutput()
        let player = StreamingAudioPlayer()
        let events = EventBox()
        player.onEvent = { events.append($0) }
        let sessionID = UUID()
        struct ImmediateFailure: Error {}

        let stream = AsyncThrowingStream<[Float], Error> { continuation in
            continuation.finish(throwing: ImmediateFailure())
        }

        do {
            try await player.startPlayback(stream, sampleRate: 24_000, sessionID: sessionID)
            XCTFail("Expected the immediate source failure to propagate")
        } catch is ImmediateFailure {
            // Expected.
        }

        let recorded = events.values.filter { !$0.isLevel }
        XCTAssertTrue(recorded.isEmpty)
        XCTAssertFalse(recorded.contains(.failed(sessionID: sessionID)))
        XCTAssertFalse(recorded.contains(.started(sessionID: sessionID)))
    }

    func testStopWithNoActivePlaybackIsANoOp() {
        let player = StreamingAudioPlayer()
        let events = EventBox()
        player.onEvent = { events.append($0) }

        player.stop()

        XCTAssertTrue(events.values.isEmpty)
    }

    /// Skips the calling test unless explicitly opted in via an environment variable. Starting a
    /// real `AVAudioEngine` can hard-crash (not throw) a sandboxed test host with no usable audio
    /// output device.
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

    /// One mono 24kHz `TTSAudioFrame` of `samples` samples.
    private static func frame(samples: Int) -> TTSAudioFrame {
        TTSAudioFrame(
            samples: [Float](repeating: 0.1, count: samples),
            format: TTSAudioFormat(sampleRate: 24_000, channelCount: 1)
        )
    }

    /// Polls `source.callCount()` until it stops growing (the pump has hit the scheduled-ahead
    /// ceiling and suspended), returning the plateau value.
    private static func settle(_ source: ScriptedAudioSource) async -> Int {
        var last = -1
        for _ in 0..<200 {
            await Task.yield()
            let current = await source.callCount()
            if current == last { return current }
            last = current
        }
        return last
    }

    private func waitUntilAsync(
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            await Task.yield()
        }
    }
}

/// A scripted `TTSAudioSource`: yields the given steps in order, then either ends or (if
/// `repeating` is set) yields that frame forever. Counts `next()` calls so demand-bounding tests
/// can observe when the pump stops pulling.
private actor ScriptedAudioSource: TTSAudioSource {
    enum Step {
        case frame(TTSAudioFrame)
        case fail(any Error)
    }

    private var steps: [Step]
    private let loopFrame: TTSAudioFrame?
    private var nextCallCount = 0
    private var cancelled = false

    init(steps: [Step] = [], repeating loopFrame: TTSAudioFrame? = nil) {
        self.steps = steps
        self.loopFrame = loopFrame
    }

    func next() async throws -> TTSAudioFrame? {
        nextCallCount += 1
        if cancelled { return nil }
        if !steps.isEmpty {
            switch steps.removeFirst() {
            case let .frame(frame):
                return frame
            case let .fail(error):
                throw error
            }
        }
        return loopFrame
    }

    func cancel() { cancelled = true }

    func callCount() -> Int { nextCallCount }
    func wasCancelled() -> Bool { cancelled }
}

/// Yields one frame, then suspends until cancelled, so playback stays in its prebuffer window.
private actor FirstFrameThenHangSource: TTSAudioSource {
    private let frame: TTSAudioFrame
    private var delivered = false
    private var waiter: CheckedContinuation<TTSAudioFrame?, Error>?
    private(set) var cancelled = false

    init(frame: TTSAudioFrame) { self.frame = frame }

    func next() async throws -> TTSAudioFrame? {
        if cancelled { throw CancellationError() }
        if !delivered {
            delivered = true
            return frame
        }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func cancel() {
        cancelled = true
        waiter?.resume(throwing: CancellationError())
        waiter = nil
    }
}

/// A fake `AudioOutputNode`: reports a real `AVAudioFormat` (so conversion runs headless) and holds
/// buffer-played callbacks so a test can fire them deterministically, driving the player's
/// demand-bounded scheduling without a real audio device.
@MainActor
private final class FakeOutputNode: AudioOutputNode {
    let outputFormat: AVAudioFormat
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var scheduledDurations: [TimeInterval] = []
    private var playedCallbacks: [@Sendable @MainActor () -> Void] = []
    var onConfigurationChange: (@MainActor () -> Void)?

    func simulateConfigurationChange() {
        onConfigurationChange?()
    }

    init(sampleRate: Double = 24_000, channels: AVAudioChannelCount = 1) {
        outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )!
    }

    /// Total buffers ever scheduled (played + still pending).
    var scheduledCount: Int { scheduledDurations.count }

    func start() throws { startCount += 1 }
    func play() {}
    func stop() { stopCount += 1 }

    func schedule(_ buffer: AVAudioPCMBuffer, onPlayed: @escaping @Sendable @MainActor () -> Void) {
        scheduledDurations.append(Double(buffer.frameLength) / buffer.format.sampleRate)
        playedCallbacks.append(onPlayed)
    }

    /// Fires up to `count` not-yet-played buffer completions, in schedule order.
    func firePlayed(_ count: Int) {
        for _ in 0..<count {
            guard !playedCallbacks.isEmpty else { return }
            let callback = playedCallbacks.removeFirst()
            callback()
        }
    }
}

/// Collects fake nodes created per session so a test can address each session's node.
@MainActor
private final class NodeBox {
    private(set) var values: [FakeOutputNode] = []
    func append(_ node: FakeOutputNode) { values.append(node) }
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

extension StreamingAudioPlayer {
    /// Test convenience mirroring the raw-frame `startPlayback` overload that production carried
    /// during the migration: wrap a `[Float]` frame stream in a `TTSAudioSource` and play it. Kept
    /// only in tests so the player's stream-draining characterization (prebuffer threshold,
    /// supersession, pre-/post-start failure) reads exactly as before the overload was removed.
    func startPlayback(
        _ frames: AsyncThrowingStream<[Float], Error>,
        sampleRate: Double,
        sessionID: UUID
    ) async throws {
        try await startPlayback(FloatStreamTestSource(frames: frames, sampleRate: sampleRate), sessionID: sessionID)
    }
}

/// Feeds a raw `[Float]` frame stream into a pipe, keeping the stream iterator inside the
/// producer task.
private struct FloatStreamTestSource: TTSAudioSource {
    private let piped: PipedTTSAudioSource

    init(frames: AsyncThrowingStream<[Float], Error>, sampleRate: Double) {
        let format = TTSAudioFormat(sampleRate: sampleRate, channelCount: 1)
        piped = PipedTTSAudioSource { sink in
            for try await samples in frames {
                try await sink.yield(TTSAudioFrame(samples: samples, format: format))
            }
        }
    }

    func next() async throws -> TTSAudioFrame? { try await piped.next() }
    func cancel() async { await piped.cancel() }
}
