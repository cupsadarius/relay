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
    private let diagnostics: IntegrationDiagnosticsLog
    /// Used to take a single process-table snapshot per `handle(_:)` call, so dead-process
    /// sessions can be pruned before every focus decision. A failed snapshot skips pruning for
    /// that cycle rather than risking a false "dead" verdict on a live session.
    private let processInspector: ProcessInspector
    /// The most-recently-active agent session: the last one found confidently focused, or the
    /// last one actually auto-spoken (whichever happened most recently). `nil` until the first
    /// time either of those occurs.
    private var lastActiveSessionID: AgentSessionID?

    init(
        registry: AgentSessionRegistry,
        processContext: any AgentProcessContextCapturing,
        focus: any SessionFocusResolving,
        preprocess: @escaping @Sendable (String) -> String,
        speech: any SpeechSubmitting & Sendable,
        autoReadEnabled: @escaping @Sendable () async -> Bool,
        diagnostics: IntegrationDiagnosticsLog = IntegrationDiagnosticsLog(),
        processInspector: ProcessInspector = ProcessInspector()
    ) {
        self.registry = registry
        self.processContext = processContext
        self.focus = focus
        self.preprocess = preprocess
        self.speech = speech
        self.autoReadEnabled = autoReadEnabled
        self.diagnostics = diagnostics
        self.processInspector = processInspector
    }

    func handle(_ event: AgentResponseEvent) async {
        let captured = await processContext.capture(parentPID: event.parentPID)
        let session = await registry.upsert(
            response: event,
            processAncestry: captured.ancestry,
            tty: captured.tty
        )
        diagnostics.append(stage: "coordinator", outcome: "session-upserted", detail: "provider=\(event.provider.rawValue)")

        guard await autoReadEnabled() else {
            diagnostics.append(stage: "coordinator", outcome: "silent", detail: "auto-read-disabled")
            return
        }

        // Prune stale sessions before every focus decision so a dead agent's session (or one gone
        // quiet past the TTL) never keeps generic-terminal focus ambiguous. One snapshot per
        // cycle (see `pruneDeadSessions`), rather than a `ps` invocation per candidate pid.
        await pruneDeadSessions(in: registry, using: processInspector)

        let sessions = await registry.sessions()
        let focused = await focus.focusedSession(among: sessions)
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
        let source: SpeechSource = event.provider == .claudeCode ? .claudeCode : .codex
        let request = SpeechRequest(
            text: preprocess(event.text),
            source: source,
            mode: .automatic,
            sessionID: "\(event.provider.rawValue):\(event.providerSessionID)"
        )
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

    private static func label(_ id: AgentSessionID) -> String {
        "\(id.provider.rawValue):\(id.providerSessionID)"
    }
}
