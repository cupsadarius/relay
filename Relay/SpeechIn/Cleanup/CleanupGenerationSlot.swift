import Foundation

enum CleanupPriority: Equatable, Sendable {
    case production
    case test
}

enum CleanupSlotError: Error, Equatable, Sendable {
    /// Another generation, or a zombie, holds the slot. Production fails open on this at once.
    case busy
    /// A production request cancelled this Test generation ("Cancelled by dictation").
    case preempted
    /// The owner closed the slot to unload its model.
    case closed
}

/// At most one cleanup generation at a time (spec §8.4). Busy never queues. Production preempts a
/// running Test and waits up to `preemptWait` for it to drain. A generation whose caller was
/// cancelled (or that was retired) stays tracked as a zombie until its operation actually returns.
actor CleanupGenerationSlot {
    private struct Active {
        let token: UUID
        let priority: CleanupPriority
        let task: Task<String, Error>
        var retired = false
        var preempted = false
    }

    private let preemptWait: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var active: Active?
    private var closed = false
    private var idleWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    /// The pending timeout task backing each entry in `idleWaiters` that was given a `limit`
    /// (review fix 9). Cancelled once its waiter resolves for any other reason, instead of being
    /// left to sleep out its full duration for nothing.
    private var idleTimers: [UUID: Task<Void, Never>] = [:]

    init(
        preemptWait: Duration = .milliseconds(150),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.preemptWait = preemptWait
        self.sleep = sleep
    }

    var isBusy: Bool { active != nil }
    var hasZombie: Bool { active?.retired == true }
    var isClosed: Bool { closed }

    func run(_ priority: CleanupPriority, _ operation: @escaping @Sendable () async throws -> String) async throws -> String {
        guard !closed else { throw CleanupSlotError.closed }
        if let current = active {
            guard priority == .production, current.priority == .test, !current.retired else { throw CleanupSlotError.busy }
            active?.retired = true
            active?.preempted = true
            current.task.cancel()
            let drained = await waitForIdle(upTo: preemptWait)
            guard drained, active == nil, !closed else { throw CleanupSlotError.busy }
        }

        let token = UUID()
        let task = Task { try await operation() }
        active = Active(token: token, priority: priority, task: task)
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
            Task { await self.markRetired(token: token) }
        }
        let wasPreempted = active?.token == token && active?.preempted == true
        if active?.token == token { active = nil }
        resumeIdleWaiters()
        if wasPreempted { throw CleanupSlotError.preempted }
        return try result.get()
    }

    /// Cancels the active generation and tracks it as a zombie (model removal, spec §14.3).
    func retire() {
        guard let current = active else { return }
        active?.retired = true
        current.task.cancel()
    }

    /// Rejects new generations and waits until the active one (zombies included) returns.
    func close() async {
        closed = true
        while active != nil {
            _ = await waitForIdle(upTo: nil)
        }
    }

    func open() {
        closed = false
    }

    private func markRetired(token: UUID) {
        guard active?.token == token else { return }
        active?.retired = true
    }

    /// `true` once nothing is active; `false` if `limit` elapses first.
    private func waitForIdle(upTo limit: Duration?) async -> Bool {
        guard active != nil else { return true }
        let id = UUID()
        if let limit {
            let sleep = sleep
            idleTimers[id] = Task {
                do {
                    try await sleep(limit)
                    self.expireWaiter(id)
                } catch {
                    // Cancelled by `resumeIdleWaiters()`/`expireWaiter(_:)`: the waiter has
                    // already been resolved some other way, nothing left to do here.
                }
            }
        }
        return await withCheckedContinuation { idleWaiters[id] = $0 }
    }

    private func expireWaiter(_ id: UUID) {
        idleTimers.removeValue(forKey: id)
        idleWaiters.removeValue(forKey: id)?.resume(returning: false)
    }

    private func resumeIdleWaiters() {
        let waiters = idleWaiters
        idleWaiters = [:]
        let timers = idleTimers
        idleTimers = [:]
        for timer in timers.values { timer.cancel() }
        for waiter in waiters.values { waiter.resume(returning: true) }
    }
}
