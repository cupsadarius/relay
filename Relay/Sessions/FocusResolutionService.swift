import Foundation

/// Runs the ordered resolver chain (Herdr -> tmux -> generic terminal) for agent sessions.
///
/// `resolveFocus(among:processSnapshot:)` is the hot path: ONE frontmost-app lookup and the
/// caller's ONE process snapshot are put into a single `FocusContext` that every resolver and
/// every candidate session shares. `resolve(session:)` is the standalone form and takes its own
/// snapshot.
actor FocusResolutionService {
    private let registry: AgentSessionRegistry
    private let frontmostApps: FrontmostAppMonitoring
    private let processSnapshots: any ProcessSnapshotProviding
    private let resolvers: [any FocusResolver]

    init(
        registry: AgentSessionRegistry,
        frontmostApps: FrontmostAppMonitoring,
        processSnapshots: any ProcessSnapshotProviding = ProcessInspector(),
        resolvers: [any FocusResolver]
    ) {
        self.registry = registry
        self.frontmostApps = frontmostApps
        self.processSnapshots = processSnapshots
        self.resolvers = resolvers
    }

    func resolve(session: AgentSession) async -> FocusDecision {
        let snapshot = try? await processSnapshots.snapshot()
        let context = FocusContext(
            frontmostApplication: await frontmostApps.current(),
            sessions: await registry.sessions(),
            processSnapshot: snapshot
        )
        return await decide(session: session, context: context)
    }

    func resolveFocus(among sessions: [AgentSession], processSnapshot: ProcessSnapshot?) async -> FocusResolution {
        let context = FocusContext(
            frontmostApplication: await frontmostApps.current(),
            sessions: sessions,
            processSnapshot: processSnapshot
        )
        var decisions: [FocusDecision] = []
        for session in sessions {
            let decision = await decide(session: session, context: context)
            decisions.append(decision)
            if decision.isConfidentlyFocused {
                return FocusResolution(focused: session, decisions: decisions)
            }
        }
        return FocusResolution(focused: nil, decisions: decisions)
    }

    /// First high-confidence, non-unknown decision from a supporting resolver wins. Otherwise
    /// the last resolver's own `.unknown` (with its specific reason) is returned, so diagnostics
    /// can say WHY focus was unknown.
    private func decide(session: AgentSession, context: FocusContext) async -> FocusDecision {
        var lastUnknown: FocusDecision?
        for resolver in resolvers where resolver.supports(session) {
            let decision = await resolver.resolve(session: session, context: context)
            if decision.confidence == .high && decision.state != .unknown { return decision }
            lastUnknown = decision
        }
        return lastUnknown ?? .unknown(resolverID: "focus-resolution", reason: "no resolver supports this session")
    }
}

extension FocusResolutionService: SessionFocusResolving {}
