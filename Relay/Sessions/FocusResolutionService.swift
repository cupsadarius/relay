import Foundation

actor FocusResolutionService {
    private let registry: AgentSessionRegistry
    private let frontmostApps: FrontmostAppMonitoring
    private let resolvers: [any FocusResolver]
    private let now: @Sendable () -> Date

    init(
        registry: AgentSessionRegistry,
        frontmostApps: FrontmostAppMonitoring,
        resolvers: [any FocusResolver],
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.registry = registry
        self.frontmostApps = frontmostApps
        self.resolvers = resolvers
        self.now = now
    }

    func resolve(session: AgentSession) async -> FocusDecision {
        let context = FocusContext(
            frontmostApplication: await frontmostApps.current(),
            sessions: await registry.sessions(),
            now: now()
        )
        for resolver in resolvers where resolver.supports(session) {
            let decision = await resolver.resolve(session: session, context: context)
            if decision.confidence == .high && decision.state != .unknown { return decision }
        }
        return .unknown(resolverID: "focus-resolution", reason: "no resolver produced high-confidence focus evidence")
    }

    /// Resolves each of `sessions` in turn via `resolve(session:)` (the same per-session
    /// machinery used everywhere else) and returns the single confidently-focused
    /// (`.focused` + `.high`) session, or `nil` if none is. `sessions` is expected to be tiny
    /// (the live agent session count), so resolving each one in turn — rather than trying to
    /// batch the underlying ps/lsof-backed resolvers — keeps this simple; those resolvers are
    /// already deadlock-hardened for repeated calls.
    func focusedSession(among sessions: [AgentSession]) async -> AgentSession? {
        for session in sessions {
            let decision = await resolve(session: session)
            if decision.state == .focused, decision.confidence == .high {
                return session
            }
        }
        return nil
    }
}

extension FocusResolutionService: SessionFocusResolving {}
