import XCTest
@testable import Relay

@MainActor
final class AppModelTests: XCTestCase {
    func testChangingActivityOverlayStylePersistsImmediately() {
        let store = FakeSettingsStore(settings: .defaults)
        let model = makeModel(store: store)

        model.setActivityOverlayStyle(.minimal)

        XCTAssertEqual(model.settings.activityOverlayStyle, .minimal)
        XCTAssertEqual(store.saved.last?.activityOverlayStyle, .minimal)
    }

    func testOverlayLifecycleReachesInjectedPresenter() {
        let presenter = FakeOverlayPresenter()
        let overlayModel = ActivityOverlayModel()
        let model = makeModel(overlayModel: overlayModel, overlayPresenter: presenter)
        let sessionID = UUID()

        overlayModel.begin(sessionID: sessionID)
        overlayModel.listen(sessionID: sessionID, startedAt: .now)

        XCTAssertEqual(presenter.states.last?.sessionID, sessionID)
        withExtendedLifetime(model) {}
    }

    func testActiveOverlayStyleChangeUpdatesPresenterImmediately() {
        let presenter = FakeOverlayPresenter()
        let overlayModel = ActivityOverlayModel()
        let model = makeModel(overlayModel: overlayModel, overlayPresenter: presenter)
        let sessionID = UUID()
        overlayModel.begin(sessionID: sessionID)
        overlayModel.listen(sessionID: sessionID, startedAt: .now)

        model.setActivityOverlayStyle(.minimal)

        XCTAssertEqual(presenter.styles.last, .minimal)
        withExtendedLifetime(model) {}
    }

    func testSubsequentOverlayTransitionUsesNewlyPersistedStyle() {
        let presenter = FakeOverlayPresenter()
        let overlayModel = ActivityOverlayModel()
        let model = makeModel(overlayModel: overlayModel, overlayPresenter: presenter)
        let sessionID = UUID()

        model.setActivityOverlayStyle(.minimal)
        overlayModel.begin(sessionID: sessionID)
        overlayModel.listen(sessionID: sessionID, startedAt: .now)

        XCTAssertEqual(presenter.styles.last, .minimal)
        withExtendedLifetime(model) {}
    }

    func testReadSelectionPressedPreprocessesAndSpeaksUserRequest() async {
        let selection = FakeSelectionReader(text: "Intro\n```swift\nsecret()\n```\nEnd")
        let speech = FakeSpeechCoordinator()
        let hotkeys = FakeHotkeyManager()
        let model = makeModel(selection: selection, speech: speech, hotkeys: hotkeys)

        hotkeys.send(.readSelection, .pressed)
        await Task.yield()

        XCTAssertEqual(speech.requests, [
            SpeechRequest(
                text: "Intro There is a code block on screen. Please read it there. End",
                source: .selection,
                mode: .userRequested,
                sessionID: nil
            ),
        ])
        XCTAssertEqual(model.statusText, "Speaking selected text")
        XCTAssertEqual(model.diagnosticsEntries.first?.event, .ttsSubmitted)
    }

    func testReadSelectionReleasedDoesNothing() async {
        let selection = FakeSelectionReader(text: "selected")
        let speech = FakeSpeechCoordinator()
        let hotkeys = FakeHotkeyManager()
        let model = makeModel(selection: selection, speech: speech, hotkeys: hotkeys)

        hotkeys.send(.readSelection, .released)
        await Task.yield()

        XCTAssertTrue(speech.requests.isEmpty)
        XCTAssertEqual(selection.readCount, 0)
        XCTAssertEqual(model.diagnosticsCounters.dispatched, 0)
        XCTAssertFalse(model.diagnosticsEntries.contains { if case .actionDispatched = $0.event { true } else { false } })
        withExtendedLifetime(model) {}
    }

    func testStopAndReplayOnlyActWhenPressed() async {
        let speech = FakeSpeechCoordinator()
        let hotkeys = FakeHotkeyManager()
        let model = makeModel(speech: speech, hotkeys: hotkeys)

        hotkeys.send(.stopSpeech, .released)
        hotkeys.send(.replayLast, .released)
        hotkeys.send(.stopSpeech, .pressed)
        hotkeys.send(.replayLast, .pressed)
        await Task.yield()

        XCTAssertEqual(speech.stopCount, 1)
        XCTAssertEqual(speech.replayCount, 1)
        withExtendedLifetime(model) {}
    }

    func testReplayFailureIsLoggedAsTTSFailure() async {
        let speech = FakeSpeechCoordinator(replayError: TestError.saveFailed)
        let hotkeys = FakeHotkeyManager()
        let model = makeModel(speech: speech, hotkeys: hotkeys)
        hotkeys.send(.replayLast, .pressed)
        await Task.yield()
        XCTAssertEqual(model.diagnosticsEntries.first?.event, .ttsFailed)
    }

