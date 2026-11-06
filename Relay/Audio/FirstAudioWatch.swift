import Foundation

/// Finishes the mic open step only when the first audio arrives. An engine can start while macOS
/// sends it no audio (a stale microphone grant after a rebuild); the step then fails after
/// `delay` instead of showing a mic that never opened as open.
final class FirstAudioWatch: @unchecked Sendable {
    static let noAudioReason = "No audio from macOS: re-grant the microphone permission"

    private let tracer: PipelineTracer
    private let label: String
    private let lock = NSLock()
    private var settled = false

    init(
        tracer: PipelineTracer,
        label: String,
        delay: Duration = .seconds(1),
        schedule: (Duration, @escaping @Sendable () -> Void) -> Void = { delay, work in
            let (seconds, attoseconds) = delay.components
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + Double(seconds) + Double(attoseconds) / 1e18, execute: work)
        }
    ) {
        self.tracer = tracer
        self.label = label
        tracer.update(.micOpen, "Waiting for audio from \(label)")
        schedule(delay) { [self] in
            if settle() { tracer.fail(.micOpen, Self.noAudioReason) }
        }
    }

    /// Tap thread. Cheap after the first call.
    func audioArrived() {
        if settle() { tracer.finish(.micOpen, label) }
    }

    /// The capture ended before any audio arrived (a short tap).
    func captureEnded() {
        if settle() { tracer.stop(.micOpen, "Stopped before audio arrived") }
    }

    /// The capture failed to start; its own failure is already announced.
    func abandon() {
        _ = settle()
    }

    /// `true` for the first caller only.
    private func settle() -> Bool {
        lock.withLock {
            defer { settled = true }
            return !settled
        }
    }
}
