import Foundation
import Observation

enum PipelineStepState: Equatable, Sendable {
    case pending, active, done, stopped, failed
}

struct PipelineStepStatus: Equatable, Sendable {
    var state: PipelineStepState = .pending
    var detail = ""
    var startedAt: Date?
    var endedAt: Date?
}

struct PipelineRun: Identifiable, Equatable, Sendable {
    let id: UUID
    let flow: PipelineFlow
    let startedAt: Date
    var steps: [PipelineStep: PipelineStepStatus] = [:]
    var level: Float?
    var levelAt: Date?

    func status(of step: PipelineStep) -> PipelineStepStatus { steps[step] ?? PipelineStepStatus() }

    var isLive: Bool { steps.values.contains { $0.state == .active } }

    /// The step that ended the run early, if any. A failure whose fallback branch finished did
    /// not end the run.
    var stopReason: (step: PipelineStep, status: PipelineStepStatus)? {
        let branches = PipelineGraph.of(flow).edges.filter(\.isBranch)
        for step in reachedSteps {
            let status = status(of: step)
            guard status.state == .failed || status.state == .stopped else { continue }
            let recovered = branches.contains { $0.from == step && self.status(of: $0.to).state == .done }
            if !recovered { return (step, status) }
        }
        return nil
    }

    /// The steps this run reached, in graph order.
    var reachedSteps: [PipelineStep] {
        PipelineGraph.of(flow).nodes.map(\.step).filter { status(of: $0).state != .pending }
    }
}

/// Each flow's fixed graph: every step and branch is always drawn in the same place.
struct PipelineGraph: Sendable {
    struct Node: Sendable {
        let step: PipelineStep
        let column: Int
        let row: Int
        let isBranch: Bool
    }

    struct Edge: Sendable {
        let from: PipelineStep
        let to: PipelineStep
        let isBranch: Bool
    }

    let nodes: [Node]
    let edges: [Edge]

    static func of(_ flow: PipelineFlow) -> PipelineGraph {
        switch flow {
        case .dictation:
            chain([.hotkey, .micOpen, .recording, .transcribe, .cleanUp, .insert, .micReleased])
                .adding(branch: .fallback, below: .transcribe, rejoining: .cleanUp)
        case .agentReply:
            chain([.received, .session, .autoRead, .focus, .speak])
        case .readAloud:
            chain([.trigger, .source, .speak])
        }
    }

    private static func chain(_ steps: [PipelineStep]) -> PipelineGraph {
        PipelineGraph(
            nodes: steps.enumerated().map { Node(step: $1, column: $0, row: 0, isBranch: false) },
            edges: zip(steps, steps.dropFirst()).map { Edge(from: $0, to: $1, isBranch: false) }
        )
    }

    private func adding(branch: PipelineStep, below parent: PipelineStep, rejoining next: PipelineStep) -> PipelineGraph {
        let column = nodes.first { $0.step == parent }?.column ?? 0
        return PipelineGraph(
            nodes: nodes + [Node(step: branch, column: column, row: 1, isBranch: true)],
            edges: edges + [Edge(from: parent, to: branch, isBranch: true), Edge(from: branch, to: next, isBranch: true)]
        )
    }
}

/// Listens to the pipeline bus and folds events into runs. Holds no pipeline logic.
@MainActor
@Observable
final class PipelineRunStore {
    /// Newest first, across all flows.
    private(set) var runs: [PipelineRun] = []
    /// The raw event stream, newest last, for the "Raw events" section.
    private(set) var rawEvents: [PipelineEvent] = []

    @ObservationIgnored private let capacityPerFlow: Int
    @ObservationIgnored private let rawCapacity = 300
    private static let levelInterval: TimeInterval = 0.1

    init(capacityPerFlow: Int = 50) {
        self.capacityPerFlow = capacityPerFlow
    }

    /// Subscribes now; the returned task applies events until the bus finishes.
    func listen(to bus: PipelineEventBus) -> Task<Void, Never> {
        let events = bus.events()
        return Task { [weak self] in
            for await event in events {
                self?.apply(event)
            }
        }
    }

    func apply(_ event: PipelineEvent) {
        if case .level = event.phase {
        } else {
            rawEvents.append(event)
            if rawEvents.count > rawCapacity { rawEvents.removeFirst(rawEvents.count - rawCapacity) }
        }

        let index: Int
        if let existing = runs.firstIndex(where: { $0.id == event.runID }) {
            index = existing
        } else {
            runs.insert(PipelineRun(id: event.runID, flow: event.flow, startedAt: event.at), at: 0)
            trim(event.flow)
            index = 0
        }

        var run = runs[index]
        var status = run.status(of: event.step)
        switch event.phase {
        case let .started(detail):
            status = PipelineStepStatus(state: .active, detail: detail, startedAt: event.at)
        case let .updated(detail):
            if status.state == .pending {
                status.state = .active
                status.startedAt = event.at
            }
            status.detail = detail
        case let .level(value):
            if let last = run.levelAt, event.at.timeIntervalSince(last) < Self.levelInterval { return }
            run.level = value
            run.levelAt = event.at
            runs[index] = run
            return
        case let .finished(detail):
            status.state = .done
            if !detail.isEmpty { status.detail = detail }
            status.endedAt = event.at
        case let .stopped(reason):
            status.state = .stopped
            status.detail = reason
            status.endedAt = event.at
        case let .failed(reason):
            status.state = .failed
            status.detail = reason
            status.endedAt = event.at
        }
        if status.startedAt == nil { status.startedAt = event.at }
        run.steps[event.step] = status
        runs[index] = run
    }

    func clear() {
        runs = []
        rawEvents = []
    }

    private func trim(_ flow: PipelineFlow) {
        var kept = 0
        runs.removeAll { run in
            guard run.flow == flow else { return false }
            kept += 1
            return kept > capacityPerFlow
        }
    }

    /// The run the graph shows: the live run, unless the user picked another run less than 10 s
    /// ago. Hidden flows never show.
    static func displayedRun(
        in runs: [PipelineRun],
        visible: Set<PipelineFlow>,
        selected: (id: UUID, at: Date)?,
        now: Date
    ) -> PipelineRun? {
        let visibleRuns = runs.filter { visible.contains($0.flow) }
        let live = visibleRuns.first(where: \.isLive)
        if let selected, let picked = visibleRuns.first(where: { $0.id == selected.id }) {
            let isFresh = now.timeIntervalSince(selected.at) < 10
            let newerRunStarted = visibleRuns.contains { $0.startedAt > selected.at }
            if isFresh || (live == nil && !newerRunStarted) || live?.id == picked.id { return picked }
        }
        return live ?? visibleRuns.first
    }
}