    func testHoldToTalkStartsOnPressAndFinishesOnRelease() async {
        let hotkeys = FakeHotkeyManager()
        let dictation = FakeDictationCoordinator()
        let model = makeModel(hotkeys: hotkeys, dictation: dictation)

        hotkeys.send(.dictate, .pressed)
        hotkeys.send(.dictate, .released)
        await Task.yield()

        XCTAssertEqual(model.dictationPhase, .released)
        XCTAssertEqual(dictation.events, ["start", "finish"])
    }

    func testToggleDictationAlternatesOnPressAndIgnoresRelease() async {
        let hotkeys = FakeHotkeyManager()
        let dictation = FakeDictationCoordinator()
        let model = makeModel(hotkeys: hotkeys, dictation: dictation)
        model.setDictationMode(.toggle)

        hotkeys.send(.dictate, .pressed)
        hotkeys.send(.dictate, .released)
        hotkeys.send(.dictate, .pressed)
        await Task.yield()

        XCTAssertEqual(dictation.events, ["start", "finish"])
    }

    func testHoldToTalkQueuesReleaseUntilBlockedStartCompletes() async {
        let hotkeys = FakeHotkeyManager()
        let dictation = FakeDictationCoordinator(blockStart: true)
        let model = makeModel(hotkeys: hotkeys, dictation: dictation)

        hotkeys.send(.dictate, .pressed)
        while dictation.events != ["start"] { await Task.yield() }
        hotkeys.send(.dictate, .released)
        await Task.yield()
        XCTAssertEqual(dictation.events, ["start"])

        dictation.resumeStart()
        while dictation.events != ["start", "finish"] { await Task.yield() }
        withExtendedLifetime(model) {}
    }

    func testToggleQueuesNewPressUntilBlockedFinishCompletes() async {
        let hotkeys = FakeHotkeyManager()
        let dictation = FakeDictationCoordinator(blockFinish: true)
        let model = makeModel(hotkeys: hotkeys, dictation: dictation)
        model.setDictationMode(.toggle)

        hotkeys.send(.dictate, .pressed)
        while dictation.events != ["start"] { await Task.yield() }
        hotkeys.send(.dictate, .pressed)
        while dictation.events != ["start", "finish"] { await Task.yield() }
        hotkeys.send(.dictate, .pressed)
        await Task.yield()
        XCTAssertEqual(dictation.events, ["start", "finish"])

        dictation.resumeFinish()
        while dictation.events != ["start", "finish", "start"] { await Task.yield() }
    }

    func testToggleAutoReadPersistsAndReregistersImmediately() {
        let store = FakeSettingsStore(settings: .defaults)
        let hotkeys = FakeHotkeyManager()
        let model = makeModel(store: store, hotkeys: hotkeys)

        hotkeys.send(.toggleAutoRead, .pressed)

        XCTAssertFalse(model.settings.autoReadEnabled)
        XCTAssertEqual(store.saved.map(\.autoReadEnabled), [false])
        XCTAssertEqual(hotkeys.registrations.count, 2)
        XCTAssertEqual(hotkeys.registrations.last?.autoReadEnabled, false)
    }

    func testChangingASettingPersistsAndReregistersImmediately() {
        let store = FakeSettingsStore(settings: .defaults)
        let hotkeys = FakeHotkeyManager()
        let model = makeModel(store: store, hotkeys: hotkeys)
        let replacement = HotkeyDefinition.chord(keyCode: 49, modifiers: [.command])

        model.setHotkey(replacement, for: .readSelection)

        XCTAssertEqual(model.settings.hotkeys[.readSelection], replacement)
        XCTAssertEqual(store.saved.last?.hotkeys[.readSelection], replacement)
        XCTAssertEqual(hotkeys.registrations.last?.hotkeys[.readSelection], replacement)
    }

    func testDuplicateHotkeyIsRejectedWithoutPersistenceOrReregistration() {
        let store = FakeSettingsStore(settings: .defaults)
        let hotkeys = FakeHotkeyManager()
        let model = makeModel(store: store, hotkeys: hotkeys)
        let existing = try! XCTUnwrap(model.settings.hotkeys[.replayLast])

        model.setHotkey(existing, for: .readSelection)

        XCTAssertEqual(model.settings, .defaults)
        XCTAssertTrue(store.saved.isEmpty)
        XCTAssertEqual(hotkeys.registrations.count, 1)
    }

    func testDuplicateHotkeyRejectionSurfacesActionableConflictMessage() {
        let hotkeys = FakeHotkeyManager()
        let model = makeModel(hotkeys: hotkeys)
        let existing = try! XCTUnwrap(model.settings.hotkeys[.replayLast])

        model.setHotkey(existing, for: .readSelection)

        let expected = "Read Selection conflicts with Replay Last. Choose a different shortcut."
        XCTAssertEqual(model.statusText, expected)
        XCTAssertEqual(model.hotkeyConflictMessage, expected)
    }

