import Foundation

/// Errors surfaced while reading or writing Codex's `hooks.json`, or while
/// respecting Codex's own opt-out of hooks in `config.toml`.
enum CodexInstallerError: Error, Equatable, Sendable {
    /// The hooks file's top-level JSON value was not an object.
    case hooksFileNotObject
    /// The hooks file's `hooks` key (or `hooks.Stop` within it) is present
    /// but not shaped the way Relay expects, so it cannot be safely modified
    /// without risking data loss.
    case hooksFileMalformed
    /// `config.toml` explicitly contains `[features]` with `hooks = false`.
    /// Install refuses to touch `hooks.json` (or trust state) when this is
    /// set; the caller should surface `CodexInstaller.hooksDisabledMessage`.
    case hooksDisabledInConfig
}

/// Installs, removes, and reports on the Relay `Stop` hook entry inside
/// Codex's user-level `hooks.json`.
///
/// This installer only ever touches the single Relay-owned command hook
/// entry it recognizes by a structural signature (see
/// `isRelayOwnedCommand(_:)`): the exact command suffix `--provider codex`
/// combined with a `RelayHook` helper basename. Every other key, hook event,
/// and matcher group in the file — including other `Stop` hook entries a
/// person or another tool has configured — is left untouched.
///
/// Codex requires non-managed hooks to be trusted via `/hooks` before they
/// run. This installer never edits that trust state and never passes
/// `--dangerously-bypass-hook-trust`; `status()` reports
/// `.installedTrustRequired` until Relay observes a first valid event
/// (tracked by `IntegrationManager`, added separately).
///
/// Never logs hooks file or config.toml contents; only structural facts.
struct CodexInstaller {
    private static let commandSuffix = "--provider codex"
    private static let helperBasename = "RelayHook"

    /// Settings copy shown once install succeeds but Codex has not yet
    /// granted trust to the Relay hook command.
    static let trustRequiredMessage = "Installed. Open /hooks in Codex and trust the Relay hook."
    /// Settings copy shown when `config.toml` explicitly disables hooks.
    static let hooksDisabledMessage = "Codex hooks are disabled in config.toml."

    private let hooksURL: URL
    private let configTomlURL: URL
    private let helperPath: String

    /// - Parameters:
    ///   - baseDirectory: Directory containing `hooks.json` and
    ///     `config.toml`. Defaults to `CODEX_HOME` when set, else `~/.codex`.
    ///     Tests MUST inject a unique temporary directory here rather than
    ///     relying on the default, so the real user config is never read or
    ///     written.
    ///   - helperPath: Absolute path to the bundled `RelayHook` helper.
    init(
        baseDirectory: URL = CodexInstaller.defaultBaseDirectory(),
        helperPath: String = CodexInstaller.defaultHelperPath()
    ) {
        self.hooksURL = baseDirectory.appendingPathComponent("hooks.json")
        self.configTomlURL = baseDirectory.appendingPathComponent("config.toml")
        self.helperPath = helperPath
    }

