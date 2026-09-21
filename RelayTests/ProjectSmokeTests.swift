import XCTest
@testable import Relay

final class ProjectSmokeTests: XCTestCase {
    func testAppModelStartsReady() async {
        let model = await MainActor.run { AppModel(runtime: .makeProduction()) }
        let status = await MainActor.run { model.statusText }
        XCTAssertEqual(status, "Ready")
    }

    /// CHARACTERIZATION (Reliability Wave 3, Task 1): pins the current shape of the production
    /// dependency graph `AppModel`'s production initializer builds, end to end, BEFORE that graph
    /// moves into a `RelayRuntime` composition root. Every assertion here must still hold,
    /// unchanged, once the graph is built by `RelayRuntime.makeProduction()` instead — this test
    /// is the regression guard for that move, not a test of any specific wiring detail.
    ///
    /// Deliberately never calls `startIntegrations()`/`stopIntegrations()`: those open the real,
    /// fixed-path Unix socket and must stay untouched by any test (see `AppModelIntegrationsTests`'s
    /// file-level doc comment).
    @MainActor
    func testProductionAppModelGraphConstructsAndFunctionsEndToEnd() async {
        let model = AppModel(runtime: .makeProduction())

        // Settings/permissions/login-item services all constructed and readable.
        XCTAssertEqual(model.statusText, "Ready")
        XCTAssertNotNil(model.settings)
        XCTAssertNotNil(model.permissionSnapshot)

        // STT/TTS registries and their downloaders are wired: Kokoro and PocketTTS can download a
        // model, Apple TTS never does (it has no model to download). On the STT side every
        // backend -- including Apple Speech, via `AppleSpeechModelManager`'s always-downloaded
        // one-model façade -- has a registered manager, so the settings UI can render all three
        // through the same collapsible-provider + nested-model-list code path.
        XCTAssertTrue(model.canDownloadTTSModel("kokoro"))
        XCTAssertTrue(model.canDownloadTTSModel("pocket-tts"))
        XCTAssertFalse(model.canDownloadTTSModel("apple-tts"))
        XCTAssertTrue(model.canDownloadSpeechModel("parakeet"))
        XCTAssertTrue(model.canDownloadSpeechModel("whisper"))
        XCTAssertTrue(model.canDownloadSpeechModel("apple-speech"))

        // Backend status refresh actually runs against the real registries and produces rows.
        await model.initialSpeechBackendRefresh?.value
        await model.initialTTSBackendRefresh?.value
        XCTAssertFalse(model.sttBackends.isEmpty)
        XCTAssertFalse(model.ttsBackends.isEmpty)

        // Diagnostics is live (real hotkey registration during init records `.eventTapRegistered`);
        // the separate integration-pipeline diagnostics log starts empty since nothing has run yet.
        XCTAssertTrue(model.diagnosticsEntries.contains { $0.event == .eventTapRegistered })
        XCTAssertTrue(model.integrationDiagnosticsEntries().isEmpty)
        XCTAssertNil(model.lastMicrophoneCaptureDiagnostics)

        // Session-intelligence graph (registry/focus/process inspector) is wired and empty at
        // rest; agent-integration status defaults to not-installed with no socket started.
        let sessions = await model.agentSessionSummaries()
        XCTAssertTrue(sessions.isEmpty)
        XCTAssertFalse(model.isSocketListening)
        XCTAssertEqual(model.integrationStatus(for: .claudeCode), .notInstalled)
        XCTAssertEqual(model.integrationStatus(for: .codex), .notInstalled)
        XCTAssertFalse(model.latestAgentResponseAvailable)

        // Hotkey registration ran during init (status is always one of these two outcomes).
        switch model.eventTapStatus {
        case .registered, .unavailable:
            break
        }
    }

    /// Task 11 composition-root test: `RelayRuntime.makeProduction()` registers Whisper in the
    /// STT registry AND its model manager, mirroring how the graph already registers Parakeet.
    /// Checked directly against `RelayRuntime`'s own properties (rather than only through
    /// `AppModel`) so this also pins the CONCRETE types, not just presence -- a swapped-in stub
    /// that merely satisfies the protocols would still pass an `AppModel`-only check.
    @MainActor
    func testMakeProductionRegistersWhisperBackendAndModelManager() {
        let runtime = RelayRuntime.makeProduction()

        XCTAssertTrue(runtime.speechIn.sttRegistry["whisper"] is WhisperBackend)
        XCTAssertTrue(runtime.speechIn.speechModelManagers["whisper"] is WhisperModelManager)
    }

    /// Composition-root test for the TTS side: `RelayRuntime.makeProduction()` registers a one-model
    /// `SpeechModelManaging` for each model-backed TTS backend (Kokoro, PocketTTS), and none for
    /// Apple, which downloads nothing. Pins the concrete manager types.
    @MainActor
    func testMakeProductionRegistersTTSModelManagers() {
        let runtime = RelayRuntime.makeProduction()

        XCTAssertTrue(runtime.speechOut.ttsModelManagers["kokoro"] is KokoroModelManager)
        XCTAssertTrue(runtime.speechOut.ttsModelManagers["pocket-tts"] is PocketTTSModelManager)
        XCTAssertNil(runtime.speechOut.ttsModelManagers["apple-tts"])
    }
}
