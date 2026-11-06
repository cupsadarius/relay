import XCTest

@testable import Relay

@MainActor
final class SettingsControllerTests: XCTestCase {
    private func makeController(
        store: SpySettingsStore? = nil,
        statusSink: StatusSink? = nil,
        saveDelay: Duration = .seconds(60)
    ) -> SettingsController {
        SettingsController(store: store ?? SpySettingsStore(), statusSink: statusSink ?? StatusSink(), saveDelay: saveDelay)
    }

    func testLoadsFromStoreAndExposesOneValueThroughCurrentAndSnapshot() {
        var saved = AppSettings.defaults
        saved.dictationMode = .toggle
        let controller = makeController(store: SpySettingsStore(settings: saved))

        XCTAssertEqual(controller.current.dictationMode, .toggle)
        XCTAssertEqual(controller.snapshot.value, controller.current)
    }

    func testSnapshotIsReadableOffTheMainActor() async {
        let controller = makeController()
        controller.setAutoReadEnabled(false)
        let snapshot = controller.snapshot

        let autoRead = await Task.detached { snapshot.value.autoReadEnabled }.value

        XCTAssertFalse(autoRead)
    }

    func testToggleAutoReadPersistsAndAnnounces() {
        let store = SpySettingsStore()
        let statusSink = StatusSink()
        let controller = makeController(store: store, statusSink: statusSink)

        controller.toggleAutoRead()
        XCTAssertFalse(controller.current.autoReadEnabled)
        XCTAssertEqual(statusSink.message, "Auto-read disabled")

        controller.toggleAutoRead()
        XCTAssertTrue(controller.current.autoReadEnabled)
        XCTAssertEqual(statusSink.message, "Auto-read enabled")
        XCTAssertEqual(store.saved.map(\.autoReadEnabled), [false, true])
    }

    func testSetAutoReadEnabledToCurrentValueIsANoOp() {
        let store = SpySettingsStore()
        let controller = makeController(store: store)

        controller.setAutoReadEnabled(true)

        XCTAssertTrue(store.saved.isEmpty)
    }

    func testConflictingHotkeyIsRejectedWithActionableMessage() {
        let store = SpySettingsStore()
        let statusSink = StatusSink()
        let controller = makeController(store: store, statusSink: statusSink)
        let notified = HotkeyChangeRecorder()
        controller.onHotkeysChanged = { notified.values.append($0) }
        let existing = try! XCTUnwrap(controller.current.hotkeys[.replayLast])

        controller.setHotkey(existing, for: .readSelection)

        let expected = "Read Selection conflicts with Replay Last. Choose a different shortcut."
        XCTAssertEqual(controller.hotkeyConflictMessage, expected)
        XCTAssertEqual(statusSink.message, expected)
        XCTAssertEqual(controller.current, .defaults)
        XCTAssertTrue(store.saved.isEmpty)
        XCTAssertTrue(notified.values.isEmpty)
    }

    func testHotkeyChangeNotifiesOnlyWhenDefinitionsChange() {
        let controller = makeController()
        let notified = HotkeyChangeRecorder()
        controller.onHotkeysChanged = { notified.values.append($0) }
        let replacement = HotkeyDefinition.chord(keyCode: 49, modifiers: [.command])

        controller.setDictationMode(.toggle)
        controller.setHotkey(replacement, for: .readSelection)

        XCTAssertEqual(notified.values.count, 1)
        XCTAssertEqual(notified.values.first?[.readSelection], replacement)
    }

    func testRemoveHotkeyClearsConflictMessage() {
        let controller = makeController()
        let existing = try! XCTUnwrap(controller.current.hotkeys[.replayLast])
        controller.setHotkey(existing, for: .readSelection)
        XCTAssertNotNil(controller.hotkeyConflictMessage)

        controller.removeHotkey(for: .readSelection)

        XCTAssertNil(controller.hotkeyConflictMessage)
        XCTAssertNil(controller.current.hotkeys[.readSelection])
    }

    func testSaveFailureStillAppliesChangeAndSurfacesError() {
        let statusSink = StatusSink()
        let controller = makeController(
            store: SpySettingsStore(saveError: NSError(domain: "test", code: 1)),
            statusSink: statusSink
        )

        controller.setDictationMode(.toggle)

        XCTAssertEqual(controller.current.dictationMode, .toggle)
        XCTAssertTrue(statusSink.message.contains("Could not save settings"))
    }

    // MARK: Speech rate debounce

    func testSpeechRateAppliesImmediatelyButPersistsOnceWhenFlushed() {
        let store = SpySettingsStore()
        let controller = makeController(store: store)

        for rate: Float in [0.55, 0.6, 0.65, 0.7] { controller.setSpeechRate(rate) }

        XCTAssertEqual(controller.current.ttsRate, 0.7, accuracy: 0.0001)
        XCTAssertEqual(controller.snapshot.value.ttsRate, 0.7, accuracy: 0.0001)
        XCTAssertTrue(store.saved.isEmpty, "slider ticks must not write UserDefaults")

        controller.flushPendingSave()
        XCTAssertEqual(store.saved.count, 1)
        XCTAssertEqual(store.saved.last?.ttsRate ?? 0, 0.7, accuracy: 0.0001)

        controller.flushPendingSave()
        XCTAssertEqual(store.saved.count, 1, "nothing pending, nothing written")
    }

