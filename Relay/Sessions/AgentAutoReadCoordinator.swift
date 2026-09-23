import Foundation

/// Process ancestry and tty for the process that emitted an agent response, used by
/// `AgentSessionRegistry`/focus resolvers to identify which terminal/multiplexer pane a session
/// runs in.
struct AgentProcessContext: Sendable, Equatable {
    let ancestry: [Int32]
    let tty: String?

    /// Walks `parentPID`'s ancestry in `snapshot`. No snapshot (failed `ps`) degrades to an empty
    /// context: session tracking and gating treat "no ancestry" as "unknown", never a crash.
    static func capture(parentPID: Int32, in snapshot: ProcessSnapshot?) -> AgentProcessContext {
        guard let snapshot else { return AgentProcessContext(ancestry: [], tty: nil) }
        let records = snapshot.ancestry(from: parentPID)
        return AgentProcessContext(ancestry: records.map(\.pid), tty: records.compactMap(\.tty).first)
    }

    /// Prefers the ancestry `RelayHook` captured itself (exact, and still correct after a
    /// wrapper shell has exited); falls back to walking `event.parentPID` in `snapshot` for
    /// envelopes from older helpers. The tty comes from the snapshot either way: the agent
    /// process itself may have no tty (e.g. its stdio is piped), so this takes the first
    /// non-nil tty found walking UP the ancestry chain, not just the agent's own entry.
    static func resolve(for event: AgentResponseEvent, in snapshot: ProcessSnapshot?) -> AgentProcessContext {
        if let ancestry = event.processAncestry, !ancestry.isEmpty {
            let tty = ancestry.lazy.compactMap { snapshot?.record(pid: $0)?.tty }.first
            return AgentProcessContext(ancestry: ancestry, tty: tty)
        }
        return capture(parentPID: event.parentPID, in: snapshot)
    }
}

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
    /// `any SpeechSubmitting & Sendable`, not bare `any SpeechSubmitting`: this actor calls
    /// `speech.speak(_:)` — a `@MainActor`-isolated method — from its own isolation domain, which
    /// requires the receiver to be `Sendable` for the crossing to type-check. `SpeechCoordinator`
    /// satisfies this via its `@unchecked Sendable` conformance (all of its mutable state is only
    /// ever touched from `@MainActor`), so the protocol declaration itself stays exactly as
    /// specified — only the storage type here is widened to require the marker conformance too.
    private let speech: any SpeechSubmitting & Sendable
    private let autoReadEnabled: @Sendable () async -> Bool
    private let diagnostics: IntegrationDiagnosticsLog
    /// Takes the ONE process-table snapshot per `handle(_:)` that ancestry capture, pruning, and
    /// every focus resolver share.
    private let processInspector: ProcessInspector
    /// The most-recently-active agent session: the last one found confidently focused, or the
    /// last one actually auto-spoken (whichever happened most recently). `nil` until the first
    /// time either of those occurs.
    private var lastActiveSessionID: AgentSessionID?

    init(
        registry: AgentSessionRegistry,
        focus: any SessionFocusResolving,
        preprocess: @escaping @Sendable (String) -> String,
        speech: any SpeechSubmitting & Sendable,
        autoReadEnabled: @escaping @Sendable () async -> Bool,
        diagnostics: IntegrationDiagnosticsLog = IntegrationDiagnosticsLog(),
        processInspector: ProcessInspector = ProcessInspector()
    ) {
        self.registry = registry
        self.focus = focus
        self.preprocess = preprocess
        self.speech = speech
        self.autoReadEnabled = autoReadEnabled
        self.diagnostics = diagnostics
        self.processInspector = processInspector
    }

    func handle(_ event: AgentResponseEvent) async {
        // One snapshot per event, shared by ancestry capture, pruning, and every focus resolver.
        let snapshot = try? await processInspector.snapshot()
        let captured = AgentProcessContext.resolve(for: event, in: snapshot)
        let session = await registry.upsert(
            response: event,
            processAncestry: captured.ancestry,
            tty: captured.tty
        )
        diagnostics.append(
            stage: "coordinator",
            outcome: "session-upserted",
            detail: "provider=\(event.provider.rawValue) ancestry=\(event.processAncestry?.isEmpty == false ? "envelope" : "snapshot")"
        )

        guard await autoReadEnabled() else {
            diagnostics.append(stage: "coordinator", outcome: "silent", detail: "auto-read-disabled")
            return
        }

        // Prune before every focus decision so a dead agent's session (or one past the TTL)
        // never keeps generic-terminal focus ambiguous.
        await pruneDeadSessions(in: registry, snapshot: snapshot)

        let sessions = await registry.sessions()
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
            await speak(session: session, event: event, reason: "focused")
            return
        }

        if focused == nil, lastActiveSessionID == session.id {
            await speak(session: session, event: event, reason: "last-active")
            return
        }

        if let focused {
            // A different session now owns focus; the handoff means subsequent background
            // responses should be judged against that session, not a stale last-active one.
            lastActiveSessionID = focused.id
        }
        diagnostics.append(stage: "coordinator", outcome: "silent", detail: "reason=not-focused-not-last-active")
    }

    private func speak(session: AgentSession, event: AgentResponseEvent, reason: String) async {
        diagnostics.append(stage: "coordinator", outcome: "spoke", detail: "provider=\(event.provider.rawValue) reason=\(reason)")
        let request = event.speechRequest(text: preprocess(event.text), mode: .automatic)
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

    private static func label(_ id: AgentSessionID) -> String {
        id.qualifiedName
    }
}
