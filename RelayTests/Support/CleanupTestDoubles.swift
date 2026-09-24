import CryptoKit
import Foundation
import Synchronization
import XCTest

@testable import Relay

struct CleanupTestError: Error, Equatable {}

/// An operation that suspends until the test finishes it. A cooperative one finishes with
/// `CancellationError` as soon as its task is cancelled; a non-cooperative one ignores
/// cancellation (a zombie) until `finish` is called.
final class ManualOperation: Sendable {
    private struct State {
        var continuation: CheckedContinuation<String, Error>?
        var pending: Result<String, Error>?
        var startCount = 0
    }

    let cooperative: Bool
    private let state = Mutex(State())

    init(cooperative: Bool) { self.cooperative = cooperative }

    var startCount: Int { state.withLock { $0.startCount } }

    func run() async throws -> String {
        guard cooperative else { return try await suspend() }
        return try await withTaskCancellationHandler {
            try await suspend()
        } onCancel: {
            finish(.failure(CancellationError()))
        }
    }

    func finish(_ result: Result<String, Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<String, Error>? in
            if let continuation = state.continuation {
                state.continuation = nil
                return continuation
            }
            if state.pending == nil { state.pending = result }
            return nil
        }
        continuation?.resume(with: result)
    }

    private func suspend() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let pending = state.withLock { state -> Result<String, Error>? in
                state.startCount += 1
                if let pending = state.pending {
                    state.pending = nil
                    return pending
                }
                state.continuation = continuation
                return nil
            }
            if let pending { continuation.resume(with: pending) }
        }
    }
}

/// A sleep seam that suspends until the test fires it. Cancelling the sleeping task throws.
final class TestSleeper: Sendable {
    private struct Waiter {
        let id: UUID
        let duration: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct State {
        var waiters: [Waiter] = []
        var cancelledEarly: Set<UUID> = []
        var history: [Duration] = []
    }

    private let state = Mutex(State())

    var sleepFunction: @Sendable (Duration) async throws -> Void { { try await self.sleep($0) } }

    func pending(_ duration: Duration) -> Int { state.withLock { $0.waiters.filter { $0.duration == duration }.count } }
    func requestCount(_ duration: Duration) -> Int { state.withLock { $0.history.filter { $0 == duration }.count } }

    /// Resumes every pending sleep of exactly `duration`.
    func fire(_ duration: Duration) {
        let fired = state.withLock { state -> [Waiter] in
            let matching = state.waiters.filter { $0.duration == duration }
            state.waiters.removeAll { $0.duration == duration }
            return matching
        }
        for waiter in fired { waiter.continuation.resume() }
    }

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let cancelled = state.withLock { state -> Bool in
                    state.history.append(duration)
                    if state.cancelledEarly.remove(id) != nil { return true }
                    state.waiters.append(Waiter(id: id, duration: duration, continuation: continuation))
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let waiter = state.withLock { state -> Waiter? in
                if let index = state.waiters.firstIndex(where: { $0.id == id }) { return state.waiters.remove(at: index) }
                state.cancelledEarly.insert(id)
                return nil
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }
}

/// Thread-safe ordered event log for ordering assertions.
final class OrderLog: Sendable {
    private let entries = Mutex<[String]>([])
    func append(_ entry: String) { entries.withLock { $0.append(entry) } }
    var values: [String] { entries.withLock { $0 } }
}

@MainActor
extension XCTestCase {
    /// Polls `condition` until it holds or fails the test after `timeout`.
    func eventually(
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if await condition() { return }
            if Date() > deadline {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            await Task.yield()
        }
    }
}

/// A scriptable `AppleCleanupBackending`.
final class FakeAppleCleanup: AppleCleanupBackending {
    private struct State {
        var availability: AppleCleanupAvailability
        var supportsLocale: Bool
        var prewarmCount = 0
        var requests: [CleanupRequest] = []
        var priorities: [CleanupPriority] = []
    }

    private let state: Mutex<State>
    private let handler: @Sendable (CleanupRequest, CleanupPriority) async throws -> String

