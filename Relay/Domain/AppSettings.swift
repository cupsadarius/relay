import Foundation

enum ActivityOverlayStyle: String, Codable, CaseIterable, Sendable {
    case off
    case minimal
    case interactive
}

struct AppSettings: Codable, Equatable, Sendable {
    /// The on-disk schema version of this value. Always `AppSettings.currentSchemaVersion` once
    /// a value exists in memory — a blob saved by an older build (or with no `schemaVersion` key
    /// at all, i.e. version 0) is migrated up to the current version during decode rather than
    /// carrying its original version forward. See `init(from:)`'s migration switch.
    var schemaVersion: Int
    var dictationMode: DictationMode
    var hotkeys: [HotkeyAction: HotkeyDefinition]
    var sttBackendOrder: [String]
    var ttsBackendOrder: [String]
    var ttsVoiceIdentifier: String?
    var ttsRate: Float
    var autoReadEnabled: Bool
    var activityOverlayStyle: ActivityOverlayStyle
    var kokoroVoice: String?
    var pocketVoice: String?
    var liveTranscriptionEnabled: Bool

    /// The current on-disk schema version. Bump this and add a case to the `switch` in
    /// `init(from:)` whenever a future change needs an explicit transformation step (e.g.
    /// renaming or reshaping a field) beyond what per-field fallback defaults already handle.
    static let currentSchemaVersion = 1

    /// Backend ids `sttBackendOrder` recognizes as valid, mirroring the STT backends
    /// `RelayRuntime.makeProduction()` actually registers (`Relay/App/RelayRuntime.swift`).
    /// Update this alongside that registry when a new STT backend is added.
    static let knownSTTBackendIDs: Set<String> = ["apple-speech", "parakeet"]

    /// Backend ids `ttsBackendOrder` recognizes as valid, mirroring the TTS backends
    /// `RelayRuntime.makeProduction()` actually registers (`Relay/App/RelayRuntime.swift`).
    /// Update this alongside that registry when a new TTS backend is added.
    static let knownTTSBackendIDs: Set<String> = ["pocket-tts", "apple-tts", "kokoro"]

