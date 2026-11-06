import CoreAudio
import Foundation

enum MicrophoneStopPath: String, Sendable {
    case stop, cancel, failure
}

protocol ProcessInputProbing: Sendable {
    /// `nil` when CoreAudio cannot answer.
    func isRunningInput() -> Bool?
}

/// Asks CoreAudio whether this process still runs audio input on any device.
struct CoreAudioProcessInputProbe: ProcessInputProbing {
    func isRunningInput() -> Bool? {
        var pid = getpid()
        var process = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process
            ) == noErr, process != kAudioObjectUnknown
        else { return nil }

        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioProcessPropertyIsRunningInput
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &running) == noErr else { return nil }
        return running != 0
    }
}

/// Reports a microphone that stays open after a capture is released. Checks once, after
/// `delay`: the HAL can still report input as running for a few milliseconds after a stop.
final class MicrophoneReleaseMonitor: @unchecked Sendable {
    private let probe: any ProcessInputProbing
    private let delay: Duration
    private let schedule: @Sendable (Duration, @escaping @Sendable () -> Void) -> Void
    private let report: @Sendable (MicrophoneStopPath) -> Void
    private let lock = NSLock()
    /// Bumped by every start and release; a pending check whose generation is stale is skipped.
    private var generation = 0

    init(
        probe: any ProcessInputProbing,
        delay: Duration = .seconds(1),
        schedule: @escaping @Sendable (Duration, @escaping @Sendable () -> Void) -> Void = { delay, work in
            let (seconds, attoseconds) = delay.components
            let interval = Double(seconds) + Double(attoseconds) / 1e18
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + interval, execute: work)
        },
        report: @escaping @Sendable (MicrophoneStopPath) -> Void
    ) {
        self.probe = probe
        self.delay = delay
        self.schedule = schedule
        self.report = report
    }

    func captureStarted() {
        lock.withLock { generation += 1 }
    }

    /// `tracer` gets the mic released step of the run that just ended.
    func captureReleased(_ path: MicrophoneStopPath, tracer: PipelineTracer? = nil) {
        let expected = lock.withLock {
            generation += 1
            return generation
        }
        tracer?.start(.micReleased, "Checking…")
        schedule(delay) { [self] in
            guard lock.withLock({ generation == expected }) else {
                tracer?.finish(.micReleased, "Not checked: next dictation started")
                return
            }
            switch probe.isRunningInput() {
            case true?:
                tracer?.fail(.micReleased, "Still open after \(path.rawValue)")
                report(path)
            case false?:
                tracer?.finish(.micReleased, "Released")
            case nil:
                tracer?.finish(.micReleased, "Released (not verified)")
            }
        }
    }
}