    init(
        availability: AppleCleanupAvailability = .available,
        supportsLocale: Bool = true,
        handler: @escaping @Sendable (CleanupRequest, CleanupPriority) async throws -> String = { request, _ in request.input }
    ) {
        state = Mutex(State(availability: availability, supportsLocale: supportsLocale))
        self.handler = handler
    }

    var prewarmCount: Int { state.withLock { $0.prewarmCount } }
    var requests: [CleanupRequest] { state.withLock { $0.requests } }
    var priorities: [CleanupPriority] { state.withLock { $0.priorities } }
    func setAvailability(_ availability: AppleCleanupAvailability) { state.withLock { $0.availability = availability } }

    func availability() -> AppleCleanupAvailability { state.withLock { $0.availability } }
    func supportsLocale(_ locale: Locale) -> Bool { state.withLock { $0.supportsLocale } }
    func prewarm(instructions: String) { state.withLock { $0.prewarmCount += 1 } }

    func generate(_ request: CleanupRequest, priority: CleanupPriority) async throws -> String {
        state.withLock {
            $0.requests.append(request)
            $0.priorities.append(priority)
        }
        return try await handler(request, priority)
    }
}

/// A scriptable `MLXCleanupRuntimeServing`.
actor FakeMLXRuntime: MLXCleanupRuntimeServing {
    nonisolated let events: AsyncStream<MLXCleanupRuntimeEvent>
    nonisolated let eventSink: AsyncStream<MLXCleanupRuntimeEvent>.Continuation
    private nonisolated let present: Mutex<Set<CleanupModelID>>
    private let log: OrderLog?
    private let handler: @Sendable (CleanupRequest, CleanupPriority) async throws -> String
    private var readinessValue: MLXCleanupReadiness
    private(set) var ensureLoadedCalls: [CleanupModelID] = []
    private(set) var generateRequests: [CleanupRequest] = []
    private(set) var generatePriorities: [CleanupPriority] = []
    private(set) var touchCount = 0
    private(set) var unloadCauses: [CleanupUnloadCause] = []
    private(set) var unloadInvolving: [CleanupModelID] = []
    private(set) var retireCount = 0

    init(
        present: Set<CleanupModelID> = [.qwen3_0_6b, .qwen3_1_7b],
        readiness: MLXCleanupReadiness = .ready,
        log: OrderLog? = nil,
        handler: @escaping @Sendable (CleanupRequest, CleanupPriority) async throws -> String = { request, _ in request.input }
    ) {
        let (stream, continuation) = AsyncStream.makeStream(of: MLXCleanupRuntimeEvent.self)
        events = stream
        eventSink = continuation
        self.present = Mutex(present)
        readinessValue = readiness
        self.log = log
        self.handler = handler
    }

    // Controller decision (Task 25): finish the stream on deinit so the service's
    // `for await event in events` loop ends instead of piling up as a suspended task once a
    // test's fake and service go out of scope.
    deinit { eventSink.finish() }

    nonisolated func isPresent(_ id: CleanupModelID) -> Bool { present.withLock { $0.contains(id) } }
    nonisolated func setPresent(_ ids: Set<CleanupModelID>) { present.withLock { $0 = ids } }
    func setReadiness(_ readiness: MLXCleanupReadiness) { readinessValue = readiness }

    func readiness(for id: CleanupModelID) -> MLXCleanupReadiness { readinessValue }
    func ensureLoaded(_ id: CleanupModelID) async throws {
        ensureLoadedCalls.append(id)
        readinessValue = .ready
    }
    func generate(_ request: CleanupRequest, priority: CleanupPriority) async throws -> String {
        generateRequests.append(request)
        generatePriorities.append(priority)
        return try await handler(request, priority)
    }
    func touch() { touchCount += 1 }
    func unload(cause: CleanupUnloadCause) { unloadCauses.append(cause) }
    func unload(ifInvolving id: CleanupModelID) {
        unloadInvolving.append(id)
        log?.append("unloadIfInvolving \(id.rawValue)")
    }
    func retireGeneration() { retireCount += 1 }
}

@MainActor
final class SpyTranscriptCleaner: TranscriptCleaning {
    private(set) var prewarmCount = 0
    nonisolated init() {}
    func cleanForInsertion(
        _ text: String,
        onAttempt: @MainActor () -> Void
    ) async throws(CancellationError) -> TranscriptCleanupResult {
        .notAttempted(text)
    }
    func prewarm() { prewarmCount += 1 }
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Writes the given files into the staging directory and reports each one's oid. `lie` reports
/// a wrong oid for that path; `omit` writes nothing for that path and leaves it out of the list.
final class FakeSnapshotDownloader: SnapshotDownloading {
    private let files: [String: Data]
    private let lie: Set<String>
    private let error: (any Error)?
    private let calls = Mutex(0)

