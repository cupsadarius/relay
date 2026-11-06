import Foundation

@testable import Relay

/// Collects every event a test's bus carries. Call `steps()` once, after the work under test.
final class PipelineEventRecorder: @unchecked Sendable {
    let bus = PipelineEventBus()
    private let stream: AsyncStream<PipelineEvent>

    init() { stream = bus.events() }

    func tracer(_ flow: PipelineFlow) -> PipelineTracer { PipelineTracer(flow: flow, bus: bus) }

    /// Ends the bus and returns `(step, phase)` pairs in emit order.
    func steps() async -> [Pair] {
        bus.finish()
        var pairs: [Pair] = []
        for await event in stream { pairs.append(Pair(step: event.step, phase: event.phase)) }
        return pairs
    }

    struct Pair: Equatable, CustomStringConvertible {
        let step: PipelineStep
        let phase: PipelinePhase
        var description: String { "\(step.rawValue): \(phase)" }
    }
}