    /// `ttsRate`'s valid range, matching `TTSSettingsView`'s slider bounds — the only place a
    /// user can actually set this value today.
    static let validTTSRateRange: ClosedRange<Float> = 0.1...1.0

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case dictationMode, hotkeys, sttBackendOrder, ttsBackendOrder
        case ttsVoiceIdentifier, ttsRate, autoReadEnabled, activityOverlayStyle, kokoroVoice, pocketVoice
        case liveTranscriptionEnabled
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)

        // The saved schema version, defaulting to 0 (legacy/pre-schema-version) when absent or
        // unreadable. Every field below already falls back to its own default independently, so
        // there is nothing further a v0 blob needs beyond that — the switch exists so a future,
        // more involved migration has an obvious place to live instead of being invented ad hoc.
        let savedSchemaVersion = (try? values.decode(Int.self, forKey: .schemaVersion)) ?? 0
        switch savedSchemaVersion {
        case AppSettings.currentSchemaVersion:
            break
        default:
            // Covers both legacy blobs (< currentSchemaVersion) and blobs saved by a newer build
            // than this one knows about (> currentSchemaVersion): best-effort decode via the
            // per-field fallbacks below, since there is no version-specific transform yet.
            break
        }

        // Per-field resilient decode: `try?` collapses BOTH "key missing" and "key present with
        // the wrong type/an invalid value" into the same fallback-to-default outcome, so one
        // malformed or absent field can never throw and reset every other field along with it
        // (which is what plain `decode`/`decodeIfPresent` used to do here before this fix).
        dictationMode = (try? values.decode(DictationMode.self, forKey: .dictationMode))
            ?? AppSettings.defaults.dictationMode
        hotkeys = (try? values.decode([HotkeyAction: HotkeyDefinition].self, forKey: .hotkeys))
            ?? AppSettings.defaults.hotkeys
        let decodedSTTOrder = (try? values.decode([String].self, forKey: .sttBackendOrder))
            ?? AppSettings.defaults.sttBackendOrder
        let decodedTTSOrder = (try? values.decode([String].self, forKey: .ttsBackendOrder))
            ?? AppSettings.defaults.ttsBackendOrder
        ttsVoiceIdentifier = try values.decodeIfPresent(String.self, forKey: .ttsVoiceIdentifier)
        let decodedRate = (try? values.decode(Float.self, forKey: .ttsRate)) ?? AppSettings.defaults.ttsRate
        autoReadEnabled = (try? values.decode(Bool.self, forKey: .autoReadEnabled))
            ?? AppSettings.defaults.autoReadEnabled
        activityOverlayStyle = try values.decodeIfPresent(
            ActivityOverlayStyle.self,
            forKey: .activityOverlayStyle
        ) ?? .interactive
        kokoroVoice = try values.decodeIfPresent(String.self, forKey: .kokoroVoice)
        pocketVoice = try values.decodeIfPresent(String.self, forKey: .pocketVoice)
        liveTranscriptionEnabled = try values.decodeIfPresent(Bool.self, forKey: .liveTranscriptionEnabled) ?? false

        // Normalize AFTER every field has its per-field fallback value: drop unknown/duplicate
        // backend ids (keeping the first occurrence of each known id, in order) and clamp the
        // rate into its valid range. Deliberately does NOT append known-but-missing backend ids
        // to the order — that would invent new behavior; `BackendCatalog.knownOrder` (the
        // equivalent runtime-side filter in `Relay/App/BackendCatalog.swift`) only ever filters
        // too, never appends, so this matches existing semantics.
        sttBackendOrder = AppSettings.normalizedBackendOrder(
            decodedSTTOrder,
            knownIDs: AppSettings.knownSTTBackendIDs,
            fallback: AppSettings.defaults.sttBackendOrder
        )
        ttsBackendOrder = AppSettings.normalizedBackendOrder(
            decodedTTSOrder,
            knownIDs: AppSettings.knownTTSBackendIDs,
            fallback: AppSettings.defaults.ttsBackendOrder
        )
        ttsRate = min(max(decodedRate, AppSettings.validTTSRateRange.lowerBound), AppSettings.validTTSRateRange.upperBound)

        // Every in-memory value is the current schema, regardless of what version (if any) the
        // saved blob carried — the fields above have already migrated it.
        schemaVersion = AppSettings.currentSchemaVersion
    }

    /// Filters `order` down to ids in `knownIDs`, preserving their relative order and collapsing
    /// duplicates to their first occurrence. Falls back to `fallback` entirely if nothing known
    /// remains (equivalent to treating the field as absent) so a settings value never ends up
    /// with zero enabled backends.
    private static func normalizedBackendOrder(_ order: [String], knownIDs: Set<String>, fallback: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []
        for id in order where knownIDs.contains(id) && seen.insert(id).inserted {
            normalized.append(id)
        }
        return normalized.isEmpty ? fallback : normalized
    }

    init(
        dictationMode: DictationMode,
        hotkeys: [HotkeyAction: HotkeyDefinition],
        sttBackendOrder: [String],
        ttsBackendOrder: [String],
        ttsVoiceIdentifier: String?,
        ttsRate: Float,
        autoReadEnabled: Bool,
        activityOverlayStyle: ActivityOverlayStyle,
        kokoroVoice: String? = nil,
        pocketVoice: String? = nil,
        liveTranscriptionEnabled: Bool = false,
        schemaVersion: Int = AppSettings.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.dictationMode = dictationMode
        self.hotkeys = hotkeys
        self.sttBackendOrder = sttBackendOrder
        self.ttsBackendOrder = ttsBackendOrder
        self.ttsVoiceIdentifier = ttsVoiceIdentifier
        self.ttsRate = ttsRate
        self.autoReadEnabled = autoReadEnabled
        self.activityOverlayStyle = activityOverlayStyle
        self.kokoroVoice = kokoroVoice
        self.pocketVoice = pocketVoice
        self.liveTranscriptionEnabled = liveTranscriptionEnabled
    }

    static let defaults = AppSettings(
        dictationMode: .holdToTalk,
        hotkeys: [
            .dictate: .modifierOnly(.function),
            .readSelection: .chord(keyCode: 15, modifiers: [.option]),
            .stopSpeech: .chord(keyCode: 53, modifiers: []),
            .replayLast: .chord(keyCode: 15, modifiers: [.option, .shift]),
            .toggleAutoRead: .chord(keyCode: 0, modifiers: [.option, .shift]),
        ],
        sttBackendOrder: ["apple-speech"],
        ttsBackendOrder: ["pocket-tts", "apple-tts", "kokoro"],
        ttsVoiceIdentifier: nil,
        ttsRate: 0.5,
        autoReadEnabled: true,
        activityOverlayStyle: .interactive,
        liveTranscriptionEnabled: false
    )
}
