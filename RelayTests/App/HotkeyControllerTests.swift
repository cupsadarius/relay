import XCTest
@testable import Relay

@MainActor
final class HotkeyControllerTests: XCTestCase {
    private func makeController(
        hotkeys: SpyHotkeyManager? = nil,
        dictation: SpyDictationCoordinator? = nil,
        speech: SpySpeechCoordinator? = nil,
        selection: SpySelectionReader? = nil
    ) -> (controller: HotkeyController, runtime: RelayRuntime) {
        let hotkeys = hotkeys ?? SpyHotkeyManager()
        let speech = speech ?? SpySpeechCoordinator()
        let selection = selection ?? SpySelectionReader()
        let runtime = RelayRuntime.testing(
            selectionReader: selection,
            speechCoordinator: speech,
            hotkeyManager: hotkeys,
            dictationCoordinator: dictation
        )
        let actions = SpeechActions(runtime: runtime, voiceCatalog: SpeechVoiceCatalog(
            appleVoices: [], kokoroVoices: [], recommendedKokoroVoice: "af_heart", pocketVoice: "alba"
        ))
        let controller = HotkeyController(runtime: runtime, speechActions: actions)
        controller.start()
        return (controller, runtime)
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out") }
            await Task.yield()
        }
    }

    func testStartPushesDefinitionsAndEnsuresTheTapOnce() {
        let hotkeys = SpyHotkeyManager()
        let (controller, runtime) = makeController(hotkeys: hotkeys)

        XCTAssertEqual(hotkeys.updates, [runtime.settingsController.current.hotkeys])
        XCTAssertEqual(hotkeys.ensureTapCount, 1)
        XCTAssertEqual(controller.eventTapStatus, .registered)
    }

    /// Editing a hotkey is a natural moment to retry a previously-unavailable tap (e.g. the user
    /// just granted Accessibility and came back to Settings to fix a binding).
    func testDefinitionsChangedAlsoRetriesTheEventTap() {
        let hotkeys = SpyHotkeyManager()
        let (controller, runtime) = makeController(hotkeys: hotkeys)
        XCTAssertEqual(hotkeys.ensureTapCount, 1, "sanity: start() already called ensureTap once")

        controller.definitionsChanged([:])

        XCTAssertEqual(hotkeys.updates.last, [:])
        XCTAssertEqual(hotkeys.ensureTapCount, 2)
        withExtendedLifetime(runtime) {}
    }

    /// A still-unavailable tap must keep posting its status after a hotkey edit, exactly as
    /// `ensureTap()` always does — not just retry silently.
    func testDefinitionsChangedPostsStatusWhenTheTapIsStillUnavailable() {
        let hotkeys = SpyHotkeyManager(status: .unavailable("Enable Accessibility permission, then reopen Relay."))
        let (controller, runtime) = makeController(hotkeys: hotkeys)

        controller.definitionsChanged([:])

        XCTAssertEqual(controller.eventTapStatus, .unavailable("Enable Accessibility permission, then reopen Relay."))
        XCTAssertEqual(runtime.status.message, "Enable Accessibility permission, then reopen Relay.")
    }

    func testUnavailableTapSurfacesActionableStatus() {
        let hotkeys = SpyHotkeyManager(status: .unavailable("Enable Accessibility permission, then reopen Relay."))
        let (controller, runtime) = makeController(hotkeys: hotkeys)

        XCTAssertEqual(controller.eventTapStatus, .unavailable("Enable Accessibility permission, then reopen Relay."))
        XCTAssertEqual(runtime.status.message, "Enable Accessibility permission, then reopen Relay.")
    }

    func testHoldToTalkStartsOnPressAndFinishesOnRelease() async {
        let hotkeys = SpyHotkeyManager()
        let dictation = SpyDictationCoordinator()
        let (controller, _) = makeController(hotkeys: hotkeys, dictation: dictation)

        hotkeys.send(.dictate, .pressed)
        hotkeys.send(.dictate, .released)
        await waitUntil { dictation.events == ["start", "finish"] }

        XCTAssertEqual(controller.dictationPhase, .released)
    }

    func testToggleDictationAlternatesOnPressAndIgnoresRelease() async {
        let hotkeys = SpyHotkeyManager()
        let dictation = SpyDictationCoordinator()
        let (controller, runtime) = makeController(hotkeys: hotkeys, dictation: dictation)
        runtime.settingsController.setDictationMode(.toggle)

        hotkeys.send(.dictate, .pressed)
        hotkeys.send(.dictate, .released)
        hotkeys.send(.dictate, .pressed)
        await waitUntil { dictation.events == ["start", "finish"] }
        withExtendedLifetime(controller) {}
    }

    func testHoldToTalkQueuesReleaseUntilBlockedStartCompletes() async {
        let hotkeys = SpyHotkeyManager()
        let dictation = SpyDictationCoordinator(blockStart: true)
        let (controller, _) = makeController(hotkeys: hotkeys, dictation: dictation)

        hotkeys.send(.dictate, .pressed)
        await waitUntil { dictation.events == ["start"] }
        hotkeys.send(.dictate, .released)
        await Task.yield()
        XCTAssertEqual(dictation.events, ["start"])

        dictation.resumeStart()
        await waitUntil { dictation.events == ["start", "finish"] }
        withExtendedLifetime(controller) {}
    }

    func testToggleQueuesNewPressUntilBlockedFinishCompletes() async {
        let hotkeys = SpyHotkeyManager()
        let dictation = SpyDictationCoordinator(blockFinish: true)
        let (controller, runtime) = makeController(hotkeys: hotkeys, dictation: dictation)
        runtime.settingsController.setDictationMode(.toggle)

        hotkeys.send(.dictate, .pressed)
        await waitUntil { dictation.events == ["start"] }
        hotkeys.send(.dictate, .pressed)
        await waitUntil { dictation.events == ["start", "finish"] }
        hotkeys.send(.dictate, .pressed)
        await Task.yield()
        XCTAssertEqual(dictation.events, ["start", "finish"])

        dictation.resumeFinish()
        await waitUntil { dictation.events == ["start", "finish", "start"] }
        withExtendedLifetime(controller) {}
    }

    func testReadSelectionReleasedDoesNothing() async {
        let hotkeys = SpyHotkeyManager()
        let selection = SpySelectionReader()
        let speech = SpySpeechCoordinator()
        let (controller, runtime) = makeController(hotkeys: hotkeys, speech: speech, selection: selection)

        hotkeys.send(.readSelection, .released)
        await Task.yield()

        XCTAssertEqual(selection.readCount, 0)
        XCTAssertTrue(speech.requests.isEmpty)
        XCTAssertEqual(runtime.diagnostics.counters.dispatched, 0)
        withExtendedLifetime(controller) {}
    }

    func testStopAndReplayOnlyActWhenPressed() async {
        let hotkeys = SpyHotkeyManager()
        let speech = SpySpeechCoordinator()
        let (controller, _) = makeController(hotkeys: hotkeys, speech: speech)

        hotkeys.send(.stopSpeech, .released)
        hotkeys.send(.replayLast, .released)
        hotkeys.send(.stopSpeech, .pressed)
        hotkeys.send(.replayLast, .pressed)
        await waitUntil { speech.replayCount > 0 }

        XCTAssertEqual(speech.stopCount, 1)
        XCTAssertEqual(speech.replayCount, 1)
        withExtendedLifetime(controller) {}
    }

    // Plan 1 Task 8's single-action tests, moved from AppModelTests.

    func testTwoQuickReadSelectionPressesSpeakOnlyOnce() async {
        let hotkeys = SpyHotkeyManager()
        let speech = SpySpeechCoordinator()
        let (controller, _) = makeController(hotkeys: hotkeys, speech: speech)

        hotkeys.send(.readSelection, .pressed)
        hotkeys.send(.readSelection, .pressed)
        await waitUntil { !speech.requests.isEmpty }
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(speech.requests.count, 1)
        withExtendedLifetime(controller) {}
    }

    func testTwoQuickReplayPressesReplayOnlyOnce() async {
        let hotkeys = SpyHotkeyManager()
        let speech = SpySpeechCoordinator()
        let (controller, _) = makeController(hotkeys: hotkeys, speech: speech)

        hotkeys.send(.replayLast, .pressed)
        hotkeys.send(.replayLast, .pressed)
        await waitUntil { speech.replayCount > 0 }
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(speech.replayCount, 1)
        withExtendedLifetime(controller) {}
    }

    func testStopSpeechCancelsAPendingReplay() async {
        let hotkeys = SpyHotkeyManager()
        let speech = SpySpeechCoordinator()
        let (controller, _) = makeController(hotkeys: hotkeys, speech: speech)

        hotkeys.send(.replayLast, .pressed)
        hotkeys.send(.stopSpeech, .pressed)
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(speech.replayCount, 0)
        XCTAssertEqual(speech.stopCount, 1)
        withExtendedLifetime(controller) {}
    }

    func testToggleAutoReadHotkeyPersistsWithoutPushingDefinitions() {
        let hotkeys = SpyHotkeyManager()
        let (controller, runtime) = makeController(hotkeys: hotkeys)

        hotkeys.send(.toggleAutoRead, .pressed)

        XCTAssertFalse(runtime.settingsController.current.autoReadEnabled)
        XCTAssertEqual(hotkeys.updates.count, 1)
        withExtendedLifetime(controller) {}
    }
}
