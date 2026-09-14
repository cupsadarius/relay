import XCTest
import AVFoundation
@testable import Relay

final class MicrophoneCaptureStateTests: XCTestCase {
    func testConversionDispositionAppendsFramesForHaveDataAndInputRanDry() {
        XCTAssertEqual(AudioConversionDisposition.resolve(status: .haveData, hasConversionError: false, frameLength: 12), .appendOutput)
        XCTAssertEqual(AudioConversionDisposition.resolve(status: .inputRanDry, hasConversionError: false, frameLength: 12), .appendOutput)
    }

    func testConversionDispositionWaitsForNextLiveCallbackWhenNoFramesWereProduced() {
        XCTAssertEqual(AudioConversionDisposition.resolve(status: .haveData, hasConversionError: false, frameLength: 0), .awaitNextCallback)
        XCTAssertEqual(AudioConversionDisposition.resolve(status: .inputRanDry, hasConversionError: false, frameLength: 0), .awaitNextCallback)
    }

    func testConversionDispositionFailsForConversionErrorsAndTerminalStatuses() {
        XCTAssertEqual(AudioConversionDisposition.resolve(status: .haveData, hasConversionError: true, frameLength: 12), .fail)
        XCTAssertEqual(AudioConversionDisposition.resolve(status: .error, hasConversionError: false, frameLength: 0), .fail)
        XCTAssertEqual(AudioConversionDisposition.resolve(status: .endOfStream, hasConversionError: false, frameLength: 0), .fail)
    }
    func testLevelMeterNormalizesRMSWithoutExposingSamples() {
        XCTAssertEqual(MicrophoneLevelMeter.normalized(samples: [0, 0]), 0)
        XCTAssertEqual(MicrophoneLevelMeter.normalized(samples: [1, -1]), 1)
    }

    func testStartEmitsNormalizedLevelForEachAcceptedSampleBatch() async throws {
        let source = FakeAudioSource()
        let capture = MicrophoneCapture(permission: FakeMicrophonePermission(granted: true), source: source)
        let recorder = LevelRecorder()

        try await capture.start(onLevel: { recorder.record($0) })
        await source.emit([1, -1])
        await source.emit([0, 0])

        XCTAssertEqual(recorder.levels, [1, 0])
    }

    func testCancelWhileRecordingStopsSourceResetsAccumulatorAndReturnsToIdleWithoutThrowing() async throws {
        let source = FakeAudioSource()
        let capture = MicrophoneCapture(permission: FakeMicrophonePermission(granted: true), source: source)
        try await capture.start(onLevel: { _ in })
        await source.emit([0.4])

        await capture.cancel()

        await XCTAssertThrowsErrorAsync(try await capture.stop()) { error in
            XCTAssertEqual(error as? MicrophoneCaptureError, .notRecording)
        }
        try await capture.start(onLevel: { _ in })
    }

    func testCancelWhileIdleIsANoOp() async {
        let capture = MicrophoneCapture(permission: FakeMicrophonePermission(granted: true), source: FakeAudioSource())

        await capture.cancel()

        try? await capture.start(onLevel: { _ in })
    }

    func testCancelWhileStartingWaitsForSourceStartThenStopsExactlyOnceAndReturnsToIdle() async throws {
        let source = FakeAudioSource(blockStart: true)
        let capture = MicrophoneCapture(permission: FakeMicrophonePermission(granted: true), source: source)

        let startTask = Task { try await capture.start(onLevel: { _ in }) }
        await source.waitForStart()

        let cancelCompleted = FlagBox()
        let cancelTask = Task {
            await capture.cancel()
            cancelCompleted.set()
        }
        await Task.yield()
        XCTAssertFalse(cancelCompleted.value, "cancel() must not resolve while source.start() is still in flight")

        await source.releaseStart()
        _ = try? await startTask.value
        await cancelTask.value

        XCTAssertTrue(cancelCompleted.value)
        let stopCount = await source.stopInvocationCount
        XCTAssertEqual(stopCount, 1)
        // The actor must be idle: a fresh start succeeds.
        try await capture.start(onLevel: { _ in })
    }