    /// Resolves Codex's user-level config directory: `CODEX_HOME` when set
    /// and nonempty, else `~/.codex`. `environment` is injectable so this
    /// resolution can be unit tested without touching real process state.
    static func defaultBaseDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["CODEX_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    /// The stable, app-bundle-independent location `HelperInstaller` copies the bundled
    /// `RelayHook` helper to. Using this (rather than a path inside `Bundle.main.bundleURL`,
    /// which changes across rebuilds/relocations/DerivedData resets) means an installed hook
    /// command keeps working no matter what happens to the app bundle that installed it.
    static func defaultHelperPath() -> String {
        HelperInstaller.stableHelperURL().path
    }

    /// True when `command` is a Relay-owned Codex hook command: it ends with
    /// the exact suffix `--provider codex`, and the executable path
    /// preceding that suffix has basename `RelayHook`. This is independent
    /// of the absolute path, so a Relay entry installed from a previous app
    /// location is still recognized.
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

    /// Ensures the Relay `Stop` hook is present in `hooks.json`, pointed at this installer's
    /// current `helperPath`.
    ///
    /// - `config.toml` explicitly disables hooks: throws
    ///   `hooksDisabledInConfig` without touching `hooks.json`.
    /// - No file exists: creates one containing only the Relay hook.
    /// - Unrelated `Stop` hook group(s) exist: appends a new Relay group;
    ///   existing groups are never deleted or rewritten.
    /// - A Relay-owned entry already exists (recognized by `isRelayOwnedCommand`, regardless
    ///   of its absolute path) but its command differs from `relayCommand` — e.g. it still
    ///   points at a stale, previous-app-bundle path: it is REWRITTEN in place to
    ///   `relayCommand`, preserving its other keys (e.g. `timeout`). This repairs an install
    ///   left behind by a rebuilt or relocated app bundle. Only the Relay-owned entry's
    ///   `command` value is ever changed.
    /// - A Relay-owned entry already exists and already equals `relayCommand`: no-op
    ///   (idempotent, no duplicate).
    func install() throws {
        if try configExplicitlyDisablesHooks() {
            throw CodexInstallerError.hooksDisabledInConfig
        }

        var hooksFile = try readHooksFile()
        var hooks = try Self.validatedHooks(from: hooksFile)
        var stopGroups = try Self.validatedStopGroups(from: hooks)

        let migrated = Self.migratingRelayCommand(in: stopGroups, to: relayCommand)
        stopGroups = migrated.stopGroups

        if !migrated.foundRelayEntry {
            stopGroups.append([
                "hooks": [
                    ["type": "command", "command": relayCommand, "timeout": 3]
                ]
            ])
        }

        hooks["Stop"] = stopGroups
        hooksFile["hooks"] = hooks
        try writeHooksFile(hooksFile)
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
    /// A no-op (including no write) when there is nothing to remove.
    func uninstall() throws {
        guard var hooksFile = try readHooksFileIfExists() else { return }
        guard var hooks = hooksFile["hooks"] as? [String: Any] else { return }
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
            hooksFile.removeValue(forKey: "hooks")
        } else {
            hooksFile["hooks"] = hooks
        }

        try writeHooksFile(hooksFile)
    }

    /// Reports whether the Relay `Stop` hook is currently installed, and
    /// whether Codex's own configuration blocks it outright.
    ///
    /// - `config.toml` explicitly disables hooks: `.configurationError`
    ///   with `hooksDisabledMessage`, regardless of `hooks.json` contents.
    /// - The Relay entry is present: `.installedTrustRequired` (Codex
    ///   requires the operator to trust non-managed hooks via `/hooks`
    ///   before Relay will start receiving events; nothing here edits that
    ///   trust state).
    /// - Otherwise: `.notInstalled`.
    func status() throws -> IntegrationStatus {
        if try configExplicitlyDisablesHooks() {
            return .configurationError(Self.hooksDisabledMessage)
        }

        guard let hooksFile = try readHooksFileIfExists(),
              let hooks = hooksFile["hooks"] as? [String: Any],
              let stopGroups = hooks["Stop"] as? [[String: Any]] else {
            return .notInstalled
        }

        let present = stopGroups.contains { group in
            Self.commandStrings(in: group).contains { Self.isRelayOwnedCommand($0) }
        }
        return present ? .installedTrustRequired : .notInstalled
    }

    // MARK: - config.toml (`[features] hooks = false`)

    /// True when `config.toml` (under this installer's base directory)
    /// explicitly contains a `[features]` table with `hooks = false`. A
    /// missing file, a commented-out line, `hooks = false` under a
    /// different or nested table, or any other value never counts.
    private func configExplicitlyDisablesHooks() throws -> Bool {
        guard FileManager.default.fileExists(atPath: configTomlURL.path) else { return false }
        let text = try String(contentsOf: configTomlURL, encoding: .utf8)
        return Self.tomlExplicitlyDisablesHooks(text)
    }

    /// A targeted scan for `[features]\nhooks = false` — not a full TOML
    /// parser. It tracks the most recently opened `[table]` header and looks
    /// for a `hooks = false` assignment while that table is `features`
    /// exactly (not `features.sub`, not `[[features]]`). Comments (`#`,
    /// respecting quoted strings) are stripped from each line before it is
    /// inspected, so a commented-out header or assignment is never matched.
    static func tomlExplicitlyDisablesHooks(_ text: String) -> Bool {
        var inFeaturesTable = false
        for rawLine in text.components(separatedBy: .newlines) {
            let line = stripTomlComment(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                let tableName = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                inFeaturesTable = (tableName == "features")
                continue
            }

            guard inFeaturesTable, let equalsIndex = line.firstIndex(of: "=") else { continue }

            let key = line[line.startIndex..<equalsIndex].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equalsIndex)...].trimmingCharacters(in: .whitespaces)
            if key == "hooks" && value == "false" {
                return true
            }
        }
        return false
    }

    /// Strips a trailing `#` comment from a single TOML line, respecting
    /// (naively) single- and double-quoted strings so a `#` inside a quoted
    /// value is never mistaken for a comment marker.
    private static func stripTomlComment(_ line: String) -> String {
        var result = ""
        var quoteChar: Character?
        for char in line {
            if let quote = quoteChar {
                result.append(char)
                if char == quote { quoteChar = nil }
            } else if char == "#" {
                break
            } else if char == "\"" || char == "'" {
                quoteChar = char
                result.append(char)
            } else {
                result.append(char)
            }
        }
        return result
    }

    // MARK: - hooks.json validation helpers

    /// Returns `hooksFile["hooks"]` as a `[String: Any]`, or an empty
    /// dictionary if the key is absent. Throws `hooksFileMalformed` if the
    /// key is present but not an object, so `install()` never silently
    /// discards it.
    private static func validatedHooks(from hooksFile: [String: Any]) throws -> [String: Any] {
        guard let rawHooks = hooksFile["hooks"] else { return [:] }
        guard let hooks = rawHooks as? [String: Any] else {
            throw CodexInstallerError.hooksFileMalformed
        }
        return hooks
    }

    /// Returns `hooks["Stop"]` as a `[[String: Any]]`, or an empty array if
    /// the key is absent. Throws `hooksFileMalformed` if the key is present
    /// but not an array of objects (including an array containing a
    /// non-object element), so `install()` never silently discards it.
    private static func validatedStopGroups(from hooks: [String: Any]) throws -> [[String: Any]] {
        guard let rawStop = hooks["Stop"] else { return [] }
        guard let stopGroups = rawStop as? [[String: Any]] else {
            throw CodexInstallerError.hooksFileMalformed
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

    private func readHooksFile() throws -> [String: Any] {
        try readHooksFileIfExists() ?? [:]
    }

    private func readHooksFileIfExists() throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: hooksURL.path) else { return nil }
        let data = try Data(contentsOf: hooksURL)
        guard !data.isEmpty else { return [:] }
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let dict = object as? [String: Any] else {
            throw CodexInstallerError.hooksFileNotObject
        }
        return dict
    }

    private func writeHooksFile(_ hooksFile: [String: Any]) throws {
        let directory = hooksURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: hooksFile, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: hooksURL, options: .atomic)
    }
}
