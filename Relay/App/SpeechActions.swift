import Foundation

/// User-initiated speech: read the selection, session-aware replay, stop, voice preview, and
/// speaking the latest agent response. Holds no state; failures go to diagnostics + status line.
/// The caller owns the task these run in: every speak re-checks `Task.isCancelled` first, and a
/// `CancellationError` (Stop, or a newer press) is intentional — never `.ttsFailed`.
@MainActor
final class SpeechActions {
    /// Fixed sample for voice previews — never user content.
    static let previewSampleText = "This is a preview of the selected voice and speaking rate."

    private let selectionReader: any SelectionReading
    private let preprocessor: RulesSpeechPreprocessor
    private let speechCoordinator: any SpeechCoordinating
    private let integrationManager: IntegrationManager
    private let integrationDiagnosticsLog: IntegrationDiagnosticsLog
    private let replayResolver: ReplayLastResolver
    private let voiceCatalog: SpeechVoiceCatalog
    private let settings: SettingsController
    private let diagnostics: DiagnosticsRecorder
    private let statusSink: StatusSink

    init(runtime: RelayRuntime, voiceCatalog: SpeechVoiceCatalog) {
        selectionReader = runtime.selectionReader
        preprocessor = runtime.preprocessor
        speechCoordinator = runtime.speechOut.speechCoordinator
        integrationManager = runtime.integrations.integrationManager
        integrationDiagnosticsLog = runtime.integrationDiagnosticsLog
        replayResolver = ReplayLastResolver(
            registry: runtime.sessions.registry,
            processInspector: runtime.sessions.processInspector,
            focusResolution: runtime.sessions.focusResolution,
            frontmostApps: runtime.sessions.frontmostApps
        )
        self.voiceCatalog = voiceCatalog
        settings = runtime.settingsController
        diagnostics = runtime.diagnostics
        statusSink = runtime.status
    }

    func readSelection() async {
        do {
            let selection = try await selectionReader.readSelection()
            diagnostics.record(selection.source == .accessibility ? .selectionAccessibility : .selectionClipboard)
            let request = SpeechRequest(
                text: preprocessor.prepare(text: selection.text, mode: .userRequested),
                source: .selection,
                mode: .userRequested,
                sessionID: nil
            )
            guard !Task.isCancelled else { return }
            try await speechCoordinator.speak(request)
            diagnostics.record(.ttsSubmitted)
        } catch is CancellationError {
            // Stopped or superseded on purpose: not a failure.
        } catch {
            diagnostics.record(error is SelectionReadingError ? .selectionUnavailable : .ttsFailed)
            statusSink.post(error.localizedDescription)
        }
    }

    /// Session-aware Replay Last; tiers documented on `ReplayTarget`. Always `.userRequested`.
    func replayLast() async {
        let manager = integrationManager
        let target = await replayResolver.resolve(globalLatestAvailable: { manager.latestResponse != nil })
        guard !Task.isCancelled else { return }
        switch target {
        case let .focusedSession(session):
            await speakFocusedSessionReply(session)
        case .globalLatest:
            if await speakGlobalLatestReply() { return }
            guard !Task.isCancelled else { return }
            await speakLastSpokenText()
        case .lastSpoken:
            await speakLastSpokenText()
        }
    }

    /// Stops playback. Cancelling the in-flight action task is the caller's job (`HotkeyController`).
    func stopSpeech() {
        speechCoordinator.stop()
        diagnostics.record(.ttsStopped)
        statusSink.post("Speech stopped")
    }

    func previewVoice(backendID: String, voiceID: String) async {
        guard let options = voiceCatalog.options(for: voiceID, backendID: backendID, settings: settings.current) else { return }
        do {
            try await speechCoordinator.previewVoice(text: Self.previewSampleText, backendID: backendID, options: options)
            diagnostics.record(.ttsSubmitted)
        } catch {
            diagnostics.record(.ttsFailed)
            statusSink.post("Voice preview failed. Try again.")
        }
    }

    func speakLatestAgentResponse() async {
        do {
            guard try await integrationManager.speakLatest() else {
                statusSink.post("No agent response to speak yet.")
                return
            }
            diagnostics.record(.ttsSubmitted)
            // Clears a stale "Could not speak…" / "No agent response…" left by an earlier call.
            statusSink.post(StatusSink.idleMessage)
        } catch {
            diagnostics.record(.ttsFailed)
            statusSink.post("Could not speak the latest agent response.")
        }
    }

    private func speakFocusedSessionReply(_ session: AgentSession) async {
        do {
            try await integrationManager.speakResponse(session.latestResponse)
            diagnostics.record(.ttsSubmitted)
            integrationDiagnosticsLog.append(
                stage: "replay-last",
                outcome: "focused-session",
                detail: "provider=\(session.id.provider.rawValue)"
            )
        } catch is CancellationError {
            // Stopped or superseded on purpose: not a failure.
        } catch {
            diagnostics.record(.ttsFailed)
            statusSink.post(error.localizedDescription)
        }
    }

    /// `true` when tier 2 handled the request (spoke, was cancelled, or failed loudly); `false`
    /// when the store had nothing, so the caller falls through to tier 3.
    private func speakGlobalLatestReply() async -> Bool {
        do {
            guard try await integrationManager.speakLatest() else { return false }
            diagnostics.record(.ttsSubmitted)
            integrationDiagnosticsLog.append(stage: "replay-last", outcome: "global-latest", detail: "")
            return true
        } catch is CancellationError {
            return true
        } catch {
            diagnostics.record(.ttsFailed)
            statusSink.post(error.localizedDescription)
            return true
        }
    }

    private func speakLastSpokenText() async {
        do {
            try await speechCoordinator.replayLast()
            diagnostics.record(.ttsReplayed)
            integrationDiagnosticsLog.append(stage: "replay-last", outcome: "last-spoken", detail: "")
        } catch is CancellationError {
            // Stopped or superseded on purpose: not a failure.
        } catch {
            diagnostics.record(.ttsFailed)
            statusSink.post(error.localizedDescription)
        }
    }
}
