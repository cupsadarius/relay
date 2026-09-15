import Foundation

/// Process ancestry and tty captured for the process that emitted an agent response, used by
/// `AgentSessionRegistry`/focus resolvers to identify which terminal/multiplexer pane a session is
/// running in.
struct AgentProcessContext: Sendable, Equatable {
    let ancestry: [Int32]
    let tty: String?
}

protocol AgentProcessContextCapturing: Sendable {
    func capture(parentPID: Int32) async -> AgentProcessContext
}

/// Production `AgentProcessContextCapturing`, backed by `ProcessInspector`. A failed `ps` snapshot
/// degrades to an empty context rather than throwing: session tracking and auto-read gating both
/// treat "no ancestry" as "unknown", never as a crash.
struct AgentProcessContextCapture: AgentProcessContextCapturing {
    let processInspector: ProcessInspector

    func capture(parentPID: Int32) async -> AgentProcessContext {
        guard let snapshot = try? processInspector.snapshot() else {
            return .init(ancestry: [], tty: nil)
        }
        let records = snapshot.ancestry(from: parentPID)
        return .init(ancestry: records.map(\.pid), tty: records.compactMap(\.tty).first)
    }
}

/// Publishes decoded `AgentResponseEvent`s into session intelligence (`AgentSessionRegistry`) and,
/// only when auto-read is enabled AND the resolved focus is a confidently-focused
/// (`.focused`/`.high`) session, submits exactly one `.automatic` `SpeechRequest`.
///
/// Every other outcome — auto-read disabled, `.notFocused`, `.unknown`, or any confidence below
/// `.high` — stays silent, but the session is still upserted into the registry so a background
/// response remains available for manual "Speak Latest".
actor AgentAutoReadCoordinator {
    private let registry: AgentSessionRegistry
    private let processContext: any AgentProcessContextCapturing
    private let focus: any SessionFocusResolving
    private let preprocess: @Sendable (String) -> String
    /// `any SpeechSubmitting & Sendable`, not bare `any SpeechSubmitting`: this actor calls
    /// `speech.speak(_:)` — a `@MainActor`-isolated method — from its own isolation domain, which
    /// requires the receiver to be `Sendable` for the crossing to type-check. `SpeechCoordinator`
    /// satisfies this via its `@unchecked Sendable` conformance (all of its mutable state is only
    /// ever touched from `@MainActor`), so the protocol declaration itself stays exactly as
    /// specified — only the storage type here is widened to require the marker conformance too.
    private let speech: any SpeechSubmitting & Sendable
    private let autoReadEnabled: @Sendable () async -> Bool

    init(
        registry: AgentSessionRegistry,
        processContext: any AgentProcessContextCapturing,
        focus: any SessionFocusResolving,
        preprocess: @escaping @Sendable (String) -> String,
        speech: any SpeechSubmitting & Sendable,
        autoReadEnabled: @escaping @Sendable () async -> Bool
    ) {
        self.registry = registry
        self.processContext = processContext
        self.focus = focus
        self.preprocess = preprocess
        self.speech = speech
        self.autoReadEnabled = autoReadEnabled
    }

    func handle(_ event: AgentResponseEvent) async {
        let captured = await processContext.capture(parentPID: event.parentPID)
        let session = await registry.upsert(
            response: event,
            processAncestry: captured.ancestry,
            tty: captured.tty
        )

        guard await autoReadEnabled() else { return }
        let decision = await focus.resolve(session: session)
        guard decision.state == .focused, decision.confidence == .high else { return }

        let source: SpeechSource = event.provider == .claudeCode ? .claudeCode : .codex
        let request = SpeechRequest(
            text: preprocess(event.text),
            source: source,
            mode: .automatic,
            sessionID: "\(event.provider.rawValue):\(event.providerSessionID)"
        )
        try? await speech.speak(request)
    }
}
