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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return .defaults
        }
        return value
    }

    func save(_ value: AppSettings) throws {
        defaults.set(try JSONEncoder().encode(value), forKey: key)
    }
}
