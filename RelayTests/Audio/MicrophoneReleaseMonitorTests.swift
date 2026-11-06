import XCTest

@testable import Relay

final class MicrophoneReleaseMonitorTests: XCTestCase {
    private struct FakeProbe: ProcessInputProbing {
        let answer: Bool?
        func isRunningInput() -> Bool? { answer }
    }

    private final class Harness: @unchecked Sendable {
        private let lock = NSLock()
        private var scheduled: [@Sendable () -> Void] = []
        private var reported: [MicrophoneStopPath] = []

        var reports: [MicrophoneStopPath] { lock.withLock { reported } }

        func monitor(probe: Bool?) -> MicrophoneReleaseMonitor {
            MicrophoneReleaseMonitor(
                probe: FakeProbe(answer: probe),
                schedule: { _, work in self.lock.withLock { self.scheduled.append(work) } },
                report: { path in self.lock.withLock { self.reported.append(path) } }
            )
        }

        func runScheduled() {
            let work = lock.withLock { () -> [@Sendable () -> Void] in
                defer { scheduled = [] }
                return scheduled
            }
            work.forEach { $0() }
        }
    }

    func testReportsWhenInputStillRunsAfterDelay() {
        let harness = Harness()
        let monitor = harness.monitor(probe: true)
        monitor.captureStarted()
        monitor.captureReleased(.cancel)
        harness.runScheduled()
        XCTAssertEqual(harness.reports, [.cancel])
    }

    func testNoReportWhenInputStopped() {
        let harness = Harness()
        let monitor = harness.monitor(probe: false)
        monitor.captureReleased(.stop)
        harness.runScheduled()
        XCTAssertEqual(harness.reports, [])
    }

    func testNoReportWhenProbeCannotAnswer() {
        let harness = Harness()
        let monitor = harness.monitor(probe: nil)
        monitor.captureReleased(.failure)
        harness.runScheduled()
        XCTAssertEqual(harness.reports, [])
    }

    func testNewCaptureBeforeCheckSuppressesReport() {
        let harness = Harness()
        let monitor = harness.monitor(probe: true)
        monitor.captureReleased(.stop)
        monitor.captureStarted()
        harness.runScheduled()
        XCTAssertEqual(harness.reports, [])
    }

    func testReleaseCheckIsAnnouncedOnTheRunTracer() async {
        let harness = Harness()
        let recorder = PipelineEventRecorder()
        let monitor = harness.monitor(probe: true)
        monitor.captureReleased(.stop, tracer: recorder.tracer(.dictation))
        harness.runScheduled()

        let steps = await recorder.steps()
        XCTAssertEqual(
            steps,
            [
                .init(step: .micReleased, phase: .started("Checking…")),
                .init(step: .micReleased, phase: .failed("Still open after stop")),
            ])
    }

    func testCleanReleaseIsAnnouncedAsFinished() async {
        let harness = Harness()
        let recorder = PipelineEventRecorder()
        let monitor = harness.monitor(probe: false)
        monitor.captureReleased(.cancel, tracer: recorder.tracer(.dictation))
        harness.runScheduled()

        let steps = await recorder.steps()
        XCTAssertEqual(steps.last, .init(step: .micReleased, phase: .finished("Released")))
    }

    func testDiagnosticMessages() {
        XCTAssertEqual(
            DictationDiagnostic.microphoneStillOpen(.failure).message,
            "Microphone still open after dictation stopped (failure)"
        )
        XCTAssertEqual(
            DictationDiagnostic.microphoneFallback(missingName: "AirPods Pro").message,
            "Relay could not use AirPods Pro. Using the system default microphone."
        )
    }
}
