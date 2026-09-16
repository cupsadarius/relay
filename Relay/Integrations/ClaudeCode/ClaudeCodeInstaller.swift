import Foundation

/// Errors surfaced while reading or writing Claude Code's `settings.json`.
enum ClaudeCodeInstallerError: Error, Equatable, Sendable {
    /// The settings file's top-level JSON value was not an object.
    case settingsFileNotObject
    /// The settings file's `hooks` key (or `hooks.Stop` within it) is present
    /// but not shaped the way Relay expects, so it cannot be safely modified
    /// without risking data loss.
    case settingsFileMalformed
}

/// Installs, removes, and reports on the Relay `Stop` hook entry inside
/// Claude Code's user-level `settings.json`.
///
/// This installer only ever touches the single Relay-owned command hook
/// entry it recognizes by a structural signature (see
/// `isRelayOwnedCommand(_:)`): the exact command suffix `--provider
/// claude-code` combined with a `RelayHook` helper basename. Every other key,
/// hook event, and matcher group in the file — including other `Stop` hook
/// entries a person or another tool has configured — is left untouched.
///
/// Never logs settings file contents; only structural facts.
struct ClaudeCodeInstaller {
    private static let commandSuffix = "--provider claude-code"
    private static let helperBasename = "RelayHook"

    private let settingsURL: URL
    private let helperPath: String

    /// - Parameters:
    ///   - baseDirectory: Directory containing `settings.json`. Defaults to
    ///     `CLAUDE_CONFIG_DIR` when set, else `~/.claude`. Tests MUST inject
    ///     a unique temporary directory here rather than relying on the
    ///     default, so the real user config is never read or written.
    ///   - helperPath: Absolute path to the bundled `RelayHook` helper.
    init(
        baseDirectory: URL = ClaudeCodeInstaller.defaultBaseDirectory(),
        helperPath: String = ClaudeCodeInstaller.defaultHelperPath()
    ) {
        self.settingsURL = baseDirectory.appendingPathComponent("settings.json")
        self.helperPath = helperPath
    }

    /// Resolves Claude Code's user-level config directory: `CLAUDE_CONFIG_DIR`
    /// when set and nonempty, else `~/.claude`. `environment` is injectable so
    /// this resolution can be unit tested without touching real process state.
    static func defaultBaseDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["CLAUDE_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }

    /// The stable, app-bundle-independent location `HelperInstaller` copies the bundled
    /// `RelayHook` helper to. Using this (rather than a path inside `Bundle.main.bundleURL`,
    /// which changes across rebuilds/relocations/DerivedData resets) means an installed hook
    /// command keeps working no matter what happens to the app bundle that installed it.
    static func defaultHelperPath() -> String {
        HelperInstaller.stableHelperURL().path
    }

    /// True when `command` is a Relay-owned Claude Code hook command: it ends
    /// with the exact suffix `--provider claude-code`, and the executable
    /// path preceding that suffix has basename `RelayHook`. This is
    /// independent of the absolute path, so a Relay entry installed from a
    /// previous app location is still recognized.
    static func isRelayOwnedCommand(_ command: String) -> Bool {
        guard command.hasSuffix(commandSuffix) else { return false }
        var pathPortion = String(command.dropLast(commandSuffix.count))
        pathPortion = pathPortion.trimmingCharacters(in: .whitespaces)
        pathPortion = pathPortion.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return (pathPortion as NSString).lastPathComponent == helperBasename
    }

    /// The exact command string Relay installs for this installer's helper path.
    var relayCommand: String {
        "\"\(helperPath)\" \(Self.commandSuffix)"
    }

    /// Ensures the Relay `Stop` hook is present in `settings.json`, pointed at this
    /// installer's current `helperPath`.
    ///
    /// - No file exists: creates one containing only the Relay hook.
    /// - Unrelated `Stop` hook group(s) exist: appends a new Relay group;
    ///   existing groups are never deleted or rewritten.
    /// - A Relay-owned entry already exists (recognized by `isRelayOwnedCommand`, regardless
    ///   of its absolute path) but its command differs from `relayCommand` — e.g. it still
    ///   points at a stale, previous-app-bundle path: it is REWRITTEN in place to
    ///   `relayCommand`. This repairs an install left behind by a rebuilt or relocated app
    ///   bundle. Only the Relay-owned entry's `command` value is ever changed.
    /// - A Relay-owned entry already exists and already equals `relayCommand`: no-op
    ///   (idempotent, no duplicate).
    func install() throws {
        var settings = try readSettings()
        var hooks = try Self.validatedHooks(from: settings)
        var stopGroups = try Self.validatedStopGroups(from: hooks)

        let migrated = Self.migratingRelayCommand(in: stopGroups, to: relayCommand)
        stopGroups = migrated.stopGroups

        if !migrated.foundRelayEntry {
            stopGroups.append(["hooks": [["type": "command", "command": relayCommand]]])
        }

        hooks["Stop"] = stopGroups
        settings["hooks"] = hooks
        try writeSettings(settings)
    }

    /// Rewrites the `command` of any Relay-owned hook entry within `stopGroups` to
    /// `relayCommand`, leaving every other entry (Relay-owned or not) byte-for-byte
    /// untouched. Returns the (possibly modified) groups plus whether a Relay-owned entry
    /// was found at all, so the caller knows whether to append a new one.
    private static func migratingRelayCommand(
        in stopGroups: [[String: Any]],
        to relayCommand: String
    ) -> (stopGroups: [[String: Any]], foundRelayEntry: Bool) {
        var foundRelayEntry = false
        let updatedGroups = stopGroups.map { group -> [String: Any] in
            guard let hookEntries = group["hooks"] as? [[String: Any]] else { return group }

            let updatedEntries = hookEntries.map { entry -> [String: Any] in
                guard entry["type"] as? String == "command",
                      let command = entry["command"] as? String,
                      isRelayOwnedCommand(command) else { return entry }
                foundRelayEntry = true
                guard command != relayCommand else { return entry }
                var updatedEntry = entry
                updatedEntry["command"] = relayCommand
                return updatedEntry
            }

            var updatedGroup = group
            updatedGroup["hooks"] = updatedEntries
            return updatedGroup
        }
        return (updatedGroups, foundRelayEntry)
    }

    /// Removes only the Relay-owned `Stop` command hook entry. Every other
    /// hook entry, matcher group, and top-level key is left intact. If
    /// removing the Relay entry empties a group that Relay itself created
    /// (a group whose only key is `hooks`), that now-empty group is dropped;
    /// groups containing other keys are kept with their remaining entries.
    /// A no-op when there is nothing to remove.
    func uninstall() throws {
        guard var settings = try readSettingsIfExists() else { return }
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        guard var stopGroups = hooks["Stop"] as? [[String: Any]] else { return }

        var didRemoveAnyRelayEntry = false

        stopGroups = stopGroups.compactMap { group -> [String: Any]? in
            guard let hookEntries = group["hooks"] as? [[String: Any]] else { return group }

            let filteredEntries = hookEntries.filter { entry in
                guard entry["type"] as? String == "command",
                      let command = entry["command"] as? String,
                      Self.isRelayOwnedCommand(command) else { return true }
                return false
            }

            if filteredEntries.count == hookEntries.count {
                return group
            }

            didRemoveAnyRelayEntry = true

            if filteredEntries.isEmpty && group.keys.count == 1 {
                return nil
            }

            var updatedGroup = group
            updatedGroup["hooks"] = filteredEntries
            return updatedGroup
        }

        guard didRemoveAnyRelayEntry else { return }

        if stopGroups.isEmpty {
            hooks.removeValue(forKey: "Stop")
        } else {
            hooks["Stop"] = stopGroups
        }

        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }

        try writeSettings(settings)
    }