    func testModifierOnlyAndDoubleTapModifierConflictIsRejected() {
        let store = FakeSettingsStore(settings: .defaults)
        let hotkeys = FakeHotkeyManager()
        let model = makeModel(store: store, hotkeys: hotkeys)

        model.setHotkey(.doubleTapModifier(.function), for: .readSelection)

        XCTAssertEqual(model.settings, .defaults)
        XCTAssertTrue(store.saved.isEmpty)
        XCTAssertEqual(hotkeys.registrations.count, 1)
    }

    func testRegistrationFailureSurfacesActionableStatus() {
        let hotkeys = FakeHotkeyManager(
            status: .unavailable("Enable Accessibility permission, then reopen Relay.")
        )

        let model = makeModel(hotkeys: hotkeys)

        XCTAssertEqual(model.statusText, "Enable Accessibility permission, then reopen Relay.")
    }

    func testRecheckRetriesHotkeyRegistrationAndRefreshesPermissionSnapshot() {
        let hotkeys = FakeHotkeyManager()
        let permissions = FakePermissionService(snapshot: .init(inputMonitoringGranted: false, accessibilityGranted: false))
        let model = makeModel(hotkeys: hotkeys, permissions: permissions)

        model.recheckDiagnostics()

        XCTAssertEqual(permissions.snapshotCount, 2)
        XCTAssertEqual(hotkeys.registrations.count, 2)
        XCTAssertEqual(model.permissionSnapshot.inputMonitoringGranted, false)
    }

    func testRecheckRefreshesObservableMicrophonePermissionAfterExternalChange() {
        let microphone = FakeMicrophonePermissionStatus(granted: false)
        let model = makeModel(microphone: microphone)

        XCTAssertFalse(model.microphonePermissionGranted)
        microphone.grantedValue = true
        model.recheckDiagnostics()

        XCTAssertTrue(model.microphonePermissionGranted)
        microphone.grantedValue = false
        model.recheckDiagnostics()
        XCTAssertFalse(model.microphonePermissionGranted)
    }

    func testRequestMicrophonePermissionRefreshesObservableState() async {
        let microphone = FakeMicrophonePermissionStatus(granted: false, requestResult: true)
        let model = makeModel(microphone: microphone)

        await model.requestMicrophonePermission()

        XCTAssertEqual(microphone.requestCount, 1)
        XCTAssertTrue(model.microphonePermissionGranted)
        XCTAssertEqual(model.statusText, "Microphone permission granted")
    }

    func testOpenPrivacySettingsDelegatesToInjectedOpener() {
        let opener = FakePrivacySettingsOpener()
        let model = makeModel(opener: opener)

        model.openPrivacySettings(.microphone)
        model.openPrivacySettings(.accessibility)
        model.openPrivacySettings(.inputMonitoring)

        XCTAssertEqual(opener.opened, [.microphone, .accessibility, .inputMonitoring])
    }

    func testSaveFailureStillAppliesHotkeyImmediatelyAndSurfacesError() {
        let store = FakeSettingsStore(settings: .defaults, saveError: TestError.saveFailed)
        let hotkeys = FakeHotkeyManager()
        let model = makeModel(store: store, hotkeys: hotkeys)
        let replacement = HotkeyDefinition.chord(keyCode: 49, modifiers: [.command])

        model.setHotkey(replacement, for: .readSelection)

        XCTAssertEqual(hotkeys.registrations.count, 2)
        XCTAssertEqual(hotkeys.registrations.last?.hotkeys[.readSelection], replacement)
        XCTAssertTrue(model.statusText.contains("Could not save settings"))
    }

    func testSpeechBackendStatusesDeriveFromSettingsOrderEnabledFirstThenDisabled() async {
        var settings = AppSettings.defaults
        settings.sttBackendOrder = ["b", "a"]
        let store = FakeSettingsStore(settings: settings)
        let a = FakeSTTBackend(id: "a", displayName: "A")
        let b = FakeSTTBackend(id: "b", displayName: "B")
        let c = FakeSTTBackend(id: "c", displayName: "C")
        let model = makeModel(store: store, sttRegistry: ["a": a, "b": b, "c": c])
        await model.initialSpeechBackendRefresh?.value

        XCTAssertEqual(model.sttBackends.map(\.id), ["b", "a", "c"])
        XCTAssertEqual(model.sttBackends.map(\.isEnabled), [true, true, false])
        XCTAssertEqual(model.sttBackends.map(\.position), [0, 1, Int.max])
        XCTAssertEqual(model.sttBackends.map(\.state), [.ready, .ready, .ready])
    }

    func testEnablingBackendAppendsItToOrderAndPersists() async {
        var settings = AppSettings.defaults
        settings.sttBackendOrder = ["a"]
        let store = FakeSettingsStore(settings: settings)
        let a = FakeSTTBackend(id: "a", displayName: "A")
        let b = FakeSTTBackend(id: "b", displayName: "B")
        let model = makeModel(store: store, sttRegistry: ["a": a, "b": b])
        await model.initialSpeechBackendRefresh?.value

        model.setSTTBackendEnabled("b", true)

        XCTAssertEqual(model.settings.sttBackendOrder, ["a", "b"])
        XCTAssertEqual(store.saved.last?.sttBackendOrder, ["a", "b"])
        XCTAssertEqual(model.sttBackends.first { $0.id == "b" }?.isEnabled, true)
        XCTAssertEqual(model.sttBackends.first { $0.id == "b" }?.position, 1)
    }

