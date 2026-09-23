import Foundation
import Observation
import Synchronization

/// The one copy of the current `AppSettings`, lock-protected so any actor can read it
/// synchronously (the TTS/STT routers, `WhisperBackend`'s own actor, `AgentAutoReadCoordinator`).
/// Only `SettingsController` writes it.
final class SettingsSnapshot: Sendable {
    private let storage: Mutex<AppSettings>

    init(_ initial: AppSettings) {
        storage = Mutex(initial)
    }

    var value: AppSettings {
        storage.withLock { $0 }
    }

    fileprivate func replace(_ newValue: AppSettings) {
        storage.withLock { $0 = newValue }
    }
}

/// Relay's sole settings writer: typed setters, hotkey conflict validation, persistence, and the
/// Whisper selection seam. `current` is an Observation-tracked view over `snapshot` — there is no
/// second copy to keep in sync.
@MainActor
@Observable
final class SettingsController {
    /// How long a speech-rate change waits before it is written to disk.
    static let speechRateSaveDelay: Duration = .milliseconds(400)

    private(set) var hotkeyConflictMessage: String?

    @ObservationIgnored let snapshot: SettingsSnapshot
    /// Called after a write that changed the hotkey DEFINITIONS (and only then), so the hotkey
    /// matcher is rebuilt only when it has to be.
    @ObservationIgnored var onHotkeysChanged: (@MainActor ([HotkeyAction: HotkeyDefinition]) -> Void)?
    @ObservationIgnored private let store: any SettingsStoring
    @ObservationIgnored private let statusSink: StatusSink
    @ObservationIgnored private let saveDelay: Duration
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    init(
        store: any SettingsStoring,
        statusSink: StatusSink,
        saveDelay: Duration = SettingsController.speechRateSaveDelay
    ) {
        self.store = store
        self.statusSink = statusSink
        self.saveDelay = saveDelay
        snapshot = SettingsSnapshot(store.load())
    }

    var current: AppSettings {
        access(keyPath: \.current)
        return snapshot.value
    }

    // MARK: Writes

    /// Applies `change` and persists immediately (also persisting any pending debounced change).
    func update(_ change: (inout AppSettings) -> Void) {
        apply(change)
        save()
    }

    func setHotkey(_ definition: HotkeyDefinition, for action: HotkeyAction) {
        let hotkeys = current.hotkeys
        if let conflictingAction = HotkeyAction.allCases.first(where: {
            guard $0 != action, let existing = hotkeys[$0] else { return false }
            return definition.conflicts(with: existing)
        }) {
            let message = "\(action.title) conflicts with \(conflictingAction.title). Choose a different shortcut."
            hotkeyConflictMessage = message
            statusSink.post(message)
            return
        }
        hotkeyConflictMessage = nil
        update { $0.hotkeys[action] = definition }
    }

    func removeHotkey(for action: HotkeyAction) {
        hotkeyConflictMessage = nil
        update { $0.hotkeys[action] = nil }
    }

    func setDictationMode(_ mode: DictationMode) { update { $0.dictationMode = mode } }
    func setActivityOverlayStyle(_ style: ActivityOverlayStyle) { update { $0.activityOverlayStyle = style } }
    func setLiveTranscriptionEnabled(_ enabled: Bool) { update { $0.liveTranscriptionEnabled = enabled } }
    func setSTTBackendOrder(_ order: [String]) { update { $0.sttBackendOrder = order } }
    func setTTSBackendOrder(_ order: [String]) { update { $0.ttsBackendOrder = order } }
    func setVoiceIdentifier(_ identifier: String?) { update { $0.ttsVoiceIdentifier = identifier } }
    func setKokoroVoice(_ voice: String?) { update { $0.kokoroVoice = voice } }
    func setPocketVoice(_ voice: String?) { update { $0.pocketVoice = voice } }

    func setSelectedSpeechModel(backendID: String, modelID: String?) {
        update { $0.selectedSpeechModelByBackend[backendID] = modelID }
    }

    /// No-op when unchanged, so re-toggling the same control doesn't spam the status line.
    func setAutoReadEnabled(_ enabled: Bool) {
        guard enabled != current.autoReadEnabled else { return }
        update { $0.autoReadEnabled = enabled }
        statusSink.post(enabled ? "Auto-read enabled" : "Auto-read disabled")
    }

    func toggleAutoRead() {
        setAutoReadEnabled(!current.autoReadEnabled)
    }

    /// Applies immediately (so the next utterance uses it) but persists once after the slider
    /// settles, instead of JSON-encoding and writing on every drag tick.
    func setSpeechRate(_ rate: Float) {
        apply { $0.ttsRate = rate }
        pendingSave?.cancel()
        pendingSave = Task { [weak self, saveDelay] in
            try? await Task.sleep(for: saveDelay)
            guard !Task.isCancelled else { return }
            self?.flushPendingSave()
        }
    }

    /// Writes a pending debounced change now. Called when the rate slider's drag ends and when the
    /// app terminates. No-op when nothing is pending.
    func flushPendingSave() {
        guard pendingSave != nil else { return }
        save()
    }

    // MARK: Whisper selection seam

    /// Synchronous, actor-agnostic read of Whisper's selected model (for `WhisperBackend` and
    /// `WhisperModelManager`).
    var whisperSelection: WhisperModelSelection {
        let snapshot = snapshot
        return {
            snapshot.value.selectedSpeechModelByBackend[BackendID.whisper.rawValue].flatMap(WhisperModelID.init(rawValue:))
        }
    }

    /// Write half of the seam: persists through this controller like every other setting.
    var whisperSelectionWriter: WhisperModelSelectionWriter {
        { [weak self] modelID in
            self?.setSelectedSpeechModel(backendID: BackendID.whisper.rawValue, modelID: modelID?.rawValue)
        }
    }

    // MARK: Private

    private func apply(_ change: (inout AppSettings) -> Void) {
        let previous = snapshot.value
        var next = previous
        change(&next)
        withMutation(keyPath: \.current) { snapshot.replace(next) }
        if next.hotkeys != previous.hotkeys {
            onHotkeysChanged?(next.hotkeys)
        }
    }

    private func save() {
        pendingSave?.cancel()
        pendingSave = nil
        do {
            try store.save(snapshot.value)
        } catch {
            statusSink.post("Could not save settings: \(error.localizedDescription)")
        }
    }
}