    /// Reports whether the Relay `Stop` hook is currently installed.
    func status() throws -> IntegrationStatus {
        guard let settings = try readSettingsIfExists(),
              let hooks = settings["hooks"] as? [String: Any],
              let stopGroups = hooks["Stop"] as? [[String: Any]] else {
            return .notInstalled
        }

        let present = stopGroups.contains { group in
            Self.commandStrings(in: group).contains { Self.isRelayOwnedCommand($0) }
        }
        return present ? .installedAwaitingFirstEvent : .notInstalled
    }

    /// Returns `settings["hooks"]` as a `[String: Any]`, or an empty dictionary
    /// if the key is absent. Throws `settingsFileMalformed` if the key is
    /// present but not an object, so `install()` never silently discards it.
    private static func validatedHooks(from settings: [String: Any]) throws -> [String: Any] {
        guard let rawHooks = settings["hooks"] else { return [:] }
        guard let hooks = rawHooks as? [String: Any] else {
            throw ClaudeCodeInstallerError.settingsFileMalformed
        }
        return hooks
    }

    /// Returns `hooks["Stop"]` as a `[[String: Any]]`, or an empty array if
    /// the key is absent. Throws `settingsFileMalformed` if the key is
    /// present but not an array of objects (including an array containing a
    /// non-object element), so `install()` never silently discards it.
    private static func validatedStopGroups(from hooks: [String: Any]) throws -> [[String: Any]] {
        guard let rawStop = hooks["Stop"] else { return [] }
        guard let stopGroups = rawStop as? [[String: Any]] else {
            throw ClaudeCodeInstallerError.settingsFileMalformed
        }
        return stopGroups
    }

    private static func commandStrings(in group: [String: Any]) -> [String] {
        guard let hookEntries = group["hooks"] as? [[String: Any]] else { return [] }
        return hookEntries.compactMap { entry in
            guard entry["type"] as? String == "command" else { return nil }
            return entry["command"] as? String
        }
    }

    private func readSettings() throws -> [String: Any] {
        try readSettingsIfExists() ?? [:]
    }

    private func readSettingsIfExists() throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return nil }
        let data = try Data(contentsOf: settingsURL)
        guard !data.isEmpty else { return [:] }
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let dict = object as? [String: Any] else {
            throw ClaudeCodeInstallerError.settingsFileNotObject
        }
        return dict
    }

    private func writeSettings(_ settings: [String: Any]) throws {
        let directory = settingsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsURL, options: .atomic)
    }
}
