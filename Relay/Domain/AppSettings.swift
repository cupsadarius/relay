import Foundation

enum ActivityOverlayStyle: String, Codable, CaseIterable, Sendable {
    case off
    case minimal
    case interactive
}

struct AppSettings: Codable, Equatable, Sendable {
    /// The on-disk schema version of this value. Always `AppSettings.currentSchemaVersion` once
    /// a value exists in memory: a blob saved by an older build (or with no `schemaVersion` key
    /// at all) decodes through the per-field fallbacks in `init(from:)` and lands on the current
    /// version, rather than carrying its original version forward.
    var schemaVersion: Int
    var dictationMode: DictationMode
    var hotkeys: [HotkeyAction: HotkeyDefinition]
    var sttBackendOrder: [String]
    var ttsBackendOrder: [String]
    var ttsRate: Float
    var autoReadEnabled: Bool
    var activityOverlayStyle: ActivityOverlayStyle
    /// The selected voice per TTS backend id (`BackendID.rawValue` → backend-specific voice id).
    /// A missing entry means that backend's default voice.
    var voiceByBackend: [String: String]
    var liveTranscriptionEnabled: Bool
    /// The last model id selected per STT backend id (e.g. `"whisper": "small.en"`), so a
    /// multi-model backend like Whisper remembers the user's choice across launches. Absent
    /// entries mean no selection has been made yet for that backend; resolving an id no longer
    /// present in a backend's catalog is that backend's manager's problem at read time, not
    /// AppSettings'.
    var selectedSpeechModelByBackend: [String: String]

    /// The current on-disk schema version. Bump this (and add an explicit transform to
    /// `init(from:)`) only when a future change needs more than per-field fallback defaults,
    /// e.g. renaming or reshaping a field.
    /// 2: per-backend voice keys folded into voiceByBackend.
    static let currentSchemaVersion = 2

    /// Backend ids `sttBackendOrder` recognizes as valid, mirroring the STT backends
    /// `RelayRuntime.makeProduction()` actually registers (`Relay/App/RelayRuntime.swift`).
    /// Update this alongside that registry when a new STT backend is added.
    static let knownSTTBackendIDs: Set<String> = Set(BackendID.allSpeechToText.map(\.rawValue))

    /// Backend ids `ttsBackendOrder` recognizes as valid, mirroring the TTS backends
    /// `RelayRuntime.makeProduction()` actually registers (`Relay/App/RelayRuntime.swift`).
    /// Update this alongside that registry when a new TTS backend is added.
    static let knownTTSBackendIDs: Set<String> = Set(BackendID.allTextToSpeech.map(\.rawValue))

