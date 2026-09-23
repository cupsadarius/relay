import Foundation
import XCTest

@testable import Relay

/// One recorded lifecycle event from a `FakeLoadedWhisperContext`, in the order it happened,
/// so tests can assert ordering (e.g. "unload of A happened before load of B") rather than just
/// counting calls.
enum FakeWhisperEvent: Equatable {
    case loaded(WhisperModelID)
    case unloaded(WhisperModelID)
    case transcribed(WhisperModelID)
}

/// Shared event log every fake context created by `FakeWhisperEngine` appends to, so ordering
/// across multiple loaded contexts (e.g. across a model switch) is observable from one place.
final class FakeWhisperEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [FakeWhisperEvent] = []

    func append(_ event: FakeWhisperEvent) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }

    var all: [FakeWhisperEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

/// Fake `LoadedWhisperContext` bound to one `WhisperModelID`, recording unload/transcribe calls
/// (and their order relative to other fakes) into a shared `FakeWhisperEventLog`.
final class FakeLoadedWhisperContext: LoadedWhisperContext, @unchecked Sendable {
    let id: WhisperModelID
    let log: FakeWhisperEventLog
    var textToReturn = "fake transcript"

    init(id: WhisperModelID, log: FakeWhisperEventLog) {
        self.id = id
        self.log = log
    }

    func transcribe(_ samples: [Float], options: STTOptions) async throws -> String {
        log.append(.transcribed(id))
        return textToReturn
    }

    func unload() async {
        log.append(.unloaded(id))
    }
}

/// Fake `WhisperEngine` that records every `load` call's requested model folder and hands back
/// a `FakeLoadedWhisperContext`, or throws `errorToThrow` if set (simulating a failed load).
final class FakeWhisperEngine: WhisperEngine, @unchecked Sendable {
    let log: FakeWhisperEventLog
    private(set) var loadedFolders: [URL] = []
    var errorToThrow: Error?

    init(log: FakeWhisperEventLog) {
        self.log = log
    }

    func load(modelFolder: URL) async throws -> any LoadedWhisperContext {
        if let errorToThrow {
            throw errorToThrow
        }
        loadedFolders.append(modelFolder)
        let id = WhisperRuntimeTests.modelID(forFolder: modelFolder)
        log.append(.loaded(id))
        return FakeLoadedWhisperContext(id: id, log: log)
    }
}

enum FakeWhisperEngineError: Error, Equatable {
    case simulatedLoadFailure
}

final class WhisperRuntimeTests: XCTestCase {
    private var log: FakeWhisperEventLog!
    private var engine: FakeWhisperEngine!
    private var runtime: WhisperRuntime!

    override func setUp() {
        super.setUp()
        log = FakeWhisperEventLog()
        engine = FakeWhisperEngine(log: log)
        runtime = WhisperRuntime(engine: engine, modelFolder: Self.folder(for:))
    }

    override func tearDown() {
        runtime = nil
        engine = nil
        log = nil
        super.tearDown()
    }

    /// Maps a `WhisperModelID` to a deterministic, distinguishable fake folder URL -- the two
    /// fakes above use this bijection (and its inverse, `modelID(forFolder:)`) to recover which
    /// model a folder or a load call refers to without touching real disk paths.
    private static func folder(for id: WhisperModelID) -> URL {
        URL(fileURLWithPath: "/fake/whisper-models/\(id.rawValue)", isDirectory: true)
    }

    fileprivate static func modelID(forFolder folder: URL) -> WhisperModelID {
        let name = folder.lastPathComponent
        guard let id = WhisperModelID(rawValue: name) else {
            fatalError("unrecognized fake model folder: \(folder)")
        }
        return id
    }

    func testActivateLoadsSelectedModel() async throws {
        try await runtime.activate(.baseEn)

        XCTAssertEqual(engine.loadedFolders, [Self.folder(for: .baseEn)])

        let text = try await runtime.transcribe([0.1, 0.2], options: STTOptions())
        XCTAssertEqual(text, "fake transcript")
        XCTAssertEqual(log.all, [.loaded(.baseEn), .transcribed(.baseEn)])
    }

    func testSwitchUnloadsPreviousBeforeLoadingNext() async throws {
        try await runtime.activate(.baseEn)
        try await runtime.activate(.smallEn)

        XCTAssertEqual(log.all, [.loaded(.baseEn), .unloaded(.baseEn), .loaded(.smallEn)])
    }

    func testReactivatingSameModelIsNoOp() async throws {
        try await runtime.activate(.baseEn)
        try await runtime.activate(.baseEn)

        let loadCount = log.all.filter {
            if case .loaded(.baseEn) = $0 { return true }; return false
        }.count
        let unloadCount = log.all.filter {
            if case .unloaded = $0 { return true }; return false
        }.count
        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(unloadCount, 0)
    }

    func testFailedActivateLeavesNoLoadedContext() async throws {
        engine.errorToThrow = FakeWhisperEngineError.simulatedLoadFailure

        do {
            try await runtime.activate(.baseEn)
            XCTFail("expected activate to throw")
        } catch {
            XCTAssertEqual(error as? FakeWhisperEngineError, .simulatedLoadFailure)
        }

        do {
            _ = try await runtime.transcribe([0.1], options: STTOptions())
            XCTFail("expected transcribe to throw notLoaded")
        } catch {
            XCTAssertEqual(error as? WhisperRuntimeError, .notLoaded)
        }

        engine.errorToThrow = nil
        try await runtime.activate(.baseEn)
        let text = try await runtime.transcribe([0.1], options: STTOptions())
        XCTAssertEqual(text, "fake transcript")
    }

    func testTranscribeDelegatesToLoadedContext() async throws {
        try await runtime.activate(.tiny)

        let text = try await runtime.transcribe([0.5, 0.6, 0.7], options: STTOptions())

        XCTAssertEqual(text, "fake transcript")
    }

    func testTranscribeWithoutActiveModelThrows() async throws {
        do {
            _ = try await runtime.transcribe([0.1], options: STTOptions())
            XCTFail("expected notLoaded error")
        } catch {
            XCTAssertEqual(error as? WhisperRuntimeError, .notLoaded)
        }
    }

    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    /// Polls (bounded) until `engine.loadCount` reaches `target`, instead of a fixed number of
    /// yields -- `load(modelFolder:)` increments `loadCount` before awaiting its gate, so this
    /// deterministically waits for "the gated load has been entered" rather than hoping a fixed
    /// `settle()` was long enough on a slower machine or under load.
    private func waitForLoadCount(_ target: Int, on engine: GatedWhisperEngine, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while await engine.loadCount < target, Date() < deadline {
            await Task.yield()
        }
    }

    func testConcurrentActivateOfTheSameModelLoadsOnce() async throws {
        let gate = WhisperTestGate()
        let gatedEngine = GatedWhisperEngine(log: log, loadGate: gate)
        let runtime = WhisperRuntime(engine: gatedEngine, modelFolder: Self.folder(for:))

        let interimTick = Task { try await runtime.activate(.baseEn) }
        let finalTranscribe = Task { try await runtime.activate(.baseEn) }
        await settle()
        let loadsWhileGated = await gatedEngine.loadCount

        await gate.open()
        try await interimTick.value
        try await finalTranscribe.value

        XCTAssertEqual(loadsWhileGated, 1, "the second caller must join the in-flight load")
        let totalLoads = await gatedEngine.loadCount
        XCTAssertEqual(totalLoads, 1)
        let current = await runtime.currentModelID
        XCTAssertEqual(current, .baseEn)
    }

    func testActivatingAnotherModelWaitsForAnInUseTranscriptionBeforeUnloading() async throws {
        let transcribeGate = WhisperTestGate()
        let gatedEngine = GatedWhisperEngine(log: log, transcribeGateByID: [.baseEn: transcribeGate])
        let runtime = WhisperRuntime(engine: gatedEngine, modelFolder: Self.folder(for:))
        try await runtime.activate(.baseEn)
        let contextOpt = await gatedEngine.lastContext
        let context = try XCTUnwrap(contextOpt)

        let transcription = Task { try await runtime.transcribe([0.1], options: STTOptions()) }
        while await !context.transcribeStarted { await Task.yield() }
        let switchTask = Task { try await runtime.activate(.smallEn) }
        await settle()

        XCTAssertEqual(log.all, [.loaded(.baseEn)], "the in-use context must not be unloaded mid-transcription")

        await transcribeGate.open()
        let text = try await transcription.value
        try await switchTask.value

        XCTAssertEqual(text, "gated transcript")
        XCTAssertEqual(log.all, [.loaded(.baseEn), .transcribed(.baseEn), .unloaded(.baseEn), .loaded(.smallEn)])
    }

    func testUnloadWaitsForAnInUseTranscription() async throws {
        let transcribeGate = WhisperTestGate()
        let gatedEngine = GatedWhisperEngine(log: log, transcribeGateByID: [.baseEn: transcribeGate])
        let runtime = WhisperRuntime(engine: gatedEngine, modelFolder: Self.folder(for:))
        try await runtime.activate(.baseEn)
        let contextOpt = await gatedEngine.lastContext
        let context = try XCTUnwrap(contextOpt)

        let transcription = Task { try await runtime.transcribe([0.1], options: STTOptions()) }
        while await !context.transcribeStarted { await Task.yield() }
        let unload = Task { await runtime.unload() }
        await settle()
        XCTAssertFalse(log.all.contains(.unloaded(.baseEn)))

        await transcribeGate.open()
        _ = try await transcription.value
        await unload.value
        XCTAssertEqual(log.all.last, .unloaded(.baseEn))
        let current = await runtime.currentModelID
        XCTAssertNil(current)
    }

    func testConcurrentActivateThatFailsLeavesNothingLoadedForEitherCaller() async {
        let gate = WhisperTestGate()
        let gatedEngine = GatedWhisperEngine(log: log, loadGate: gate, error: FakeWhisperEngineError.simulatedLoadFailure)
        let runtime = WhisperRuntime(engine: gatedEngine, modelFolder: Self.folder(for:))

        let first = Task { try await runtime.activate(.baseEn) }
        let second = Task { try await runtime.activate(.baseEn) }
        await waitForLoadCount(1, on: gatedEngine)
        await settle()
        await gate.open()

        for task in [first, second] {
            do {
                try await task.value
                XCTFail("both callers must see the load failure")
            } catch {
                XCTAssertEqual(error as? FakeWhisperEngineError, .simulatedLoadFailure)
            }
        }
        let loadCount = await gatedEngine.loadCount
        XCTAssertEqual(loadCount, 1)
        let current = await runtime.currentModelID
        XCTAssertNil(current)
    }

    func testUnloadDuringAnInFlightActivationWaitsAndLeavesNothingLoaded() async throws {
        let gate = WhisperTestGate()
        let gatedEngine = GatedWhisperEngine(log: log, loadGate: gate)
        let runtime = WhisperRuntime(engine: gatedEngine, modelFolder: Self.folder(for:))

        let activation = Task { try await runtime.activate(.baseEn) }
        await waitForLoadCount(1, on: gatedEngine)
        await settle()
        let unload = Task { await runtime.unload() }
        await settle()
        await gate.open()

        try await activation.value
        await unload.value
        XCTAssertEqual(log.all, [.loaded(.baseEn), .unloaded(.baseEn)])
        let current = await runtime.currentModelID
        XCTAssertNil(current)
    }

    func testUnloadIfInvolvingWaitsForInFlightActivationOfThatModelThenUnloads() async throws {
        let gate = WhisperTestGate()
        let gatedEngine = GatedWhisperEngine(log: log, loadGate: gate)
        let runtime = WhisperRuntime(engine: gatedEngine, modelFolder: Self.folder(for:))

        let activation = Task { try await runtime.activate(.baseEn) }
        await waitForLoadCount(1, on: gatedEngine)
        await settle()

        let unload = Task { await runtime.unload(ifInvolving: .baseEn) }
        await settle()
        XCTAssertEqual(log.all, [], "must not unload until the in-flight activation it targets resolves")

        await gate.open()
        try await activation.value
        await unload.value

        XCTAssertEqual(log.all, [.loaded(.baseEn), .unloaded(.baseEn)], "must unload the model once its activation finishes")
        let current = await runtime.currentModelID
        XCTAssertNil(current)
    }

    func testUnloadIfInvolvingAnUnrelatedModelDuringAnActivationLeavesTheActivationAlone() async throws {
        let gate = WhisperTestGate()
        let gatedEngine = GatedWhisperEngine(log: log, loadGate: gate)
        let runtime = WhisperRuntime(engine: gatedEngine, modelFolder: Self.folder(for:))

        let activation = Task { try await runtime.activate(.baseEn) }
        await waitForLoadCount(1, on: gatedEngine)

        await runtime.unload(ifInvolving: .smallEn)

        await gate.open()
        try await activation.value

        XCTAssertEqual(log.all, [.loaded(.baseEn)], "an unrelated id must not disturb the in-flight activation")
        let current = await runtime.currentModelID
        XCTAssertEqual(current, .baseEn)
    }

    func testUnloadIfInvolvingTheCurrentlyLoadedModelUnloadsIt() async throws {
        try await runtime.activate(.baseEn)

        await runtime.unload(ifInvolving: .baseEn)

        XCTAssertEqual(log.all, [.loaded(.baseEn), .unloaded(.baseEn)])
        let current = await runtime.currentModelID
        XCTAssertNil(current)
    }

    func testUnloadIfInvolvingAModelThatIsNeitherLoadedNorInFlightIsANoOp() async throws {
        try await runtime.activate(.baseEn)

        await runtime.unload(ifInvolving: .smallEn)

        XCTAssertEqual(log.all, [.loaded(.baseEn)])
        let current = await runtime.currentModelID
        XCTAssertEqual(current, .baseEn)
    }

    func testUnloadIfInvolvingTheModelBeingDrainedDuringASwitchWaitsForTheDrainAndLeavesTheReplacementLoaded() async throws {
        let transcribeGate = WhisperTestGate()
        let gatedEngine = GatedWhisperEngine(log: log, transcribeGateByID: [.baseEn: transcribeGate])
        let runtime = WhisperRuntime(engine: gatedEngine, modelFolder: Self.folder(for:))
        try await runtime.activate(.baseEn)
        let contextOpt = await gatedEngine.lastContext
        let context = try XCTUnwrap(contextOpt)

        let transcription = Task { try await runtime.transcribe([0.1], options: STTOptions()) }
        while await !context.transcribeStarted { await Task.yield() }
        // .baseEn is now mid-drain of a switch to .smallEn: `currentModelID` already reads `nil`,
        // but the runtime still needs .baseEn's files until the drain finishes.
        let switchTask = Task { try await runtime.activate(.smallEn) }
        await settle()

        let unloadBaseEn = Task { await runtime.unload(ifInvolving: .baseEn) }
        await settle()
        XCTAssertFalse(log.all.contains(.unloaded(.baseEn)), "must not resume the drain early")

        await transcribeGate.open()
        _ = try await transcription.value
        try await switchTask.value
        await unloadBaseEn.value

        XCTAssertEqual(log.all, [.loaded(.baseEn), .transcribed(.baseEn), .unloaded(.baseEn), .loaded(.smallEn)])
        let current = await runtime.currentModelID
        XCTAssertEqual(current, .smallEn, "unload(ifInvolving: .baseEn) must not touch the model that replaced it")
    }
}

/// Gate the concurrency tests below open by hand. Not `private`: `WhisperModelManagerTests`
/// reuses this and the two gated fakes below it to test `removeModel` during an in-flight
/// activation without duplicating them.
actor WhisperTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

actor GatedWhisperContext: LoadedWhisperContext {
    let id: WhisperModelID
    let log: FakeWhisperEventLog
    let transcribeGate: WhisperTestGate?
    private(set) var transcribeStarted = false

    init(id: WhisperModelID, log: FakeWhisperEventLog, transcribeGate: WhisperTestGate?) {
        self.id = id
        self.log = log
        self.transcribeGate = transcribeGate
    }

    func transcribe(_ samples: [Float], options: STTOptions) async throws -> String {
        transcribeStarted = true
        await transcribeGate?.wait()
        log.append(.transcribed(id))
        return "gated transcript"
    }

    func unload() async {
        log.append(.unloaded(id))
    }
}

actor GatedWhisperEngine: WhisperEngine {
    let log: FakeWhisperEventLog
    private let loadGate: WhisperTestGate?
    private let transcribeGateByID: [WhisperModelID: WhisperTestGate]
    private let error: (any Error)?
    private(set) var loadCount = 0
    private(set) var lastContext: GatedWhisperContext?

    init(
        log: FakeWhisperEventLog,
        loadGate: WhisperTestGate? = nil,
        transcribeGateByID: [WhisperModelID: WhisperTestGate] = [:],
        error: (any Error)? = nil
    ) {
        self.log = log
        self.loadGate = loadGate
        self.transcribeGateByID = transcribeGateByID
        self.error = error
    }

    func load(modelFolder: URL) async throws -> any LoadedWhisperContext {
        loadCount += 1
        await loadGate?.wait()
        if let error { throw error }
        let id = WhisperModelID(rawValue: modelFolder.lastPathComponent)!
        log.append(.loaded(id))
        let context = GatedWhisperContext(id: id, log: log, transcribeGate: transcribeGateByID[id])
        lastContext = context
        return context
    }
}