    func testMovingEnabledBackendReordersSettings() async {
        var settings = AppSettings.defaults
        settings.sttBackendOrder = ["a", "b"]
        let store = FakeSettingsStore(settings: settings)
        let a = FakeSTTBackend(id: "a", displayName: "A")
        let b = FakeSTTBackend(id: "b", displayName: "B")
        let model = makeModel(store: store, sttRegistry: ["a": a, "b": b])
        await model.initialSpeechBackendRefresh?.value

        model.moveSTTBackend("b", up: true)

        XCTAssertEqual(model.settings.sttBackendOrder, ["b", "a"])
        XCTAssertEqual(model.sttBackends.map(\.id), ["b", "a"])
    }

    func testCannotDisableTheLastEnabledBackend() async {
        var settings = AppSettings.defaults
        settings.sttBackendOrder = ["a"]
        let store = FakeSettingsStore(settings: settings)
        let a = FakeSTTBackend(id: "a", displayName: "A")
        let model = makeModel(store: store, sttRegistry: ["a": a])
        await model.initialSpeechBackendRefresh?.value

        model.setSTTBackendEnabled("a", false)

        XCTAssertEqual(model.settings.sttBackendOrder, ["a"])
        XCTAssertTrue(store.saved.isEmpty)
        XCTAssertEqual(model.statusText, "At least one speech recognition backend must stay enabled.")
    }

    func testUnknownIDsInSettingsOrderAreIgnoredAndDroppedWhenPersisted() async {
        var settings = AppSettings.defaults
        settings.sttBackendOrder = ["ghost", "a"]
        let store = FakeSettingsStore(settings: settings)
        let a = FakeSTTBackend(id: "a", displayName: "A")
        let b = FakeSTTBackend(id: "b", displayName: "B")
        let model = makeModel(store: store, sttRegistry: ["a": a, "b": b])
        await model.initialSpeechBackendRefresh?.value

        // "ghost" isn't in the registry, so "a" is treated as the first (and only) known
        // enabled backend, not the second.
        XCTAssertEqual(model.sttBackends.map(\.id), ["a", "b"])
        XCTAssertEqual(model.sttBackends.first { $0.id == "a" }?.position, 0)

        model.setSTTBackendEnabled("a", false)
        XCTAssertEqual(model.statusText, "At least one speech recognition backend must stay enabled.")

        model.setSTTBackendEnabled("b", true)

        XCTAssertEqual(model.settings.sttBackendOrder, ["a", "b"])
        XCTAssertEqual(store.saved.last?.sttBackendOrder, ["a", "b"])
    }

    func testDownloadSpeechModelReportsProgressThenBecomesReady() async {
        var settings = AppSettings.defaults
        settings.sttBackendOrder = ["parakeet"]
        let store = FakeSettingsStore(settings: settings)
        let diagnostics = DiagnosticsRecorder(capacity: 10)
        let parakeet = FakeSTTBackend(id: "parakeet", displayName: "Parakeet", availability: .modelNotDownloaded)
        let downloader = FakeSpeechModelDownloader()
        await downloader.setProgressToReport([0.5])
        await downloader.setShouldBlock(true)
        let model = makeModel(
            store: store,
            sttRegistry: ["parakeet": parakeet],
            speechModelDownloaders: ["parakeet": downloader],
            diagnostics: diagnostics
        )
        await model.initialSpeechBackendRefresh?.value

        let downloadTask = Task { await model.downloadSpeechModel("parakeet") }
        await waitUntil {
            model.sttBackends.first(where: { $0.id == "parakeet" })?.state == .downloading(progress: 0.5)
        }

        await parakeet.setAvailability(.available)
        await downloader.resume()
        await downloadTask.value

        XCTAssertEqual(model.sttBackends.first(where: { $0.id == "parakeet" })?.state, .ready)
        XCTAssertEqual(model.diagnosticsEntries.map(\.event), [
            .speechModelDownloadFinished(backendID: "parakeet"),
            .speechModelDownloadStarted(backendID: "parakeet"),
        ])
        XCTAssertNil(model.speechBackendMessage)
    }

