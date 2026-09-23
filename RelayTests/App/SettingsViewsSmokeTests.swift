import XCTest
import SwiftUI
@testable import Relay

final class SettingsViewsSmokeTests: XCTestCase {
    @MainActor
    func testAllSettingsTabViewsConstruct() {
        let model = AppModel(runtime: .testing())
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
        let model = AppModel(runtime: .testing(diagnostics: diagnosticsRecorder))

        _ = PermissionsSettingsView(model: model)

        XCTAssertEqual(model.lastMicrophoneCaptureDiagnostics?.frameCount, 0)
    }

    /// The menu bar shows and toggles auto-read state alongside the agent-response controls;
    /// this only guards that the view still constructs with the button title reflecting
    /// `model.settings.autoReadEnabled` in both states.
    @MainActor
    func testMenuBarContentViewConstructsInBothAutoReadStates() {
        let model = AppModel(runtime: .testing())
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
        SpeechModelDescriptor(id: "whisper-tiny", displayName: "Tiny", detail: detail)
    }

    func testActiveWhenSelectedAndDownloaded() {
        let status = SpeechModelStatus(descriptor: descriptor(), capabilities: [.download, .select, .remove], installState: .downloaded, isSelected: true)
        let presentation = SpeechModelRowPresentation.make(status: status)

        XCTAssertTrue(presentation.isActive)
        XCTAssertEqual(presentation.stateLabel, "\u{25CF} Active")
        XCTAssertTrue(presentation.canRemove)
    }

    func testDownloadableWhenNotDownloaded() {
        let status = SpeechModelStatus(descriptor: descriptor(), capabilities: [.download, .select, .remove], installState: .notDownloaded, isSelected: false)
        let presentation = SpeechModelRowPresentation.make(status: status)

        XCTAssertFalse(presentation.isActive)
        XCTAssertEqual(presentation.stateLabel, "Not downloaded")
        XCTAssertEqual(presentation.downloadTitle, "Download")
        XCTAssertTrue(presentation.canDownload)
        XCTAssertFalse(presentation.canSelect)
        XCTAssertFalse(presentation.canRemove)
    }

    func testDownloadingShowsProgress() {
        let status = SpeechModelStatus(descriptor: descriptor(), capabilities: [.download, .select, .remove], installState: .downloading(progress: 0.42), isSelected: false)
        let presentation = SpeechModelRowPresentation.make(status: status)

        XCTAssertEqual(presentation.stateLabel, "Downloading 42%")
        XCTAssertFalse(presentation.isActive)
        XCTAssertFalse(presentation.canRemove)
    }

    func testFailedState() {
        let status = SpeechModelStatus(descriptor: descriptor(), capabilities: [.download, .select, .remove], installState: .downloadFailed, isSelected: false)
        let presentation = SpeechModelRowPresentation.make(status: status)

        XCTAssertEqual(presentation.stateLabel, "Download failed")
        XCTAssertEqual(presentation.downloadTitle, "Retry")
        XCTAssertTrue(presentation.canDownload)
        XCTAssertFalse(presentation.isActive)
        XCTAssertFalse(presentation.canRemove)
    }

    func testRemoveOfferedOnlyForInactiveDownloaded() {
        let inactiveDownloaded = SpeechModelStatus(descriptor: descriptor(), capabilities: [.download, .select, .remove], installState: .downloaded, isSelected: false)
        XCTAssertTrue(SpeechModelRowPresentation.make(status: inactiveDownloaded).canRemove)

        let activeDownloaded = SpeechModelStatus(descriptor: descriptor(), capabilities: [.download, .select, .remove], installState: .downloaded, isSelected: true)
        XCTAssertTrue(SpeechModelRowPresentation.make(status: activeDownloaded).canRemove)

        let notDownloaded = SpeechModelStatus(descriptor: descriptor(), capabilities: [.download, .select, .remove], installState: .notDownloaded, isSelected: false)
        XCTAssertFalse(SpeechModelRowPresentation.make(status: notDownloaded).canRemove)

        let downloading = SpeechModelStatus(descriptor: descriptor(), capabilities: [.download, .select, .remove], installState: .downloading(progress: 0.1), isSelected: false)
        XCTAssertFalse(SpeechModelRowPresentation.make(status: downloading).canRemove)
    }

    func testEnglishVsMultilingualLabel() {
        let english = SpeechModelStatus(descriptor: descriptor(detail: "English only"), capabilities: [.download, .select, .remove], installState: .notDownloaded, isSelected: false)
        XCTAssertEqual(SpeechModelRowPresentation.make(status: english).detail, "English only")

        let multilingual = SpeechModelStatus(descriptor: descriptor(detail: "Multilingual"), capabilities: [.download, .select, .remove], installState: .notDownloaded, isSelected: false)
        XCTAssertEqual(SpeechModelRowPresentation.make(status: multilingual).detail, "Multilingual")

        let missing = SpeechModelStatus(descriptor: descriptor(detail: nil), capabilities: [.download, .select, .remove], installState: .notDownloaded, isSelected: false)
        XCTAssertEqual(SpeechModelRowPresentation.make(status: missing).detail, "")
    }

