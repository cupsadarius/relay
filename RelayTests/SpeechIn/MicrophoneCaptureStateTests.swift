import XCTest
@testable import Relay

final class MicrophoneCaptureStateTests: XCTestCase {
    func testStartThenStopReturnsMono16KAudioAndReturnsToIdle() async throws {
        let source = FakeAudioSource()
        let capture = MicrophoneCapture(
            permission: FakeMicrophonePermission(granted: true),
            source: source
        )

        try await capture.start()
        await source.emit([0.25, -0.5])
        let audio = try await capture.stop()

        XCTAssertEqual(audio.samples, [0.25, -0.5])
        XCTAssertEqual(audio.sampleRate, 16_000)
        try await capture.start()
    }

    func testStartWhileRecordingThrowsActionableError() async throws {
        let capture = MicrophoneCapture(
            permission: FakeMicrophonePermission(granted: true),
            source: FakeAudioSource()
        )

        try await capture.start()

        await XCTAssertThrowsErrorAsync(try await capture.start()) { error in
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

        try await capture.start()

        await XCTAssertThrowsErrorAsync(try await capture.stop()) { error in
            XCTAssertEqual(error as? SpeechBackendError, .noUsableAudio)
        }
        try await capture.start()
    }

    func testPermissionFailureReturnsToIdle() async {
        let capture = MicrophoneCapture(
            permission: FakeMicrophonePermission(granted: false),
            source: FakeAudioSource()
        )

        await XCTAssertThrowsErrorAsync(try await capture.start()) { error in
            XCTAssertEqual(error as? SpeechBackendError, .permissionDenied)
        }
        await XCTAssertThrowsErrorAsync(try await capture.stop()) { error in
            XCTAssertEqual(error as? MicrophoneCaptureError, .notRecording)
        }
    }

    func testConcurrentStartIsRejectedWhileFirstStartIsAdmitted() async throws {
        let source = FakeAudioSource(blockStart: true)
        let capture = MicrophoneCapture(permission: FakeMicrophonePermission(granted: true), source: source)

        let firstStart = Task { try await capture.start() }
        await source.waitForStart()

        await XCTAssertThrowsErrorAsync(try await capture.start()) { error in
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
        try await capture.start()
        await source.emit([0.1])

        let firstStop = Task { try await capture.stop() }
        await source.waitForStop()

        await XCTAssertThrowsErrorAsync(try await capture.stop()) { error in
            XCTAssertEqual(error as? MicrophoneCaptureError, .notRecording)
        }

        await source.releaseStop()
        let audio = try await firstStop.value
        XCTAssertEqual(audio.samples, [0.1])
        try await capture.start()
    }

    func testSourceStartFailureReturnsToIdle() async {
        let source = FakeAudioSource(startError: MicrophoneCaptureError.unavailable("start failed"))
        let capture = MicrophoneCapture(permission: FakeMicrophonePermission(granted: true), source: source)

        await XCTAssertThrowsErrorAsync(try await capture.start()) { error in
            XCTAssertEqual(error as? MicrophoneCaptureError, .unavailable("start failed"))
        }
        await source.clearStartError()
        do {
            try await capture.start()
        } catch {
            XCTFail("Expected capture to return to idle, got \(error)")
        }
    }

    func testSourceStopFailureReturnsToIdle() async throws {
        let source = FakeAudioSource(stopError: MicrophoneCaptureError.unavailable("stop failed"))
        let capture = MicrophoneCapture(permission: FakeMicrophonePermission(granted: true), source: source)
        try await capture.start()

        await XCTAssertThrowsErrorAsync(try await capture.stop()) { error in
            XCTAssertEqual(error as? MicrophoneCaptureError, .unavailable("stop failed"))
        }
        try await capture.start()
    }

    func testTerminalSourceFailureReturnsCaptureToIdle() async throws {
        let source = FakeAudioSource()
        let capture = MicrophoneCapture(permission: FakeMicrophonePermission(granted: true), source: source)
        try await capture.start()

        await source.failTerminally(MicrophoneCaptureError.unavailable("conversion failed"))

        try await capture.start()
    }

    func testSamplesAcceptedDuringStopAreIncludedBeforeDrainBoundary() async throws {
        let source = FakeAudioSource(samplesDuringStop: [0.2, -0.3])
        let capture = MicrophoneCapture(permission: FakeMicrophonePermission(granted: true), source: source)
        try await capture.start()
        await source.emit([0.1])

        let audio = try await capture.stop()
        XCTAssertEqual(audio.samples, [0.1, 0.2, -0.3])
    }
}

private actor FakeAudioSource: AudioCaptureSourcing {
    private var sink: (@Sendable ([Float]) -> Void)?
    private var terminalErrorSink: (@Sendable (Error) async -> Void)?
    private var startError: Error?
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

    init(
        startError: Error? = nil,
        stopError: Error? = nil,
        blockStart: Bool = false,
        blockStop: Bool = false,
        samplesDuringStop: [Float] = []
    ) {
        self.startError = startError
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
        sink = onSamples
        terminalErrorSink = onTerminalError
        if blockStart {
            hasEnteredStart = true
            startEnteredWaiter?.resume()
            startEnteredWaiter = nil
            await withCheckedContinuation { startWaiter = $0 }
        }
    }

    func stop() async throws {
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

    func failTerminally(_ error: Error) async {
        await terminalErrorSink?(error)
        sink = nil
        terminalErrorSink = nil
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
