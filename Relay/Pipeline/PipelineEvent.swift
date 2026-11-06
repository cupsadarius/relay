import Foundation

/// The user-visible flows Diagnostics can follow.
enum PipelineFlow: String, CaseIterable, Sendable, Identifiable {
    case dictation, agentReply, readAloud

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: "Dictation"
        case .agentReply: "Agent replies"
        case .readAloud: "Read aloud"
        }
    }
}

/// One step of a flow. Each step is announced by the module that owns it.
enum PipelineStep: String, CaseIterable, Sendable {
    // Dictation
    case hotkey, micOpen, recording, transcribe, fallback, cleanUp, insert, micReleased
    // Agent reply
    case received, session, autoRead, focus
    // Read aloud
    case trigger, source
    // Agent reply and read aloud
    case speak

    var title: String {
        switch self {
        case .hotkey: "Hotkey"
        case .micOpen: "Mic open"
        case .recording: "Recording"
        case .transcribe: "Transcribe"
        case .fallback: "Fallback"
        case .cleanUp: "Clean up"
        case .insert: "Insert"
        case .micReleased: "Mic released"
        case .received: "Received"
        case .session: "Session"
        case .autoRead: "Auto-read"
        case .focus: "Focus"
        case .trigger: "Trigger"
        case .source: "Text"
        case .speak: "Speak"
        }
    }
}

/// A step's lifecycle. Details and reasons are short labels: never transcript or reply text.
enum PipelinePhase: Equatable, Sendable {
    case started(String)
    case updated(String)
    case level(Float)
    case finished(String)
    case stopped(String)
    case failed(String)
}

struct PipelineEvent: Equatable, Sendable {
    let runID: UUID
    let flow: PipelineFlow
    let step: PipelineStep
    let phase: PipelinePhase
    let at: Date
}

/// Fans events out to every subscriber. `emit` never blocks on a subscriber, so audio, socket and
/// actor code can announce from any thread.
final class PipelineEventBus: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [UUID: AsyncStream<PipelineEvent>.Continuation] = [:]

    func emit(_ event: PipelineEvent) {
        let current = lock.withLock { Array(subscribers.values) }
        for subscriber in current { subscriber.yield(event) }
    }

    /// Subscribed when this returns, so no event emitted afterwards is missed.
    func events() -> AsyncStream<PipelineEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: PipelineEvent.self, bufferingPolicy: .bufferingNewest(1_000))
        let id = UUID()
        lock.withLock { subscribers[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.lock.withLock { _ = self?.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    /// Ends every subscription.
    func finish() {
        let current = lock.withLock {
            defer { subscribers = [:] }
            return Array(subscribers.values)
        }
        for subscriber in current { subscriber.finish() }
    }
}

/// One run's announcer. The run's owner creates it and hands it to the modules it calls, so each
/// module announces its own steps into the same run.
struct PipelineTracer: Sendable, Equatable {
    let runID: UUID
    let flow: PipelineFlow
    private let bus: PipelineEventBus

    init(flow: PipelineFlow, bus: PipelineEventBus, runID: UUID = UUID()) {
        self.runID = runID
        self.flow = flow
        self.bus = bus
    }

    static func == (lhs: PipelineTracer, rhs: PipelineTracer) -> Bool {
        lhs.runID == rhs.runID && lhs.flow == rhs.flow
    }

    func start(_ step: PipelineStep, _ detail: String) { emit(step, .started(detail)) }
    func update(_ step: PipelineStep, _ detail: String) { emit(step, .updated(detail)) }
    func level(_ step: PipelineStep, _ value: Float) { emit(step, .level(value)) }
    func finish(_ step: PipelineStep, _ detail: String) { emit(step, .finished(detail)) }
    func stop(_ step: PipelineStep, _ reason: String) { emit(step, .stopped(reason)) }
    func fail(_ step: PipelineStep, _ reason: String) { emit(step, .failed(reason)) }

    private func emit(_ step: PipelineStep, _ phase: PipelinePhase) {
        bus.emit(PipelineEvent(runID: runID, flow: flow, step: step, phase: phase, at: Date()))
    }
}