    func testCancelWhileStoppingWaitsForInFlightStopWithoutStoppingTheSourceTwice() async throws {
        let source = FakeAudioSource(blockStop: true)
        let capture = MicrophoneCapture(permission: FakeMicrophonePermission(granted: true), source: source)
        try await capture.start(onLevel: { _ in })
        await source.emit([0.2])

        let stopTask = Task { try await capture.stop() }
        await source.waitForStop()

        let cancelCompleted = FlagBox()
        let cancelTask = Task {
            await capture.cancel()
            cancelCompleted.set()
        }
        await Task.yield()
        XCTAssertFalse(cancelCompleted.value, "cancel() must not resolve while the in-flight stop() hasn't reached idle")

        await source.releaseStop()
        _ = try await stopTask.value
        await cancelTask.value

        XCTAssertTrue(cancelCompleted.value)
        let stopCount = await source.stopInvocationCount
        XCTAssertEqual(stopCount, 1)
        try await capture.start(onLevel: { _ in })
    }

    func testCancelFromFailedStartingDiscardsPendingErrorAndReturnsToIdle() async throws {
        let source = FakeAudioSource(
            terminalErrorDuringStart: MicrophoneCaptureError.unavailable("boom"),
            blockStart: true
        )
        let capture = MicrophoneCapture(permission: FakeMicrophonePermission(granted: true), source: source)

        let startTask = Task { try await capture.start(onLevel: { _ in }) }
        await source.waitForStart()
        // The terminal error already landed (moving the actor to `.failedStarting`) before the
        // fake's `start()` call parked on its own continuation.

        await capture.cancel()

        await source.releaseStart()
        _ = try? await startTask.value

        // No stale error should surface: a fresh start immediately after `cancel()` succeeds.
        try await capture.start(onLevel: { _ in })
    }

    func testCancelFromFailedRecordingDiscardsPendingErrorAndReturnsToIdle() async throws {
        let source = FakeAudioSource()
        let capture = MicrophoneCapture(permission: FakeMicrophonePermission(granted: true), source: source)
        try await capture.start(onLevel: { _ in })
        await source.failTerminally(MicrophoneCaptureError.unavailable("late failure"))

        await capture.cancel()

        try await capture.start(onLevel: { _ in })
    }

    func testStartThenStopReturnsMono16KAudioAndReturnsToIdle() async throws {
        let source = FakeAudioSource()
        let capture = MicrophoneCapture(
            permission: FakeMicrophonePermission(granted: true),
            source: source
        )

        try await capture.start(onLevel: { _ in })
        await source.emit([0.25, -0.5])
        let audio = try await capture.stop()

        XCTAssertEqual(audio.samples, [0.25, -0.5])
        XCTAssertEqual(audio.sampleRate, 16_000)
        try await capture.start(onLevel: { _ in })
    }

    func testStartWhileRecordingThrowsActionableError() async throws {
        let capture = MicrophoneCapture(
            permission: FakeMicrophonePermission(granted: true),
            source: FakeAudioSource()
        )

        try await capture.start(onLevel: { _ in })

        await XCTAssertThrowsErrorAsync(try await capture.start(onLevel: { _ in })) { error in
            XCTAssertEqual(error as? MicrophoneCaptureError, .alreadyRecording)
        }
    }

    func testStopWhileIdleThrowsActionableError() async {
        let capture = MicrophoneCapture(
            permission: FakeMicrophonePermission(granted: true),
            source: FakeAudioSource()
        )

        await XCTAssertThrowsErrorAsync(try await capture.stop()) { error in
            XCTAssertEqual(error as? MicrophoneCaptureError, .notRecording)
        }
    }

    func testStopWithNoSamplesThrowsNoUsableAudioAndReturnsToIdle() async throws {
        let capture = MicrophoneCapture(
            permission: FakeMicrophonePermission(granted: true),
            source: FakeAudioSource()
        )

        try await capture.start(onLevel: { _ in })

        await XCTAssertThrowsErrorAsync(try await capture.stop()) { error in
            XCTAssertEqual(error as? SpeechBackendError, .noUsableAudio)
        }
        try await capture.start(onLevel: { _ in })
    }

    func testPermissionFailureReturnsToIdle() async {
        let capture = MicrophoneCapture(
            permission: FakeMicrophonePermission(granted: false),
            source: FakeAudioSource()
        )

        await XCTAssertThrowsErrorAsync(try await capture.start(onLevel: { _ in })) { error in
            XCTAssertEqual(error as? SpeechBackendError, .permissionDenied)
        }
        await XCTAssertThrowsErrorAsync(try await capture.stop()) { error in
            XCTAssertEqual(error as? MicrophoneCaptureError, .notRecording)
        }
    }

