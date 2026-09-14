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
}

private actor FakeAudioSource: AudioCaptureSourcing {
    private var sink: (@Sendable ([Float]) -> Void)?

    func start(onSamples: @escaping @Sendable ([Float]) -> Void) async throws {
        sink = onSamples
    }

    func stop() async throws {
        sink = nil
    }

    func emit(_ samples: [Float]) {
        sink?(samples)
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
