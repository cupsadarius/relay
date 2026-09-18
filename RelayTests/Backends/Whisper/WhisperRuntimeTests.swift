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

        let loadCount = log.all.filter { if case .loaded(.baseEn) = $0 { return true }; return false }.count
        let unloadCount = log.all.filter { if case .unloaded = $0 { return true }; return false }.count
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
}
