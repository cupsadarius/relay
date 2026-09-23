import Foundation

/// Which side-by-side build of Relay is running. Read from the `RelayBuildFlavor` Info.plist key
/// (set per configuration in `project.yml`); a missing or unknown value is `.release`.
///
/// Compiled into BOTH the `Relay` app target and the `RelayHook` helper target. `RelayHook` has
/// no Info.plist, so `.current` is always `.release` there — the helper never uses it for paths
/// (see `RelayPaths.socketPath(forHelperExecutablePath:)`).
enum BuildFlavor: String, Sendable, CaseIterable {
    case release
    case debug

    static let infoDictionaryKey = "RelayBuildFlavor"

    init(infoDictionary: [String: Any]?) {
        let raw = (infoDictionary?[Self.infoDictionaryKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self = raw.flatMap(BuildFlavor.init(rawValue:)) ?? .release
    }

    /// The running process's flavor.
    static var current: BuildFlavor {
        BuildFlavor(infoDictionary: Bundle.main.infoDictionary)
    }

    /// Name of this build's own directory under `~/Library/Application Support`.
    var supportDirectoryName: String {
        switch self {
        case .release: "Relay"
        case .debug: "Relay Debug"
        }
    }

    /// User-visible app name.
    var displayName: String { supportDirectoryName }

    /// Only Release adopts hook entries written before the stable helper existed (helper inside
    /// an app bundle or DerivedData). See `StopHookConfigFile`.
    var ownsLegacyHookEntries: Bool { self == .release }
}