    func testConcurrentStartIsRejectedWhileFirstStartIsAdmitted() async throws {
        let source = FakeAudioSource(blockStart: true)
        let capture = MicrophoneCapture(permission: FakeMicrophonePermission(granted: true), source: source)

        let firstStart = Task { try await capture.start(onLevel: { _ in }) }
        await source.waitForStart()

        await XCTAssertThrowsErrorAsync(try await capture.start(onLevel: { _ in })) { error in
            XCTAssertEqual(error as? MicrophoneCaptureError, .alreadyRecording)
        }

        await source.releaseStart()
        try await firstStart.value
        await source.emit([0.1])
        _ = try await capture.stop()
    }

    func testConcurrentStopIsRejectedWhileFirstStopIsAdmitted() async throws {
        let source = FakeAudioSource(blockStop: true)
        let capture = MicrophoneCapture(permission: FakeMicrophonePermission(granted: true), source: source)
        try await capture.start(onLevel: { _ in })
        await source.emit([0.1])

        let firstStop = Task { try await capture.stop() }
        await source.waitForStop()

        await XCTAssertThrowsErrorAsync(try await capture.stop()) { error in
            XCTAssertEqual(error as? MicrophoneCaptureError, .notRecording)
        }

        await source.releaseStop()
        let audio = try await firstStop.value
        XCTAssertEqual(audio.samples, [0.1])
        try await capture.start(onLevel: { _ in })
    }

    func testSourceStartFailureReturnsToIdle() async {
        let source = FakeAudioSource(startError: MicrophoneCaptureError.unavailable("start failed"))
        let capture = MicrophoneCapture(permission: FakeMicrophonePermission(granted: true), source: source)

        await XCTAssertThrowsErrorAsync(try await capture.start(onLevel: { _ in })) { error in
            XCTAssertEqual(error as? MicrophoneCaptureError, .unavailable("start failed"))
        }
        await source.clearStartError()
        do {
            try await capture.start(onLevel: { _ in })
        } catch {
            XCTFail("Expected capture to return to idle, got \(error)")
        }
    }

    func testSourceStopFailureReturnsToIdle() async throws {
        let source = FakeAudioSource(stopError: MicrophoneCaptureError.unavailable("stop failed"))
        let capture = MicrophoneCapture(permission: FakeMicrophonePermission(granted: true), source: source)
        try await capture.start(onLevel: { _ in })

        await XCTAssertThrowsErrorAsync(try await capture.stop()) { error in
            XCTAssertEqual(error as? MicrophoneCaptureError, .unavailable("stop failed"))
        }
        try await capture.start(onLevel: { _ in })
    }

    func testTerminalSourceFailureIsReturnedByNextStopThenCaptureReturnsToIdle() async throws {
        let source = FakeAudioSource()
        let capture = MicrophoneCapture(permission: FakeMicrophonePermission(granted: true), source: source)
        try await capture.start(onLevel: { _ in })

        await source.failTerminally(MicrophoneCaptureError.unavailable("conversion failed"))

        await XCTAssertThrowsErrorAsync(try await capture.stop()) { error in
            XCTAssertEqual(error as? MicrophoneCaptureError, .unavailable("conversion failed"))
        }
        try await capture.start(onLevel: { _ in })
    }

    func testTerminalFailureDuringStartRejectsCompetingStartUntilOriginalStartThrows() async throws {
        let source = FakeAudioSource(
            terminalErrorDuringStart: MicrophoneCaptureError.unavailable("conversion failed"),
            blockStart: true
        )
        let capture = MicrophoneCapture(permission: FakeMicrophonePermission(granted: true), source: source)

        let firstStart = Task { try await capture.start(onLevel: { _ in }) }
        await source.waitForStart()

        await XCTAssertThrowsErrorAsync(try await capture.start(onLevel: { _ in })) { error in
            XCTAssertEqual(error as? MicrophoneCaptureError, .alreadyRecording)
        }

        await source.releaseStart()
        await XCTAssertThrowsErrorAsync(try await firstStart.value) { error in
            XCTAssertEqual(error as? MicrophoneCaptureError, .unavailable("conversion failed"))
        }

        await source.clearTerminalErrorDuringStart()
        try await capture.start(onLevel: { _ in })
    }

    func testSamplesAcceptedDuringStopAreIncludedBeforeDrainBoundary() async throws {
        let source = FakeAudioSource(samplesDuringStop: [0.2, -0.3])
        let capture = MicrophoneCapture(permission: FakeMicrophonePermission(granted: true), source: source)
        try await capture.start(onLevel: { _ in })
        await source.emit([0.1])

        let audio = try await capture.stop()
        XCTAssertEqual(audio.samples, [0.1, 0.2, -0.3])
    }