    func testDownloadSpeechModelFailureSetsFailedStateFixedStatusTextAndDiagnostics() async {
        var settings = AppSettings.defaults
        settings.sttBackendOrder = ["parakeet"]
        let store = FakeSettingsStore(settings: settings)
        let diagnostics = DiagnosticsRecorder(capacity: 10)
        let parakeet = FakeSTTBackend(id: "parakeet", displayName: "Parakeet", availability: .modelNotDownloaded)
        let downloader = FakeSpeechModelDownloader()
        await downloader.setErrorToThrow(TestError.saveFailed)
        let model = makeModel(
            store: store,
            sttRegistry: ["parakeet": parakeet],
            speechModelDownloaders: ["parakeet": downloader],
            diagnostics: diagnostics
        )
        await model.initialSpeechBackendRefresh?.value

        await model.downloadSpeechModel("parakeet")

        XCTAssertEqual(model.sttBackends.first(where: { $0.id == "parakeet" })?.state, .downloadFailed)
        let expectedMessage = "Parakeet model download failed. Check your connection and try again."
        XCTAssertEqual(model.statusText, expectedMessage)
        XCTAssertEqual(model.speechBackendMessage, expectedMessage)
        XCTAssertEqual(model.diagnosticsEntries.map(\.event), [
            .speechModelDownloadFailed(backendID: "parakeet"),
            .speechModelDownloadStarted(backendID: "parakeet"),
        ])
    }

    func testDownloadCanBeRetriedAfterAFailureWithoutGettingStuck() async {
        var settings = AppSettings.defaults
        settings.sttBackendOrder = ["parakeet"]
        let store = FakeSettingsStore(settings: settings)
        let parakeet = FakeSTTBackend(id: "parakeet", displayName: "Parakeet", availability: .modelNotDownloaded)
        let downloader = FakeSpeechModelDownloader()
        await downloader.setErrorToThrow(TestError.saveFailed)
        let model = makeModel(store: store, sttRegistry: ["parakeet": parakeet], speechModelDownloaders: ["parakeet": downloader])
        await model.initialSpeechBackendRefresh?.value

        await model.downloadSpeechModel("parakeet")
        XCTAssertEqual(model.sttBackends.first?.state, .downloadFailed)

        await downloader.setErrorToThrow(nil)
        await parakeet.setAvailability(.available)
        await model.downloadSpeechModel("parakeet")

        XCTAssertEqual(model.sttBackends.first?.state, .ready)
        XCTAssertNil(model.speechBackendMessage)
        let callCount = await downloader.callCount
        XCTAssertEqual(callCount, 2)
    }

    func testSecondDownloadClickWhileDownloadingIsIgnored() async {
        var settings = AppSettings.defaults
        settings.sttBackendOrder = ["parakeet"]
        let store = FakeSettingsStore(settings: settings)
        let parakeet = FakeSTTBackend(id: "parakeet", displayName: "Parakeet", availability: .modelNotDownloaded)
        let downloader = FakeSpeechModelDownloader()
        await downloader.setShouldBlock(true)
        let model = makeModel(
            store: store,
            sttRegistry: ["parakeet": parakeet],
            speechModelDownloaders: ["parakeet": downloader]
        )
        await model.initialSpeechBackendRefresh?.value

        let firstTask = Task { await model.downloadSpeechModel("parakeet") }
        await waitUntil { await downloader.callCount > 0 }

        await model.downloadSpeechModel("parakeet")

        let callCountAfterSecondClick = await downloader.callCount
        XCTAssertEqual(callCountAfterSecondClick, 1)

        await downloader.resume()
        await firstTask.value
    }

    func testDownloadInsertsMissingRowWhenNoStatusExistsYet() async {
        var settings = AppSettings.defaults
        settings.sttBackendOrder = ["parakeet"]
        let store = FakeSettingsStore(settings: settings)
        let parakeet = FakeSTTBackend(id: "parakeet", displayName: "Parakeet", availability: .modelNotDownloaded)
        let downloader = FakeSpeechModelDownloader()
        await downloader.setShouldBlock(true)
        let model = makeModel(
            store: store,
            sttRegistry: ["parakeet": parakeet],
            speechModelDownloaders: ["parakeet": downloader]
        )
        await model.initialSpeechBackendRefresh?.value
        model.sttBackends = [] // simulate a Download click before any status row exists

        let downloadTask = Task { await model.downloadSpeechModel("parakeet") }
        await waitUntil { model.sttBackends.first(where: { $0.id == "parakeet" }) != nil }

        let row = model.sttBackends.first(where: { $0.id == "parakeet" })
        XCTAssertEqual(row?.displayName, "Parakeet")
        XCTAssertEqual(row?.state, .downloading(progress: 0))

        await downloader.resume()
        await downloadTask.value
    }

