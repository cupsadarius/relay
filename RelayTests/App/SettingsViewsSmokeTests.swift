import XCTest
import SwiftUI
@testable import Relay

final class SettingsViewsSmokeTests: XCTestCase {
    @MainActor
    func testAllSettingsTabViewsConstruct() {
        let model = AppModel(runtime: .makeProduction())
        _ = SettingsView(model: model)
        _ = GeneralSettingsView(model: model)
        _ = KeybindsSettingsView(model: model)
        _ = DictationSettingsView(model: model)
        _ = TTSSettingsView(model: model)
        _ = PermissionsSettingsView(model: model)
        _ = IntegrationsSettingsView(model: model)
    }

    /// The Security tab's zero-frame hint only renders when `lastMicrophoneCaptureDiagnostics`
    /// is populated with `frameCount == 0` (the stale post-rebuild microphone grant case); this
    /// guards that path still constructs alongside the non-zero and nil cases already covered by
    /// `testAllSettingsTabViewsConstruct`.
    @MainActor
    func testPermissionsSettingsViewConstructsWithZeroFrameCaptureDiagnostics() {
        let diagnosticsRecorder = DiagnosticsRecorder(capacity: 10)
        diagnosticsRecorder.recordMicrophoneCapture(
            MicrophoneCaptureDiagnostics(inputSampleRate: 48_000, frameCount: 0, capturedAt: Date())
        )
        let model = AppModel(
            settingsStore: SettingsStore(),
            selectionReader: SelectionReader(accessibility: AccessibilityService(), clipboard: ClipboardService()),
            preprocessor: RulesSpeechPreprocessor(),
            speechCoordinator: SpeechCoordinator(
                router: TTSRouter(backends: [:], backendOrder: { [] }),
                options: { TTSOptions() },
                overlay: ActivityOverlayModel()
            ),
            hotkeyManager: GlobalHotkeyManager(diagnostics: diagnosticsRecorder),
            diagnostics: diagnosticsRecorder
        )

        _ = PermissionsSettingsView(model: model)

        XCTAssertEqual(model.lastMicrophoneCaptureDiagnostics?.frameCount, 0)
    }

    /// The menu bar shows and toggles auto-read state alongside the agent-response controls;
    /// this only guards that the view still constructs with the button title reflecting
    /// `model.settings.autoReadEnabled` in both states. `AppModel(runtime:)` loads the real,
    /// persisted settings store, so this reads whatever `autoReadEnabled` already is rather than assuming
    /// the shipped default, and restores it afterward so the on-disk value isn't left flipped
    /// for whichever run reuses this store next.
    @MainActor
    func testMenuBarContentViewConstructsInBothAutoReadStates() {
        let model = AppModel(runtime: .makeProduction())
        let initial = model.settings.autoReadEnabled
        _ = MenuBarContentView(model: model)

        model.toggleAutoRead()

        XCTAssertEqual(model.settings.autoReadEnabled, !initial)
        _ = MenuBarContentView(model: model)

        model.toggleAutoRead()
        XCTAssertEqual(model.settings.autoReadEnabled, initial)
    }
}
