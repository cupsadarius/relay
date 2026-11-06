import XCTest

@testable import Relay

@MainActor
final class PipelineRunStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let run = UUID()

    private func event(
        _ step: PipelineStep, _ phase: PipelinePhase, at offset: TimeInterval = 0,
        run: UUID? = nil, flow: PipelineFlow = .dictation
    ) -> PipelineEvent {
        PipelineEvent(runID: run ?? self.run, flow: flow, step: step, phase: phase, at: t0.addingTimeInterval(offset))
    }

    func testFirstEventCreatesTheRunAndStartsTheStep() {
        let store = PipelineRunStore()
        store.apply(event(.transcribe, .started("Transcribing with Parakeet"), at: 1))

        let run = try! XCTUnwrap(store.runs.first)
        XCTAssertEqual(run.flow, .dictation)
        XCTAssertEqual(run.startedAt, t0.addingTimeInterval(1))
        XCTAssertEqual(run.status(of: .transcribe).state, .active)
        XCTAssertEqual(run.status(of: .transcribe).detail, "Transcribing with Parakeet")
        XCTAssertEqual(run.status(of: .insert).state, .pending)
        XCTAssertTrue(run.isLive)
    }

    func testStepLifecycleEndsInFinishedStoppedOrFailed() {
        let store = PipelineRunStore()
        store.apply(event(.transcribe, .started("Transcribing"), at: 0))
        store.apply(event(.transcribe, .updated("Loading model…"), at: 0.2))
        XCTAssertEqual(store.runs[0].status(of: .transcribe).detail, "Loading model…")
        store.apply(event(.transcribe, .finished("Parakeet · 0.4 s"), at: 0.4))
        store.apply(event(.cleanUp, .stopped("No speech"), at: 0.5))
        store.apply(event(.insert, .failed("Paste failed"), at: 0.6))

        let run = store.runs[0]
        XCTAssertEqual(run.status(of: .transcribe).state, .done)
        XCTAssertEqual(run.status(of: .transcribe).endedAt, t0.addingTimeInterval(0.4))
        XCTAssertEqual(run.status(of: .cleanUp).state, .stopped)
        XCTAssertEqual(run.status(of: .insert).state, .failed)
        XCTAssertEqual(run.status(of: .insert).detail, "Paste failed")
        XCTAssertFalse(run.isLive)
        XCTAssertEqual(run.reachedSteps, [.transcribe, .cleanUp, .insert])
    }

    func testLevelUpdatesAreLimitedToTenPerSecond() {
        let store = PipelineRunStore()
        store.apply(event(.recording, .started("Recording"), at: 0))
        store.apply(event(.recording, .level(0.2), at: 0.00))
        store.apply(event(.recording, .level(0.9), at: 0.05))
        XCTAssertEqual(store.runs[0].level, 0.2)
        store.apply(event(.recording, .level(0.5), at: 0.12))
        XCTAssertEqual(store.runs[0].level, 0.5)
    }

    func testHistoryIsCappedPerFlow() {
        let store = PipelineRunStore(capacityPerFlow: 3)
        store.apply(event(.hotkey, .finished("Pressed"), run: UUID(), flow: .dictation))
        for index in 0..<5 {
            store.apply(event(.received, .finished("Claude Code"), at: Double(index), run: UUID(), flow: .agentReply))
        }
        XCTAssertEqual(store.runs.filter { $0.flow == .agentReply }.count, 3)
        XCTAssertEqual(store.runs.filter { $0.flow == .dictation }.count, 1)
        XCTAssertEqual(store.runs.first?.flow, .agentReply, "newest run first")
    }

    func testDisplayedRunFollowsTheLiveRunUnlessTheUserPickedOneRecently() {
        let old = PipelineRun(id: UUID(), flow: .dictation, startedAt: t0)
        var live = PipelineRun(id: UUID(), flow: .agentReply, startedAt: t0.addingTimeInterval(5))
        live.steps[.speak] = PipelineStepStatus(state: .active)
        let runs = [live, old]
        let all = Set(PipelineFlow.allCases)

        XCTAssertEqual(PipelineRunStore.displayedRun(in: runs, visible: all, selected: nil, now: t0)?.id, live.id)
        XCTAssertEqual(
            PipelineRunStore.displayedRun(in: runs, visible: all, selected: (old.id, t0), now: t0.addingTimeInterval(9))?.id,
            old.id
        )
        XCTAssertEqual(
            PipelineRunStore.displayedRun(in: runs, visible: all, selected: (old.id, t0), now: t0.addingTimeInterval(10))?.id,
            live.id
        )
        XCTAssertEqual(
            PipelineRunStore.displayedRun(in: runs, visible: [.dictation], selected: nil, now: t0)?.id,
            old.id,
            "a hidden flow never takes the graph"
        )
    }

    func testAnOldSelectionDoesNotComeBackAfterANewerRunEnds() {
        let picked = PipelineRun(id: UUID(), flow: .dictation, startedAt: t0)
        let newer = PipelineRun(id: UUID(), flow: .dictation, startedAt: t0.addingTimeInterval(15))
        let all = Set(PipelineFlow.allCases)

        XCTAssertEqual(
            PipelineRunStore.displayedRun(in: [newer, picked], visible: all, selected: (picked.id, t0), now: t0.addingTimeInterval(20))?.id,
            newer.id
        )
    }

    func testStopReasonIgnoresAFailureThatALaterStepRecoveredFrom() {
        var run = PipelineRun(id: UUID(), flow: .dictation, startedAt: t0)
        run.steps[.transcribe] = PipelineStepStatus(state: .failed, detail: "Parakeet failed")
        run.steps[.fallback] = PipelineStepStatus(state: .done, detail: "Whisper")
        run.steps[.cleanUp] = PipelineStepStatus(state: .done)
        run.steps[.insert] = PipelineStepStatus(state: .done, detail: "Pasted")
        XCTAssertNil(run.stopReason)

        run.steps[.insert] = PipelineStepStatus(state: .failed, detail: "Could not insert the text")
        XCTAssertEqual(run.stopReason?.step, .insert)
    }

    func testBusDeliversEventsToTheStoreInOrder() async {
        let bus = PipelineEventBus()
        let store = PipelineRunStore()
        let listening = store.listen(to: bus)
        let tracer = PipelineTracer(flow: .readAloud, bus: bus)
        tracer.start(.source, "Reading selection")
        tracer.finish(.source, "412 characters · Accessibility")
        bus.finish()
        await listening.value

        XCTAssertEqual(store.runs.first?.status(of: .source).state, .done)
        XCTAssertEqual(store.runs.first?.status(of: .source).detail, "412 characters · Accessibility")
        XCTAssertEqual(store.rawEvents.count, 2)
    }

    func testEveryFlowGraphStartsWithItsFirstStep() {
        XCTAssertEqual(PipelineGraph.of(.dictation).nodes.first?.step, .hotkey)
        XCTAssertEqual(PipelineGraph.of(.agentReply).nodes.first?.step, .received)
        XCTAssertEqual(PipelineGraph.of(.readAloud).nodes.first?.step, .trigger)
        XCTAssertTrue(PipelineGraph.of(.dictation).nodes.contains { $0.step == .fallback && $0.isBranch })
    }
}