    /// `ttsRate`'s valid range, matching `TTSSettingsView`'s slider bounds — the only place a
    /// user can actually set this value today.
    static let validTTSRateRange: ClosedRange<Float> = 0.1...1.0

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case dictationMode, hotkeys, sttBackendOrder, ttsBackendOrder
        case ttsRate, autoReadEnabled, activityOverlayStyle, voiceByBackend
        case liveTranscriptionEnabled
        case selectedSpeechModelByBackend
    }

    /// Keys only schema < 2 wrote; read during migration, never encoded.
    private enum LegacyCodingKeys: String, CodingKey {
        case ttsVoiceIdentifier, kokoroVoice, pocketVoice
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppSettings.defaults

        // Per-field resilient decode: `try?` collapses BOTH "key missing" and "key present with
        // the wrong type/an invalid value" into the same fallback-to-default outcome, so one
        // malformed or absent field can never throw and reset every other field along with it.
        // Every field goes through this one helper, including optionals (`Value == String?`,
        // where a JSON `null` still decodes to `nil`). For an optional field, a missing key also
        // takes `defaultValue` (rather than `nil`) — harmless today since every optional field's
        // default is itself `nil`.
        func field<Value: Decodable>(_ key: CodingKeys, default defaultValue: Value) -> Value {
            (try? values.decode(Value.self, forKey: key)) ?? defaultValue
        }

        dictationMode = field(.dictationMode, default: fallback.dictationMode)
        hotkeys = AppSettings.decodeHotkeys(from: values) ?? fallback.hotkeys
        let decodedSTTOrder = field(.sttBackendOrder, default: fallback.sttBackendOrder)
        let decodedTTSOrder = field(.ttsBackendOrder, default: fallback.ttsBackendOrder)
        let decodedRate = field(.ttsRate, default: fallback.ttsRate)
        autoReadEnabled = field(.autoReadEnabled, default: fallback.autoReadEnabled)
        activityOverlayStyle = field(.activityOverlayStyle, default: fallback.activityOverlayStyle)
        // The first reshaped field: schema < 2 stored one optional voice per TTS backend under
        // its own key. A blob with no/invalid `schemaVersion` reads as 0 and migrates too.
        let savedSchemaVersion = field(.schemaVersion, default: 0)
        if savedSchemaVersion < 2 {
            voiceByBackend = AppSettings.migrateLegacyVoices(from: decoder)
        } else {
            // Current, or newer than this build knows: best-effort per-field decode.
            voiceByBackend = field(.voiceByBackend, default: fallback.voiceByBackend)
        }
        liveTranscriptionEnabled = field(.liveTranscriptionEnabled, default: fallback.liveTranscriptionEnabled)
        selectedSpeechModelByBackend = field(
            .selectedSpeechModelByBackend,
            default: fallback.selectedSpeechModelByBackend
        )

        // Normalize AFTER every field has its per-field fallback value: drop unknown/duplicate
        // backend ids (keeping the first occurrence of each known id, in order) and clamp the
        // rate into its valid range. Deliberately does NOT append known-but-missing backend ids
        // to the order — that would invent new behavior; `BackendListModel.knownOrder()` (the
        // equivalent runtime-side filter in `Relay/App/BackendListModel.swift`) only ever filters
        // too, never appends, so this matches existing semantics.
        sttBackendOrder = AppSettings.normalizedBackendOrder(
            decodedSTTOrder,
            knownIDs: AppSettings.knownSTTBackendIDs,
            fallback: fallback.sttBackendOrder
        )
        ttsBackendOrder = AppSettings.normalizedBackendOrder(
            decodedTTSOrder,
            knownIDs: AppSettings.knownTTSBackendIDs,
            fallback: fallback.ttsBackendOrder
        )
        ttsRate = min(max(decodedRate, AppSettings.validTTSRateRange.lowerBound), AppSettings.validTTSRateRange.upperBound)

        // Every in-memory value is the current schema, regardless of what version (if any) the
        // saved blob carried — the fields above have already migrated it.
        schemaVersion = AppSettings.currentSchemaVersion
    }

    /// Decodes `hotkeys` one entry at a time, so a single unknown action (e.g. one written by a
    /// newer build) or malformed definition drops only that entry instead of the whole map.
    ///
    /// Reads the flat `[action, definition, action, definition]` array that Swift's synthesized
    /// `Dictionary` encoding produces for a non-`String`/`Int`, non-`CodingKeyRepresentable` key
    /// (the format every build so far has written, and still writes), and also a keyed
    /// `{"action": definition}` object. Returns `nil` (caller falls back to the default map) when
    /// the field is missing, is neither shape, is a flat array with an odd element count, or has
    /// at least one entry but every one of them is unknown/malformed — that last case leaves the
    /// user with zero hotkeys otherwise, which is worse than falling back to the shipped
    /// defaults. An honestly empty array/object (no entries at all) still decodes to an empty map.
    private static func decodeHotkeys(
        from values: KeyedDecodingContainer<CodingKeys>
    ) -> [HotkeyAction: HotkeyDefinition]? {
        if var entries = try? values.nestedUnkeyedContainer(forKey: .hotkeys) {
            var result: [HotkeyAction: HotkeyDefinition] = [:]
            var sawAnyEntry = false
            while !entries.isAtEnd {
                sawAnyEntry = true
                // Each element decodes through `LossyDecodable`, which never throws: a FAILED
                // decode does not advance an unkeyed container, so decoding the raw types here
                // would stall on the first bad element instead of skipping it.
                guard let key = try? entries.decode(LossyDecodable<String>.self),
                      let definition = try? entries.decode(LossyDecodable<HotkeyDefinition>.self)
                else { return nil }
                if let rawAction = key.value,
                   let action = HotkeyAction(rawValue: rawAction),
                   let definition = definition.value {
                    result[action] = definition
                }
            }
            return (sawAnyEntry && result.isEmpty) ? nil : result
        }
        if let object = try? values.nestedContainer(keyedBy: HotkeyMapKey.self, forKey: .hotkeys) {
            var result: [HotkeyAction: HotkeyDefinition] = [:]
            for key in object.allKeys {
                guard let action = HotkeyAction(rawValue: key.stringValue),
                      let definition = try? object.decode(HotkeyDefinition.self, forKey: key)
                else { continue }
                result[action] = definition
            }
            return (!object.allKeys.isEmpty && result.isEmpty) ? nil : result
        }
        return nil
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

    private static func migrateLegacyVoices(from decoder: Decoder) -> [String: String] {
        guard let legacy = try? decoder.container(keyedBy: LegacyCodingKeys.self) else { return [:] }
        let pairs: [(LegacyCodingKeys, BackendID)] = [
            (.ttsVoiceIdentifier, .appleTTS),
            (.kokoroVoice, .kokoro),
            (.pocketVoice, .pocketTTS),
        ]
        var voices: [String: String] = [:]
        for (key, backend) in pairs {
            if let voice = try? legacy.decode(String.self, forKey: key) {
                voices[backend.rawValue] = voice
            }
        }
        return voices
    }

    init(
        dictationMode: DictationMode,
        hotkeys: [HotkeyAction: HotkeyDefinition],
        sttBackendOrder: [String],
        ttsBackendOrder: [String],
        ttsRate: Float,
        autoReadEnabled: Bool,
        activityOverlayStyle: ActivityOverlayStyle,
        voiceByBackend: [String: String] = [:],
        liveTranscriptionEnabled: Bool = false,
        selectedSpeechModelByBackend: [String: String] = [:],
        schemaVersion: Int = AppSettings.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.dictationMode = dictationMode
        self.hotkeys = hotkeys
        self.sttBackendOrder = sttBackendOrder
        self.ttsBackendOrder = ttsBackendOrder
        self.ttsRate = ttsRate
        self.autoReadEnabled = autoReadEnabled
        self.activityOverlayStyle = activityOverlayStyle
        self.voiceByBackend = voiceByBackend
        self.liveTranscriptionEnabled = liveTranscriptionEnabled
        self.selectedSpeechModelByBackend = selectedSpeechModelByBackend
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
        sttBackendOrder: [BackendID.appleSpeech.rawValue],
        ttsBackendOrder: BackendID.allTextToSpeech.map(\.rawValue),
        ttsRate: 0.5,
        autoReadEnabled: true,
        activityOverlayStyle: .interactive,
        liveTranscriptionEnabled: false
    )
}

extension TTSOptions {
    /// The single mapping from persisted settings to per-utterance options.
    init(settings: AppSettings) {
        self.init(
            voiceIdentifier: settings.voiceByBackend[BackendID.appleTTS.rawValue],
            rate: settings.ttsRate,
            kokoroVoice: settings.voiceByBackend[BackendID.kokoro.rawValue],
            pocketVoice: settings.voiceByBackend[BackendID.pocketTTS.rawValue]
        )
    }
}

/// Wraps a value whose decode may fail, without failing itself — so an unkeyed container always
/// advances past the element. `value` is `nil` when the wrapped decode failed.
private struct LossyDecodable<Wrapped: Decodable>: Decodable {
    let value: Wrapped?

    init(from decoder: Decoder) throws {
        value = try? Wrapped(from: decoder)
    }
}

/// Arbitrary string key, used to read a keyed-object `hotkeys` map whose keys are not known up
/// front (unknown action names are skipped, not rejected).
private struct HotkeyMapKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
