import XCTest

@testable import Relay

final class FirstAudioWatchTests: XCTestCase {
    private final class ManualScheduler: @unchecked Sendable {
        private let lock = NSLock()
        private var work: [@Sendable () -> Void] = []
        func schedule(_ delay: Duration, _ item: @escaping @Sendable () -> Void) { lock.withLock { work.append(item) } }
        func run() { lock.withLock { work }.forEach { $0() } }
    }

    func testFirstAudioFinishesMicOpenOnce() async {
        let recorder = PipelineEventRecorder()
        let scheduler = ManualScheduler()
        let watch = FirstAudioWatch(tracer: recorder.tracer(.dictation), label: "Logitech StreamCam · 48 kHz", schedule: scheduler.schedule)

        watch.audioArrived()
        watch.audioArrived()
        scheduler.run()

        let steps = await recorder.steps()
        XCTAssertEqual(
            steps,
            [
                .init(step: .micOpen, phase: .updated("Waiting for audio from Logitech StreamCam · 48 kHz")),
                .init(step: .micOpen, phase: .finished("Logitech StreamCam · 48 kHz")),
            ])
    }

    func testNoAudioWithinTheDelayFailsMicOpen() async {
        let recorder = PipelineEventRecorder()
        let scheduler = ManualScheduler()
        _ = FirstAudioWatch(tracer: recorder.tracer(.dictation), label: "MacBook Pro Microphone · 48 kHz", schedule: scheduler.schedule)

        scheduler.run()

        let steps = await recorder.steps()
        XCTAssertEqual(steps.last, .init(step: .micOpen, phase: .failed(FirstAudioWatch.noAudioReason)))
    }

    func testCaptureThatEndsBeforeAudioStopsMicOpen() async {
        let recorder = PipelineEventRecorder()
        let scheduler = ManualScheduler()
        let watch = FirstAudioWatch(tracer: recorder.tracer(.dictation), label: "MacBook Pro Microphone", schedule: scheduler.schedule)

        watch.captureEnded()
        scheduler.run()

        let steps = await recorder.steps()
        XCTAssertEqual(steps.last, .init(step: .micOpen, phase: .stopped("Stopped before audio arrived")))
    }
}