    func testConcurrentRefreshDuringADownloadDoesNotClobberDownloadingState() async {
        var settings = AppSettings.defaults
        settings.sttBackendOrder = ["parakeet"]
        let store = FakeSettingsStore(settings: settings)
        let parakeet = FakeSTTBackend(id: "parakeet", displayName: "Parakeet", availability: .modelNotDownloaded)
        let downloader = FakeSpeechModelDownloader()
        await downloader.setShouldBlock(true)
        let model = makeModel(
            store: store,
            sttRegistry: ["parakeet": parakeet],
            speechModelDownloaders: ["parakeet": downloader]
        )
        await model.initialSpeechBackendRefresh?.value

        // Block availability() so a refresh started now is still awaiting mid-flight.
        await parakeet.setShouldBlockAvailability(true)
        let refreshTask = Task { await model.refreshSpeechBackendStatuses() }
        await waitUntil { await parakeet.availabilityCallCount > 0 }

        // A Download starts while that refresh is still suspended inside availability().
        let downloadTask = Task { await model.downloadSpeechModel("parakeet") }
        await waitUntil {
            model.sttBackends.first(where: { $0.id == "parakeet" })?.state == .downloading(progress: 0)
        }

        await parakeet.resumeAvailability()
        await refreshTask.value

        // The refresh's now-stale "model not downloaded" snapshot must not have clobbered the
        // download that started while it was in flight.
        XCTAssertEqual(model.sttBackends.first(where: { $0.id == "parakeet" })?.state, .downloading(progress: 0))

        await parakeet.setShouldBlockAvailability(false)
        await parakeet.setAvailability(.available)
        await downloader.resume()
        await downloadTask.value

        XCTAssertEqual(model.sttBackends.first(where: { $0.id == "parakeet" })?.state, .ready)
    }

    func testLateProgressCallbackAfterCompletionDoesNotChangeReadyState() async {
        var settings = AppSettings.defaults
        settings.sttBackendOrder = ["parakeet"]
        let store = FakeSettingsStore(settings: settings)
        let parakeet = FakeSTTBackend(id: "parakeet", displayName: "Parakeet", availability: .modelNotDownloaded)
        let downloader = FakeSpeechModelDownloader()
        let model = makeModel(store: store, sttRegistry: ["parakeet": parakeet], speechModelDownloaders: ["parakeet": downloader])
        await model.initialSpeechBackendRefresh?.value
        await parakeet.setAvailability(.available)

        await model.downloadSpeechModel("parakeet")
        XCTAssertEqual(model.sttBackends.first(where: { $0.id == "parakeet" })?.state, .ready)

        await downloader.reportProgress(1.0) // a tick arriving after the download already finished
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(model.sttBackends.first(where: { $0.id == "parakeet" })?.state, .ready)
    }

    func testOutOfOrderLowerProgressTickIsIgnored() async {
        var settings = AppSettings.defaults
        settings.sttBackendOrder = ["parakeet"]
        let store = FakeSettingsStore(settings: settings)
        let parakeet = FakeSTTBackend(id: "parakeet", displayName: "Parakeet", availability: .modelNotDownloaded)
        let downloader = FakeSpeechModelDownloader()
        await downloader.setShouldBlock(true)
        let model = makeModel(store: store, sttRegistry: ["parakeet": parakeet], speechModelDownloaders: ["parakeet": downloader])
        await model.initialSpeechBackendRefresh?.value

        let downloadTask = Task { await model.downloadSpeechModel("parakeet") }
        await waitUntil { await downloader.callCount > 0 }

        await downloader.reportProgress(0.7)
        await waitUntil {
            model.sttBackends.first(where: { $0.id == "parakeet" })?.state == .downloading(progress: 0.7)
        }

        await downloader.reportProgress(0.3) // out of order: must not move progress backwards
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(model.sttBackends.first(where: { $0.id == "parakeet" })?.state, .downloading(progress: 0.7))

        await downloader.resume()
        await downloadTask.value
    }

    func testCanDownloadSpeechModelReflectsWhetherADownloaderIsRegistered() {
        let a = FakeSTTBackend(id: "a", displayName: "A")
        let modelWithoutDownloader = makeModel(sttRegistry: ["a": a])
        XCTAssertFalse(modelWithoutDownloader.canDownloadSpeechModel("a"))

        let downloader = FakeSpeechModelDownloader()
        let modelWithDownloader = makeModel(sttRegistry: ["a": a], speechModelDownloaders: ["a": downloader])
        XCTAssertTrue(modelWithDownloader.canDownloadSpeechModel("a"))
    }

    func testSpeechBackendMessageIsSetOnRefusalAndClearedOnNextSuccessfulAction() async {
        var settings = AppSettings.defaults
        settings.sttBackendOrder = ["a"]
        let store = FakeSettingsStore(settings: settings)
        let a = FakeSTTBackend(id: "a", displayName: "A")
        let b = FakeSTTBackend(id: "b", displayName: "B")
        let model = makeModel(store: store, sttRegistry: ["a": a, "b": b])
        await model.initialSpeechBackendRefresh?.value

        model.setSTTBackendEnabled("a", false)
        XCTAssertEqual(model.speechBackendMessage, "At least one speech recognition backend must stay enabled.")

        model.setSTTBackendEnabled("b", true)
        XCTAssertNil(model.speechBackendMessage)
    }

