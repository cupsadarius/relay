import Foundation
import Synchronization

enum DeadlineOutcome<Value: Sendable>: Sendable {
    case value(Value)
    case failure(any Error)
    case timedOut
}

/// Resolves exactly once, from whichever of {operation, deadline, caller cancellation} is first.
private final class DeadlineLatch<Value: Sendable>: Sendable {
    enum Resolution: Sendable {
        case outcome(DeadlineOutcome<Value>)
        case cancelled
    }

    private struct State {
        var continuation: CheckedContinuation<Resolution, Never>?
        var pending: Resolution?
        var done = false
    }

    private let state = Mutex(State())

    func install(_ continuation: CheckedContinuation<Resolution, Never>) {
        let early = state.withLock { state -> Resolution? in
            if let pending = state.pending {
                state.pending = nil
                state.done = true
                return pending
            }
            state.continuation = continuation
            return nil
        }
        if let early { continuation.resume(returning: early) }
    }

    func resolve(_ resolution: Resolution) {
        let continuation = state.withLock { state -> CheckedContinuation<Resolution, Never>? in
            guard !state.done else { return nil }
            if let continuation = state.continuation {
                state.continuation = nil
                state.done = true
                return continuation
            }
            if state.pending == nil { state.pending = resolution }
            return nil
        }
        continuation?.resume(returning: resolution)
    }
}

/// Runs `operation` against a wall-clock `timeout` without a task group, so a generation that
/// ignores cancellation cannot hold the caller past the deadline (spec §8.3). On timeout or caller
/// cancellation the operation's task is cancelled and left to finish on its own; whoever owns it
/// (the generation slot) tracks it as a zombie. Throws only `CancellationError`.
func withCleanupDeadline<Value: Sendable>(
    _ timeout: Duration,
    sleep: @escaping @Sendable (Duration) async throws -> Void,
    operation: @escaping @Sendable () async throws -> Value
) async throws(CancellationError) -> DeadlineOutcome<Value> {
    if Task.isCancelled { throw CancellationError() }
    let latch = DeadlineLatch<Value>()
    let work = Task { try await operation() }
    let timer = Task {
        do { try await sleep(timeout) } catch { return }
        latch.resolve(.outcome(.timedOut))
    }
    Task {
        switch await work.result {
        case let .success(value): latch.resolve(.outcome(.value(value)))
        case let .failure(error): latch.resolve(.outcome(.failure(error)))
        }
    }
    let resolution = await withTaskCancellationHandler {
        await withCheckedContinuation { latch.install($0) }
    } onCancel: {
        latch.resolve(.cancelled)
    }
    timer.cancel()
    switch resolution {
    case .cancelled:
        work.cancel()
        throw CancellationError()
    case .outcome(.timedOut):
        work.cancel()
        return .timedOut
    case let .outcome(outcome):
        return outcome
    }
}
