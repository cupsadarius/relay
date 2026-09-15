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
}

extension FocusResolutionService: SessionFocusResolving {}