    func testRefreshMapsBackendAvailabilityCasesToFixedStates() async {
        let cases: [(BackendAvailability, STTBackendStatus.State)] = [
            (.available, .ready),
            (.modelNotDownloaded, .modelNotDownloaded),
            (.unsupportedOS, .unsupported),
            (.unsupportedHardware, .unsupported),
            (.permissionDenied, .unavailable),
            (.unavailable("some reason"), .unavailable),
            (.initializing, .unavailable),
            (.failed("boom"), .unavailable),
        ]

        for (availability, expected) in cases {
            let backend = FakeSTTBackend(id: "x", displayName: "X", availability: availability)
            let model = makeModel(sttRegistry: ["x": backend])
            await model.initialSpeechBackendRefresh?.value

            XCTAssertEqual(model.sttBackends.first?.state, expected, "availability: \(availability)")
        }
    }

    /// Polls `condition` until it's true, yielding between checks so other tasks (fakes waiting
    /// on a continuation, progress callbacks hopping to the main actor, etc.) get a chance to
    /// run. Fails the test instead of hanging forever if `condition` never becomes true.
    private func waitUntil(
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            await Task.yield()
        }
    }

    private func makeModel(
        store: FakeSettingsStore? = nil,
        selection: FakeSelectionReader? = nil,
        speech: FakeSpeechCoordinator? = nil,
        hotkeys: FakeHotkeyManager? = nil,
        permissions: FakePermissionService? = nil,
        dictation: FakeDictationCoordinator? = nil,
        microphone: FakeMicrophonePermissionStatus? = nil,
        opener: FakePrivacySettingsOpener? = nil,
        overlayModel: ActivityOverlayModel? = nil,
        overlayPresenter: (any ActivityOverlayPresenting)? = nil,
        sttRegistry: [String: any SpeechToTextBackend] = [:],
        speechModelDownloaders: [String: any SpeechModelDownloading] = [:],
        diagnostics: DiagnosticsRecorder? = nil
    ) -> AppModel {
        AppModel(
            settingsStore: store ?? FakeSettingsStore(settings: .defaults),
            selectionReader: selection ?? FakeSelectionReader(text: "selected"),
            preprocessor: RulesSpeechPreprocessor(),
            speechCoordinator: speech ?? FakeSpeechCoordinator(),
            hotkeyManager: hotkeys ?? FakeHotkeyManager(),
            permissionService: permissions ?? FakePermissionService(snapshot: .init(inputMonitoringGranted: true, accessibilityGranted: true)),
            diagnostics: diagnostics ?? DiagnosticsRecorder(capacity: 10),
            dictationCoordinator: dictation,
            microphonePermissions: microphone ?? FakeMicrophonePermissionStatus(granted: true),
            privacySettingsOpener: opener ?? FakePrivacySettingsOpener(),
            overlayModel: overlayModel ?? ActivityOverlayModel(),
            overlayPresenter: overlayPresenter ?? NoOpActivityOverlayPresenter(),
            sttRegistry: sttRegistry,
            speechModelDownloaders: speechModelDownloaders
        )
    }
}

@MainActor
private final class FakeOverlayPresenter: ActivityOverlayPresenting {
    private(set) var states: [ActivityOverlayState] = []
    private(set) var styles: [ActivityOverlayStyle] = []

    func update(state: ActivityOverlayState, style: ActivityOverlayStyle) {
        states.append(state)
        styles.append(style)
    }
}

@MainActor
private final class FakeDictationCoordinator: DictationCoordinating {
    private(set) var events: [String] = []
    private let blockStart: Bool
    private let blockFinish: Bool
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var finishContinuation: CheckedContinuation<Void, Never>?

    init(blockStart: Bool = false, blockFinish: Bool = false) {
        self.blockStart = blockStart
        self.blockFinish = blockFinish
    }

    func start() async {
        events.append("start")
        if blockStart { await withCheckedContinuation { startContinuation = $0 } }
    }
    func finish() async {
        events.append("finish")
        if blockFinish { await withCheckedContinuation { finishContinuation = $0 } }
    }
    func toggle() async {
        if events.last == "start" { await finish() }
        else { await start() }
    }
    func cancel(sessionID: UUID) async {}
    func resumeStart() { startContinuation?.resume(); startContinuation = nil }
    func resumeFinish() { finishContinuation?.resume(); finishContinuation = nil }
}

@MainActor
private final class FakePermissionService: GlobalPermissionAuthorizing {
    let value: PermissionSnapshot
    private(set) var snapshotCount = 0
    init(snapshot: PermissionSnapshot) { value = snapshot }
    func snapshot() -> PermissionSnapshot { snapshotCount += 1; return value }
    func requestPermissions() {}
}

@MainActor
private final class FakeMicrophonePermissionStatus: MicrophonePermissionStatusProviding {
    var grantedValue: Bool
    let requestResult: Bool
    private(set) var requestCount = 0
    init(granted: Bool, requestResult: Bool? = nil) {
        grantedValue = granted
        self.requestResult = requestResult ?? granted
    }
    func isGranted() -> Bool { grantedValue }
    func requestPermission() async -> Bool {
        requestCount += 1
        grantedValue = requestResult
        return requestResult
    }
}