    /// A model can be reported selected+downloaded by its manager (e.g.
    /// `AppleSpeechModelManager`'s always-downloaded façade) even while the OWNING backend isn't
    /// actually usable (`STTBackendStatus.State` other than `.ready`, e.g. `.unsupported` on a Mac
    /// where Apple Speech isn't available). `backendReady: false` must suppress "Active" in that
    /// case -- a model can never show as in-use on a backend that can't run it -- falling back to
    /// the same "Downloaded" label an inactive-but-present model gets.
    func testNotActiveWhenBackendIsNotReadyEvenIfSelectedAndDownloaded() {
        let status = SpeechModelStatus(descriptor: descriptor(), capabilities: [.download, .select, .remove], installState: .downloaded, isSelected: true)
        let presentation = SpeechModelRowPresentation.make(status: status, backendReady: false)

        XCTAssertFalse(presentation.isActive)
        XCTAssertEqual(presentation.stateLabel, "Downloaded")
    }

    func testDownloadedAlternativeCanBeSelectedWhileBackendIsNotReady() {
        let status = SpeechModelStatus(
            descriptor: descriptor(),
            capabilities: [.download, .select, .remove],
            installState: .downloaded,
            isSelected: false
        )

        let presentation = SpeechModelRowPresentation.make(status: status, backendReady: false)

        XCTAssertTrue(presentation.canSelect)
        XCTAssertFalse(presentation.isActive)
    }

    func testUnsupportedActionsRemainRepresentedButDisabled() {
        let status = SpeechModelStatus(
            descriptor: descriptor(),
            capabilities: [.select],
            installState: .downloaded,
            isSelected: true
        )
        let presentation = SpeechModelRowPresentation.make(status: status)

        XCTAssertEqual(presentation.downloadTitle, "Download")
        XCTAssertFalse(presentation.canDownload)
        XCTAssertFalse(presentation.canSelect)
        XCTAssertFalse(presentation.canRemove)
        XCTAssertNotNil(presentation.downloadHelp)
        XCTAssertNotNil(presentation.removeHelp)
    }
}

final class SpeechVoiceRowPresentationTests: XCTestCase {
    func testSelectAndTestRemainPresentForActiveAndInactiveVoices() {
        let active = SpeechVoiceRowPresentation(isActive: true)
        XCTAssertEqual(active.selectTitle, "Select")
        XCTAssertEqual(active.testTitle, "Test")
        XCTAssertFalse(active.canSelect)

        let inactive = SpeechVoiceRowPresentation(isActive: false)
        XCTAssertTrue(inactive.canSelect)
    }
}

final class CollapsedProviderSubtitleTests: XCTestCase {
    private func status(id: String, displayName: String, isSelected: Bool, installState: SpeechModelInstallState) -> SpeechModelStatus {
        SpeechModelStatus(
            descriptor: SpeechModelDescriptor(id: id, displayName: displayName, detail: nil),
            capabilities: [.download, .select, .remove],
            installState: installState,
            isSelected: isSelected
        )
    }

    /// A downloaded, selected model's display name is shown in place of the status label -- this
    /// is what lets a collapsed provider row surface which model is active without expanding it.
    func testShowsActiveModelDisplayNameWhenOneIsSelectedAndDownloaded() {
        let models = [
            status(id: "whisper-tiny", displayName: "Tiny", isSelected: false, installState: .notDownloaded),
            status(id: "whisper-base", displayName: "Base (English)", isSelected: true, installState: .downloaded),
        ]

        XCTAssertEqual(CollapsedProviderSubtitle.make(models: models, statusLabel: "Ready"), "Base (English)")
    }

    /// Selected but not yet downloaded doesn't count as active -- falls back to the status label,
    /// same as having no models at all.
    func testFallsBackToStatusLabelWhenSelectedModelIsNotDownloaded() {
        let models = [status(id: "whisper-base", displayName: "Base (English)", isSelected: true, installState: .notDownloaded)]

        XCTAssertEqual(CollapsedProviderSubtitle.make(models: models, statusLabel: "Model not downloaded"), "Model not downloaded")
    }

    func testFallsBackToStatusLabelWhenNoModelIsSelected() {
        let models = [status(id: "whisper-base", displayName: "Base (English)", isSelected: false, installState: .downloaded)]

        XCTAssertEqual(CollapsedProviderSubtitle.make(models: models, statusLabel: "Ready"), "Ready")
    }

    func testFallsBackToStatusLabelWhenModelsIsEmpty() {
        XCTAssertEqual(CollapsedProviderSubtitle.make(models: [], statusLabel: "Ready"), "Ready")
    }

    /// Same scenario as `SpeechModelRowPresentationTests
    /// .testNotActiveWhenBackendIsNotReadyEvenIfSelectedAndDownloaded`, one level up: a
    /// downloaded+selected model on a backend that isn't ready (e.g. Apple Speech reported
    /// `.unsupported` by `AppleSpeechBackend.availability()`, even though
    /// `AppleSpeechModelManager` always reports its one model downloaded+selected) must show the
    /// real status label, not the model's name -- the collapsed subtitle must never claim a model
    /// is in use on a backend that can't run it.
    func testFallsBackToStatusLabelWhenBackendIsNotReady() {
        let models = [status(id: "apple-on-device", displayName: "On-device", isSelected: true, installState: .downloaded)]

        XCTAssertEqual(
            CollapsedProviderSubtitle.make(models: models, statusLabel: "Unsupported on this Mac", backendReady: false),
            "Unsupported on this Mac"
        )
    }
}
