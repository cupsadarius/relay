import Foundation

/// Runs the ordered resolver chain (Herdr -> Rex -> tmux -> generic terminal) for agent sessions.
/// One frontmost-app lookup and the caller's one process snapshot form a single `FocusContext`
/// that every resolver and every candidate session shares.
actor FocusResolutionService {
    private let frontmostApps: FrontmostAppMonitoring
    private let resolvers: [any FocusResolver]

    init(frontmostApps: FrontmostAppMonitoring, resolvers: [any FocusResolver]) {
        self.frontmostApps = frontmostApps
        self.resolvers = resolvers
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
