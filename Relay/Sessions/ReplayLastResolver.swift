import Foundation

/// What "Replay Last" should speak.
enum ReplayTarget: Equatable, Sendable {
    /// Tier 1: a confidently focused agent session's own last reply.
    case focusedSession(AgentSession)
    /// Tier 2: the frontmost app hosts an agent session but focus is ambiguous — the global latest reply.
    case globalLatest
    /// Tier 3: a non-agent context — re-speak the last spoken/selected text.
    case lastSpoken
}

/// Decides the Replay Last tier. Reads the session registry, one process snapshot, focus
/// resolution and the frontmost app; performs no speech.
@MainActor
struct ReplayLastResolver {
    let registry: AgentSessionRegistry
    let processInspector: ProcessInspector
    let focusResolution: any SessionFocusResolving
    let frontmostApps: any FrontmostAppMonitoring

    /// - Parameter globalLatestAvailable: evaluated only at the tier-2 check, so it reflects the
    ///   store at that moment.
    func resolve(globalLatestAvailable: () -> Bool) async -> ReplayTarget {
        // One snapshot for this decision, shared by pruning and every focus resolver — the same
        // shape as `AgentAutoReadCoordinator.handle(_:)`. Pruning first means a dead-process
        // session is never offered to focus resolution or treated as hosting the frontmost app.
        let snapshot = try? await processInspector.snapshot()
        await pruneDeadSessions(in: registry, snapshot: snapshot)
        let sessions = await registry.sessions()

        if let focused = await focusResolution.resolveFocus(among: sessions, processSnapshot: snapshot).focused {
            return .focusedSession(focused)
        }
        if let frontmostPID = await frontmostApps.current()?.pid,
            sessions.contains(where: { $0.processAncestry.contains(frontmostPID) }),
            globalLatestAvailable()
        {
            return .globalLatest
        }
        return .lastSpoken
    }
}