    init(files: [String: Data], lie: Set<String> = [], error: (any Error)? = nil) {
        self.files = files
        self.lie = lie
        self.error = error
    }

    var callCount: Int { calls.withLock { $0 } }

    func download(
        _ snapshot: PinnedSnapshot,
        into directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [VerifiedModelFile] {
        calls.withLock { $0 += 1 }
        if let error { throw error }
        var result: [VerifiedModelFile] = []
        for (path, data) in files.sorted(by: { $0.key < $1.key }) {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            let digest = lie.contains(path) ? String(repeating: "0", count: 64) : sha256Hex(data)
            result.append(VerifiedModelFile(relativePath: path, oid: .sha256(digest)))
        }
        progress(1)
        return result
    }
}

/// A scriptable `MLXCleanupEngine`. `loadGate`, when set, makes every load wait on it.
final class FakeMLXEngine: MLXCleanupEngine {
    final class Model: LoadedMLXCleanupModel {
        let directory: URL
        private let handler: @Sendable (CleanupRequest) async throws -> String
        private let unloads = Mutex(0)
        init(directory: URL, handler: @escaping @Sendable (CleanupRequest) async throws -> String) {
            self.directory = directory
            self.handler = handler
        }
        var unloadCount: Int { unloads.withLock { $0 } }
        func generate(_ request: CleanupRequest) async throws -> String { try await handler(request) }
        func unload() async { unloads.withLock { $0 += 1 } }
    }

    private struct State {
        var loads: [URL] = []
        var models: [Model] = []
        var clearCacheCount = 0
        var failNextLoad = false
    }

    private let state = Mutex(State())
    private let loadGate: ManualOperation?
    private let handler: @Sendable (CleanupRequest) async throws -> String

    init(loadGate: ManualOperation? = nil, handler: @escaping @Sendable (CleanupRequest) async throws -> String = { $0.input }) {
        self.loadGate = loadGate
        self.handler = handler
    }

    var loads: [URL] { state.withLock { $0.loads } }
    var models: [Model] { state.withLock { $0.models } }
    var clearCacheCount: Int { state.withLock { $0.clearCacheCount } }
    func failNextLoad() { state.withLock { $0.failNextLoad = true } }

    func load(directory: URL) async throws -> any LoadedMLXCleanupModel {
        state.withLock { $0.loads.append(directory) }
        if let loadGate { _ = try await loadGate.run() }
        let fail = state.withLock { state -> Bool in
            defer { state.failNextLoad = false }
            return state.failNextLoad
        }
        if fail { throw CleanupTestError() }
        let model = Model(directory: directory, handler: handler)
        state.withLock { $0.models.append(model) }
        return model
    }

    func clearCache() async { state.withLock { $0.clearCacheCount += 1 } }
}

final class FakeMemoryPressure: MemoryPressureMonitoring {
    private let handler = Mutex<(@Sendable () -> Void)?>(nil)
    func start(_ handler: @escaping @Sendable () -> Void) { self.handler.withLock { $0 = handler } }
    func fire() { handler.withLock { $0 }?() }
}

/// A `Sendable` box for mutable test state shared with `@Sendable` closures. A bare `Mutex` is
/// noncopyable, so it cannot be copied into a local or captured by an escaping closure.
final class LockedValue<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) { mutex = Mutex(value) }

    func withLock<Result: Sendable>(_ body: (inout Value) -> Result) -> Result {
        mutex.withLock { body(&$0) }
    }
}
