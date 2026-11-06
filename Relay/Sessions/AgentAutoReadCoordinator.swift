import Foundation

/// Publishes decoded `AgentResponseEvent`s into session intelligence (`AgentSessionRegistry`) and,
/// only when auto-read is enabled, decides whether the producing session (`S`) should be spoken
/// (mode `.automatic`).
///
/// `S` speaks if EITHER:
///  1. `S` is confidently focused (`.focused` + `.high`), or
///  2. `S` is the most-recently-active agent session AND no other agent session is currently
///     confidently focused — even if `S` itself isn't focused (the user tabbed away to a
///     non-agent app), the last session the user was in keeps reading.
///
/// "Most-recently-active" (`lastActiveSessionID`) is actor state updated whenever a session is
/// found confidently focused, or whenever a session is actually spoken — never merely upserted.
/// With no established last-active session yet and nobody focused, the coordinator stays silent
/// (conservative: never auto-read a session the user never looked at).
///
/// Every other outcome — auto-read disabled, or a different session confidently focused while
/// `S` isn't the last-active one — stays silent, but the session is still upserted into the
/// registry so a background response remains available for manual "Speak Latest".
actor AgentAutoReadCoordinator {
    private let registry: AgentSessionRegistry
    private let focus: any SessionFocusResolving
    private let preprocess: @Sendable (String) -> String
    /// `Sendable` because this actor calls the `@MainActor` `speak(_:)` across isolation.
    private let speech: any SpeechSubmitting & Sendable
    private let autoReadEnabled: @Sendable () async -> Bool
    private let diagnostics: IntegrationDiagnosticsLog
    /// Takes the ONE process-table snapshot per `handle(_:)` that ancestry capture, pruning, and
    /// every focus resolver share.
    private let processInspector: ProcessInspector
    private let pipeline: PipelineEventBus?
    /// The most-recently-active agent session: the last one found confidently focused, or the
    /// last one actually auto-spoken, or the last one prompted (whichever happened most recently).
    /// `nil` until the first time any of those occurs.
    private var lastActiveSessionID: AgentSessionID?
    private var promptedAt: [AgentSessionID: Date] = [:]

    init(
        registry: AgentSessionRegistry,
        focus: any SessionFocusResolving,
        preprocess: @escaping @Sendable (String) -> String,
        speech: any SpeechSubmitting & Sendable,
        autoReadEnabled: @escaping @Sendable () async -> Bool,
        diagnostics: IntegrationDiagnosticsLog = IntegrationDiagnosticsLog(),
        processInspector: ProcessInspector = ProcessInspector(),
        pipeline: PipelineEventBus? = nil
    ) {
        self.pipeline = pipeline
        self.registry = registry
        self.focus = focus
        self.preprocess = preprocess
        self.speech = speech
        self.autoReadEnabled = autoReadEnabled
        self.diagnostics = diagnostics
        self.processInspector = processInspector
    }

    /// The user just prompted `sessionID`: it becomes the last-active session, and it wins ties
    /// when several sessions look focused (Rex cannot say which session is on screen).
    func notePrompt(_ sessionID: AgentSessionID) {
        promptedAt[sessionID] = Date()
        lastActiveSessionID = sessionID
    }

    func handle(_ event: AgentResponseEvent) async {
        let tracer = pipeline.map { PipelineTracer(flow: .agentReply, bus: $0) }
        tracer?.finish(.received, "\(event.provider.displayName) · \(Self.size(of: event.text))")
        // One snapshot per event, shared by ancestry capture, pruning, and every focus resolver.
        let snapshot = try? await processInspector.snapshot()
        let session = await registry.upsert(
            response: event,
            processAncestry: Self.processAncestry(for: event, in: snapshot)
        )
        diagnostics.append(
            stage: "coordinator",
            outcome: "session-upserted",
            detail: "provider=\(event.provider.rawValue) ancestry=\(event.processAncestry?.isEmpty == false ? "envelope" : "snapshot")"
        )
        tracer?.finish(.session, Self.terminalLabel(for: event))

        guard await autoReadEnabled() else {
            diagnostics.append(stage: "coordinator", outcome: "silent", detail: "auto-read-disabled")
            tracer?.stop(.autoRead, "Not spoken: auto-read is off")
            return
        }
        tracer?.finish(.autoRead, "On")
        tracer?.start(.focus, "Checking focus")

        // Prune before every focus decision so a dead agent's session (or one past the TTL)
        // never keeps generic-terminal focus ambiguous.
        await pruneDeadSessions(in: registry, snapshot: snapshot)

        let sessions = await registry.sessions().sorted { lhs, rhs in
            let lhsPrompt = promptedAt[lhs.id] ?? .distantPast
            let rhsPrompt = promptedAt[rhs.id] ?? .distantPast
            return lhsPrompt != rhsPrompt ? lhsPrompt > rhsPrompt : lhs.lastActivityAt > rhs.lastActivityAt
        }
        let resolution = await focus.resolveFocus(among: sessions, processSnapshot: snapshot)
        recordFocusDecisions(resolution.decisions)
        let focused = resolution.focused
        diagnostics.append(
            stage: "coordinator",
            outcome: "focus-decision",
            detail: "focused=\(focused.map { Self.label($0.id) } ?? "none") lastActive=\(lastActiveSessionID.map(Self.label) ?? "none")"
        )

        if let focused, focused.id == session.id {
            lastActiveSessionID = session.id
            tracer?.finish(.focus, "Focused")
            await speak(session: session, event: event, reason: "focused", tracer: tracer)
            return
        }

        if focused == nil, lastActiveSessionID == session.id {
            tracer?.finish(.focus, "Last active session")
            await speak(session: session, event: event, reason: "last-active", tracer: tracer)
            return
        }
        tracer?.stop(
            .focus, focused == nil ? "Not spoken: this session is not the last active one" : "Not spoken: another session has focus"
        )

        if let focused {
            // A different session now owns focus; the handoff means subsequent background
            // responses should be judged against that session, not a stale last-active one.
            lastActiveSessionID = focused.id
        }
        diagnostics.append(stage: "coordinator", outcome: "silent", detail: "reason=not-focused-not-last-active")
    }

    private func speak(session: AgentSession, event: AgentResponseEvent, reason: String, tracer: PipelineTracer?) async {
        diagnostics.append(stage: "coordinator", outcome: "spoke", detail: "provider=\(event.provider.rawValue) reason=\(reason)")
        let request = event.speechRequest(text: preprocess(event.text), mode: .automatic, tracer: tracer)
        do {
            try await speech.speak(request)
        } catch is CancellationError {
            // Superseded by newer speech or stopped by the user: expected, but still visible.
            diagnostics.append(stage: "coordinator", outcome: "speak-cancelled", detail: "provider=\(event.provider.rawValue)")
        } catch {
            // Structural only: never the error's own text, which could carry content.
            diagnostics.append(stage: "coordinator", outcome: "speak-failed", detail: "provider=\(event.provider.rawValue)")
        }
    }

    /// The "why silent?" signal: one privacy-safe entry per session resolved — resolver ID,
    /// state, confidence, and the resolver's reason (always a fixed literal, never payload,
    /// paths, or IDs).
    private func recordFocusDecisions(_ decisions: [FocusDecision]) {
        for decision in decisions {
            diagnostics.append(
                stage: "focus",
                outcome: decision.state.rawValue,
                detail: "resolver=\(decision.resolverID) confidence=\(decision.confidence) reason=\(decision.reason)"
            )
        }
    }

    /// Prefers the ancestry `RelayHook` captured itself (still correct after a wrapper shell
    /// exits); otherwise walks `event.parentPID` in `snapshot`. No snapshot gives no ancestry.
    private static func processAncestry(for event: AgentResponseEvent, in snapshot: ProcessSnapshot?) -> [Int32] {
        if let ancestry = event.processAncestry, !ancestry.isEmpty {
            return ancestry
        }
        return snapshot?.ancestry(from: event.parentPID).map(\.pid) ?? []
    }

    /// A size label only: never the reply text.
    private static func size(of text: String) -> String {
        let bytes = text.utf8.count
        return bytes < 1_024 ? "\(bytes) B" : String(format: "%.1f KB", Double(bytes) / 1_024)
    }

    private static func terminalLabel(for event: AgentResponseEvent) -> String {
        let terminal = TerminalContext(event: event)
        if terminal.rexBlockID != nil { return "Rex" }
        if terminal.herdrPaneID != nil { return "herdr" }
        if terminal.tmuxPaneID != nil { return "tmux" }
        return "Terminal"
    }

    private static func label(_ id: AgentSessionID) -> String {
        id.qualifiedName
    }
}
