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

final class SpeechModelRowPresentationTests: XCTestCase {
    private func descriptor(detail: String? = "English only") -> SpeechModelDescriptor {
        SpeechModelDescriptor(id: "whisper-tiny", displayName: "Tiny", detail: detail, approximateDownloadBytes: 100)
    }

    func testActiveWhenSelectedAndDownloaded() {
        let status = SpeechModelStatus(descriptor: descriptor(), installState: .downloaded, isSelected: true, isLoaded: false)
        let presentation = SpeechModelRowPresentation.make(status: status)

        XCTAssertTrue(presentation.isActive)
        XCTAssertEqual(presentation.stateLabel, "\u{25CF} Active")
        XCTAssertFalse(presentation.showsRemove)
    }

    func testDownloadableWhenNotDownloaded() {
        let status = SpeechModelStatus(descriptor: descriptor(), installState: .notDownloaded, isSelected: false, isLoaded: false)
        let presentation = SpeechModelRowPresentation.make(status: status)

        XCTAssertFalse(presentation.isActive)
        XCTAssertEqual(presentation.stateLabel, "Download")
        XCTAssertFalse(presentation.showsRemove)
    }

    func testDownloadingShowsProgress() {
        let status = SpeechModelStatus(descriptor: descriptor(), installState: .downloading(progress: 0.42), isSelected: false, isLoaded: false)
        let presentation = SpeechModelRowPresentation.make(status: status)

        XCTAssertEqual(presentation.stateLabel, "Downloading 42%")
        XCTAssertFalse(presentation.isActive)
        XCTAssertFalse(presentation.showsRemove)
    }

    func testFailedState() {
        let status = SpeechModelStatus(descriptor: descriptor(), installState: .downloadFailed, isSelected: false, isLoaded: false)
        let presentation = SpeechModelRowPresentation.make(status: status)

        XCTAssertEqual(presentation.stateLabel, "Failed")
        XCTAssertFalse(presentation.isActive)
        XCTAssertFalse(presentation.showsRemove)
    }

    func testRemoveOfferedOnlyForInactiveDownloaded() {
        let inactiveDownloaded = SpeechModelStatus(descriptor: descriptor(), installState: .downloaded, isSelected: false, isLoaded: false)
        XCTAssertTrue(SpeechModelRowPresentation.make(status: inactiveDownloaded).showsRemove)

        let activeDownloaded = SpeechModelStatus(descriptor: descriptor(), installState: .downloaded, isSelected: true, isLoaded: false)
        XCTAssertFalse(SpeechModelRowPresentation.make(status: activeDownloaded).showsRemove)

        let notDownloaded = SpeechModelStatus(descriptor: descriptor(), installState: .notDownloaded, isSelected: false, isLoaded: false)
        XCTAssertFalse(SpeechModelRowPresentation.make(status: notDownloaded).showsRemove)

        let downloading = SpeechModelStatus(descriptor: descriptor(), installState: .downloading(progress: 0.1), isSelected: false, isLoaded: false)
        XCTAssertFalse(SpeechModelRowPresentation.make(status: downloading).showsRemove)
    }

    func testEnglishVsMultilingualLabel() {
        let english = SpeechModelStatus(descriptor: descriptor(detail: "English only"), installState: .notDownloaded, isSelected: false, isLoaded: false)
        XCTAssertEqual(SpeechModelRowPresentation.make(status: english).detailLabel, "English only")

        let multilingual = SpeechModelStatus(descriptor: descriptor(detail: "Multilingual"), installState: .notDownloaded, isSelected: false, isLoaded: false)
        XCTAssertEqual(SpeechModelRowPresentation.make(status: multilingual).detailLabel, "Multilingual")

        let missing = SpeechModelStatus(descriptor: descriptor(detail: nil), installState: .notDownloaded, isSelected: false, isLoaded: false)
        XCTAssertEqual(SpeechModelRowPresentation.make(status: missing).detailLabel, "")
    }
}

final class SpeechBackendModelDisplayModeTests: XCTestCase {
    /// Zero models means the async `refreshSpeechModels()` hasn't populated `speechModels` for
    /// this backend yet (or it genuinely has none, e.g. Apple Speech has no manager and never
    /// appears in `speechModels` at all) -- neither the aggregate Download button nor the nested
    /// per-model list should render, since showing the aggregate action here is exactly the
    /// "silently downloads the first model" bug this gating exists to prevent.
    func testZeroModelsShowsNeither() {
        XCTAssertEqual(SpeechBackendModelDisplayMode.make(modelCount: 0), .none)
    }

    /// Exactly one model (Parakeet's genuine case) shows the single aggregate Download row.
    func testOneModelShowsAggregateAction() {
        XCTAssertEqual(SpeechBackendModelDisplayMode.make(modelCount: 1), .aggregateAction)
    }

    /// More than one model (Whisper) shows the nested per-model list instead.
    func testMultipleModelsShowsNestedList() {
        XCTAssertEqual(SpeechBackendModelDisplayMode.make(modelCount: 2), .nestedList)
        XCTAssertEqual(SpeechBackendModelDisplayMode.make(modelCount: 5), .nestedList)
    }
}