    func testDebouncedSpeechRateSavesAfterTheDelay() async {
        let store = SpySettingsStore()
        let controller = makeController(store: store, saveDelay: .milliseconds(10))

        controller.setSpeechRate(0.8)

        let deadline = Date().addingTimeInterval(2)
        while store.saved.isEmpty, Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.saved.count, 1)
        XCTAssertEqual(store.saved.last?.ttsRate ?? 0, 0.8, accuracy: 0.0001)
    }

    func testAnImmediateWriteAlsoPersistsThePendingRate() {
        let store = SpySettingsStore()
        let controller = makeController(store: store)

        controller.setSpeechRate(0.8)
        controller.setDictationMode(.toggle)
        controller.flushPendingSave()

        XCTAssertEqual(store.saved.count, 1)
        XCTAssertEqual(store.saved.last?.ttsRate ?? 0, 0.8, accuracy: 0.0001)
        XCTAssertEqual(store.saved.last?.dictationMode, .toggle)
    }

    // MARK: Model selection seams

    func testWhisperSelectionIsSeededFromPersistedSettings() {
        var saved = AppSettings.defaults
        saved.selectedSpeechModelByBackend[.whisper] = "base.en"
        let controller = makeController(store: SpySettingsStore(settings: saved))

        let read: WhisperModelSelection = controller.modelSelection(for: .whisper)
        XCTAssertEqual(read(), .baseEn)
    }

    func testWhisperSelectionWriterPersistsAndIsVisibleFromAnyActor() async {
        let store = SpySettingsStore()
        let controller = makeController(store: store)
        let read: WhisperModelSelection = controller.modelSelection(for: .whisper)
        let write: WhisperModelSelectionWriter = controller.modelSelectionWriter(for: .whisper)

        write(.smallEn)

        XCTAssertEqual(controller.current.selectedSpeechModelByBackend[.whisper], "small.en")
        XCTAssertEqual(store.saved.last?.selectedSpeechModelByBackend[.whisper], "small.en")
        let seenOffMain = await Task.detached { read() }.value
        XCTAssertEqual(seenOffMain, .smallEn)

        write(nil)

        XCTAssertNil(controller.current.selectedSpeechModelByBackend[.whisper])
        XCTAssertNil(read())
    }

    func testParakeetSelectionPersistsAndReadsBack() {
        let controller = makeController(store: SpySettingsStore())
        let read: ParakeetModelSelection = controller.modelSelection(for: .parakeet)
        let write: ParakeetModelSelectionWriter = controller.modelSelectionWriter(for: .parakeet)
        XCTAssertNil(read())

        write(.v2)

        XCTAssertEqual(controller.current.selectedSpeechModelByBackend[.parakeet], "parakeet-v2")
        XCTAssertEqual(read(), .v2)
    }

    func testUnknownPersistedWhisperIDReadsAsNoSelection() {
        var saved = AppSettings.defaults
        saved.selectedSpeechModelByBackend[.whisper] = "not-a-model"
        let controller = makeController(store: SpySettingsStore(settings: saved))

        let read: WhisperModelSelection = controller.modelSelection(for: .whisper)
        XCTAssertNil(read())
    }

    func testSetVoiceWritesAndClearsOneBackendsEntry() {
        let store = SpySettingsStore()
        let controller = makeController(store: store)

        controller.setVoice("am_adam", for: .kokoro)
        XCTAssertEqual(controller.current.voiceByBackend, [.kokoro: "am_adam"])

        controller.setVoice(nil, for: .kokoro)
        XCTAssertTrue(controller.current.voiceByBackend.isEmpty)
        XCTAssertEqual(store.saved.count, 2)
    }

    func testTTSOptionsCarryTheVoiceMapAndRate() {
        var settings = AppSettings.defaults
        settings.ttsRate = 0.7
        settings.voiceByBackend = [.appleTTS: "com.apple.voice.x", .kokoro: "am_adam", .pocketTTS: "alba"]

        let options = TTSOptions(settings: settings)

        XCTAssertEqual(options, TTSOptions(voiceByBackend: [.appleTTS: "com.apple.voice.x", .kokoro: "am_adam", .pocketTTS: "alba"], rate: 0.7))
    }
}

/// Collects `onHotkeysChanged` calls. A class, so the escaping `@MainActor` closure mutates a
/// reference instead of a captured local `var`.
@MainActor
private final class HotkeyChangeRecorder {
    var values: [[HotkeyAction: HotkeyDefinition]] = []
}
