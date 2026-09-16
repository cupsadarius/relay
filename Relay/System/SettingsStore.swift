import Foundation

@MainActor
protocol SettingsStoring: AnyObject {
    func load() -> AppSettings
    func save(_ value: AppSettings) throws
}

@MainActor
final class SettingsStore: SettingsStoring {
    private let defaults: UserDefaults
    private let key = "relay.settings.v1"
    private let diagnostics: DiagnosticsRecorder?

    /// Holds only the single most recently failed-to-decode blob, overwritten on each new
    /// failure rather than accumulated — one recovery copy is enough to inspect what went wrong
    /// (or restore it by hand) without the key growing without bound across repeated failures.
    static let corruptBlobKey = "relay.settings.corrupt"

    init(defaults: UserDefaults = .standard, diagnostics: DiagnosticsRecorder? = nil) {
        self.defaults = defaults
        self.diagnostics = diagnostics
    }

    func load() -> AppSettings {
        guard let data = defaults.data(forKey: key) else {
            return .defaults
        }
        do {
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            // Total decode failure: not even a JSON object `AppSettings.init(from:)`'s per-field
            // fallbacks could pick apart (garbage bytes, or valid JSON that isn't a keyed
            // object). Preserve the raw blob for later recovery and record a privacy-safe,
            // content-free diagnostic — never the bytes, never `error`'s own description, which
            // could otherwise echo fragments of the corrupt data back into a log.
            defaults.set(data, forKey: Self.corruptBlobKey)
            diagnostics?.record(.settingsDecodeFailed(byteCount: data.count))
            return .defaults
        }
    }

    func save(_ value: AppSettings) throws {
        defaults.set(try JSONEncoder().encode(value), forKey: key)
    }
}