@MainActor
private final class FakePrivacySettingsOpener: PrivacySettingsOpening {
    private(set) var opened: [PrivacySettingsPane] = []
    func open(_ pane: PrivacySettingsPane) { opened.append(pane) }
}

@MainActor
private final class FakeSettingsStore: SettingsStoring {
    let settings: AppSettings
    let saveError: Error?
    private(set) var saved: [AppSettings] = []

    init(settings: AppSettings, saveError: Error? = nil) {
        self.settings = settings
        self.saveError = saveError
    }

    func load() -> AppSettings { settings }
    func save(_ value: AppSettings) throws {
        if let saveError { throw saveError }
        saved.append(value)
    }
}

private enum TestError: Error {
    case saveFailed
}

private actor FakeSTTBackend: SpeechToTextBackend {
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let capabilities = STTCapabilities([])
    private var availabilityResult: BackendAvailability
    private var shouldBlockAvailability = false
    private(set) var availabilityCallCount = 0
    private var availabilityContinuation: CheckedContinuation<Void, Never>?

    init(id: String, displayName: String, availability: BackendAvailability = .available) {
        self.id = id
        self.displayName = displayName
        availabilityResult = availability
    }

    func availability() async -> BackendAvailability {
        availabilityCallCount += 1
        if shouldBlockAvailability {
            await withCheckedContinuation { availabilityContinuation = $0 }
        }
        return availabilityResult
    }

    func setAvailability(_ value: BackendAvailability) { availabilityResult = value }

    /// Makes `availability()` suspend on a continuation instead of returning immediately, so a
    /// test can deterministically hold a refresh mid-flight and interleave other work before
    /// calling `resumeAvailability()`.
    func setShouldBlockAvailability(_ value: Bool) { shouldBlockAvailability = value }

    func resumeAvailability() {
        availabilityContinuation?.resume()
        availabilityContinuation = nil
    }

    func prepare() async throws {}

    func transcribe(audio: AudioInput, options: STTOptions) async throws -> Transcript {
        Transcript(text: "", backendID: id)
    }
}

private actor FakeSpeechModelDownloader: SpeechModelDownloading {
    private(set) var callCount = 0
    private var progressToReport: [Double] = []
    private var errorToThrow: Error?
    private var shouldBlock = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var capturedProgress: (@Sendable (Double) -> Void)?

    func setProgressToReport(_ values: [Double]) { progressToReport = values }
    func setErrorToThrow(_ error: Error?) { errorToThrow = error }
    func setShouldBlock(_ value: Bool) { shouldBlock = value }

    func downloadModels(progress: @escaping @Sendable (Double) -> Void) async throws {
        callCount += 1
        capturedProgress = progress
        for value in progressToReport {
            progress(value)
        }
        if shouldBlock {
            await withCheckedContinuation { continuation = $0 }
        }
        if let errorToThrow {
            throw errorToThrow
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }

    /// Invokes the progress closure captured from the most recent `downloadModels` call, letting
    /// a test simulate a tick arriving at an arbitrary time — including after completion, or out
    /// of order relative to an earlier tick.
    func reportProgress(_ value: Double) {
        capturedProgress?(value)
    }
}

@MainActor
private final class FakeSelectionReader: SelectionReading {
    let text: String
    private(set) var readCount = 0

    init(text: String) {
        self.text = text
    }

    func readSelection() throws -> SelectionResult {
        readCount += 1
        return .init(text: text, source: .accessibility)
    }
}

@MainActor
private final class FakeSpeechCoordinator: SpeechCoordinating {
    private(set) var requests: [SpeechRequest] = []
    private(set) var stopCount = 0
    private(set) var stoppedSessionIDs: [UUID] = []
    private(set) var replayCount = 0
    let replayError: Error?
    init(replayError: Error? = nil) { self.replayError = replayError }

    func speak(_ request: SpeechRequest) async throws { requests.append(request) }
    func stop() { stopCount += 1 }
    func stop(sessionID: UUID) { stoppedSessionIDs.append(sessionID) }
    func replayLast() async throws { replayCount += 1; if let replayError { throw replayError } }
}

@MainActor
private final class FakeHotkeyManager: HotkeyManaging {
    private let status: HotkeyRegistrationStatus
    private var handler: ((HotkeyAction, HotkeyPhase) -> Void)?
    private(set) var registrations: [AppSettings] = []

    init(status: HotkeyRegistrationStatus = .registered) {
        self.status = status
    }

    func register(
        settings: AppSettings,
        handler: @escaping @MainActor (HotkeyAction, HotkeyPhase) -> Void
    ) -> HotkeyRegistrationStatus {
        registrations.append(settings)
        self.handler = handler
        return status
    }

    func send(_ action: HotkeyAction, _ phase: HotkeyPhase) {
        handler?(action, phase)
    }
}