    func testTerminalCallbackWhileStoppingDoesNotReplaceStopResult() async throws {
        let source = FakeAudioSource(blockStop: true)
        let capture = MicrophoneCapture(permission: FakeMicrophonePermission(granted: true), source: source)
        try await capture.start(onLevel: { _ in })
        await source.emit([0.1])

        let stop = Task { try await capture.stop() }
        await source.waitForStop()
        await source.failTerminally(MicrophoneCaptureError.unavailable("late failure"))
        await source.releaseStop()

        let audio = try await stop.value
        XCTAssertEqual(audio.samples, [0.1])
        try await capture.start(onLevel: { _ in })
    }
}

private actor FakeAudioSource: AudioCaptureSourcing {
    private var sink: (@Sendable ([Float]) -> Void)?
    private var terminalErrorSink: (@Sendable (Error) async -> Void)?
    private var startError: Error?
    private var terminalErrorDuringStart: Error?
    private var stopError: Error?
    private let blockStart: Bool
    private let blockStop: Bool
    private let samplesDuringStop: [Float]
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var stopWaiter: CheckedContinuation<Void, Never>?
    private var startEnteredWaiter: CheckedContinuation<Void, Never>?
    private var stopEnteredWaiter: CheckedContinuation<Void, Never>?
    private var hasEnteredStart = false
    private var hasEnteredStop = false
    private var startInvocationCount = 0
    private(set) var stopInvocationCount = 0

    init(
        startError: Error? = nil,
        terminalErrorDuringStart: Error? = nil,
        stopError: Error? = nil,
        blockStart: Bool = false,
        blockStop: Bool = false,
        samplesDuringStop: [Float] = []
    ) {
        self.startError = startError
        self.terminalErrorDuringStart = terminalErrorDuringStart
        self.stopError = stopError
        self.blockStart = blockStart
        self.blockStop = blockStop
        self.samplesDuringStop = samplesDuringStop
    }

    func start(
        onSamples: @escaping @Sendable ([Float]) -> Void,
        onTerminalError: @escaping @Sendable (Error) async -> Void
    ) async throws {
        if let startError { throw startError }
        startInvocationCount += 1
        sink = onSamples
        terminalErrorSink = onTerminalError
        if let terminalErrorDuringStart, startInvocationCount == 1 {
            await onTerminalError(terminalErrorDuringStart)
            sink = nil
            terminalErrorSink = nil
        }
        if blockStart, startInvocationCount == 1 {
            hasEnteredStart = true
            startEnteredWaiter?.resume()
            startEnteredWaiter = nil
            await withCheckedContinuation { startWaiter = $0 }
        }
    }

    func stop() async throws {
        stopInvocationCount += 1
        if blockStop {
            hasEnteredStop = true
            stopEnteredWaiter?.resume()
            stopEnteredWaiter = nil
            await withCheckedContinuation { stopWaiter = $0 }
        }
        sink?(samplesDuringStop)
        if let stopError { throw stopError }
        sink = nil
    }

    func emit(_ samples: [Float]) {
        sink?(samples)
    }

    func waitForStart() async {
        guard !hasEnteredStart else { return }
        await withCheckedContinuation { startEnteredWaiter = $0 }
    }

    func releaseStart() { startWaiter?.resume(); startWaiter = nil }

    func waitForStop() async {
        guard !hasEnteredStop else { return }
        await withCheckedContinuation { stopEnteredWaiter = $0 }
    }

    func releaseStop() { stopWaiter?.resume(); stopWaiter = nil }

    func clearStartError() { startError = nil }

    func clearTerminalErrorDuringStart() { terminalErrorDuringStart = nil }

    func failTerminally(_ error: Error) async {
        await terminalErrorSink?(error)
        sink = nil
        terminalErrorSink = nil
    }
}

private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func set() {
        lock.withLock { flag = true }
    }

    var value: Bool {
        lock.withLock { flag }
    }
}

private final class LevelRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Float] = []

    func record(_ level: Float) {
        lock.withLock { values.append(level) }
    }

    var levels: [Float] {
        lock.withLock { values }
    }
}

private struct FakeMicrophonePermission: MicrophonePermissionAuthorizing {
    let granted: Bool

    func requestPermission() async -> Bool {
        granted
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error")
    } catch {
        errorHandler(error)
    }
}
