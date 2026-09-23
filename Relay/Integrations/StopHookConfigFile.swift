import Darwin
import Foundation

/// Errors surfaced while reading, validating, or writing an agent's hook config file
/// (`settings.json` / `hooks.json`), or while respecting an agent's own opt-out of hooks. Never
/// carries file contents or paths — only the structural reason.
enum IntegrationInstallerError: Error, Equatable, Sendable {
    /// The config file's top-level JSON value was not an object.
    case configFileNotObject
    /// `hooks` (or `hooks.Stop`) is present but not shaped the way Relay expects, so it cannot be
    /// modified without risking data loss.
    case configFileMalformed
    /// Codex's `config.toml` explicitly disables hooks. Callers surface
    /// `CodexInstaller.hooksDisabledMessage`.
    case hooksDisabledInConfig
}

/// Owns the read -> merge -> write cycle for the single Relay-owned `Stop` command hook inside
/// ONE agent's JSON hook config (Claude Code's `settings.json`, Codex's `hooks.json`).
///
/// Only the Relay-owned command entry — recognised structurally by
/// `isRelayOwnedCommand(_:provider:)` (a `RelayHook` helper basename followed by the exact
/// `--provider <raw>` suffix) — is ever added, rewritten, or removed. Every other key, hook
/// event, matcher group, and `Stop` entry is left untouched.
///
/// Never logs file contents; only structural facts.
struct StopHookConfigFile: Sendable {
    static let helperBasename = "RelayHook"

    let fileURL: URL
    let provider: AgentProvider
    /// Absolute path of the helper THIS build installs (the stable `RelayHook` copy).
    let helperPath: String
    /// `timeout` (seconds) written on a NEWLY appended Relay entry; `nil` writes no timeout key.
    /// An existing Relay entry's keys are never rewritten except `command`.
    let entryTimeoutSeconds: Int?

    init(fileURL: URL, provider: AgentProvider, helperPath: String, entryTimeoutSeconds: Int? = nil) {
        self.fileURL = fileURL
        self.provider = provider
        self.helperPath = helperPath
        self.entryTimeoutSeconds = entryTimeoutSeconds
    }

    // MARK: - Identification

    static func commandSuffix(for provider: AgentProvider) -> String {
        "--provider \(provider.rawValue)"
    }

    /// True when `command` ends with the exact `--provider <raw>` suffix for `provider` and the
    /// executable path before it has basename `RelayHook` — independent of the absolute path, so
    /// an entry installed from a previous app location is still recognised.
    static func isRelayOwnedCommand(_ command: String, provider: AgentProvider) -> Bool {
        let suffix = commandSuffix(for: provider)
        guard command.hasSuffix(suffix) else { return false }
        var pathPortion = String(command.dropLast(suffix.count))
        pathPortion = pathPortion.trimmingCharacters(in: .whitespaces)
        pathPortion = pathPortion.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return (pathPortion as NSString).lastPathComponent == helperBasename
    }

    /// The exact command string Relay installs for `helperPath`.
    static func relayCommand(helperPath: String, provider: AgentProvider) -> String {
        "\"\(helperPath)\" \(commandSuffix(for: provider))"
    }

    // MARK: - Operations

    /// Ensures exactly one Relay `Stop` entry exists, pointed at `helperPath`.
    ///
    /// - No file: creates one containing only the Relay hook.
    /// - Unrelated `Stop` groups: appends a new Relay group; existing groups are untouched.
    /// - A Relay-owned entry with a stale command (e.g. a previous app-bundle path): its
    ///   `command` is rewritten in place, other keys such as `timeout` preserved.
    /// - A Relay-owned entry already matching: nothing changes.
    func install() throws {
        let original = try readIfExists()
        var root = original ?? [:]
        var hooks = try Self.validatedHooks(from: root)
        var stopGroups = try Self.validatedStopGroups(from: hooks)

        let command = Self.relayCommand(helperPath: helperPath, provider: provider)
        let migrated = migratingRelayCommand(in: stopGroups, to: command)
        stopGroups = migrated.stopGroups
        if !migrated.foundRelayEntry {
            stopGroups.append(["hooks": [newEntry(command: command)]])
        }

        hooks["Stop"] = stopGroups
        root["hooks"] = hooks
        try write(root, replacing: original)
    }

    /// Removes only Relay-owned `Stop` entries. A group Relay created (whose only key is
    /// `hooks`) is dropped once empty; groups with other keys keep their remaining entries.
    /// Empty `Stop`/`hooks` containers are removed. A no-op (no write) when nothing matches.
    func uninstall() throws {
        guard let original = try readIfExists() else { return }
        var root = original
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        guard var stopGroups = hooks["Stop"] as? [[String: Any]] else { return }

        var didRemoveAnyRelayEntry = false
        stopGroups = stopGroups.compactMap { group -> [String: Any]? in
            guard let hookEntries = group["hooks"] as? [[String: Any]] else { return group }
            let filteredEntries = hookEntries.filter { !isRelayEntry($0) }
            if filteredEntries.count == hookEntries.count { return group }
            didRemoveAnyRelayEntry = true
            if filteredEntries.isEmpty && group.keys.count == 1 { return nil }
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
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        try write(root, replacing: original)
    }

    /// Whether any `Stop` group currently contains a Relay-owned command for `provider`.
    func containsRelayEntry() throws -> Bool {
        guard let root = try readIfExists(),
              let hooks = root["hooks"] as? [String: Any],
              let stopGroups = hooks["Stop"] as? [[String: Any]] else {
            return false
        }
        return stopGroups.contains { group in
            (group["hooks"] as? [[String: Any]] ?? []).contains(where: isRelayEntry)
        }
    }

    // MARK: - Merge helpers

    private func isRelayEntry(_ entry: [String: Any]) -> Bool {
        guard entry["type"] as? String == "command",
              let command = entry["command"] as? String else { return false }
        return Self.isRelayOwnedCommand(command, provider: provider)
    }

    private func newEntry(command: String) -> [String: Any] {
        var entry: [String: Any] = ["type": "command", "command": command]
        if let entryTimeoutSeconds { entry["timeout"] = entryTimeoutSeconds }
        return entry
    }

    /// Rewrites the `command` of any Relay-owned entry to `command`, leaving every other entry
    /// untouched, and reports whether a Relay-owned entry was found at all.
    private func migratingRelayCommand(
        in stopGroups: [[String: Any]],
        to command: String
    ) -> (stopGroups: [[String: Any]], foundRelayEntry: Bool) {
        var foundRelayEntry = false
        let updatedGroups = stopGroups.map { group -> [String: Any] in
            guard let hookEntries = group["hooks"] as? [[String: Any]] else { return group }
            let updatedEntries = hookEntries.map { entry -> [String: Any] in
                guard isRelayEntry(entry) else { return entry }
                foundRelayEntry = true
                guard entry["command"] as? String != command else { return entry }
                var updatedEntry = entry
                updatedEntry["command"] = command
                return updatedEntry
            }
            var updatedGroup = group
            updatedGroup["hooks"] = updatedEntries
            return updatedGroup
        }
        return (updatedGroups, foundRelayEntry)
    }

    /// `root["hooks"]` as an object, or `[:]` when absent. Throws `.configFileMalformed` when
    /// present but not an object, so install never silently discards it.
    private static func validatedHooks(from root: [String: Any]) throws -> [String: Any] {
        guard let rawHooks = root["hooks"] else { return [:] }
        guard let hooks = rawHooks as? [String: Any] else {
            throw IntegrationInstallerError.configFileMalformed
        }
        return hooks
    }

    /// `hooks["Stop"]` as an array of objects, or `[]` when absent. Throws
    /// `.configFileMalformed` when present but not an array of objects (including an array
    /// containing a non-object element).
    private static func validatedStopGroups(from hooks: [String: Any]) throws -> [[String: Any]] {
        guard let rawStop = hooks["Stop"] else { return [] }
        guard let stopGroups = rawStop as? [[String: Any]] else {
            throw IntegrationInstallerError.configFileMalformed
        }
        return stopGroups
    }

    // MARK: - File I/O

    private func readIfExists() throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return [:] }
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let dict = object as? [String: Any] else {
            throw IntegrationInstallerError.configFileNotObject
        }
        return dict
    }

    /// `original` is what `readIfExists()` returned (`nil` when no file existed). Unused until
    /// Task 2's no-op skip.
    private func write(_ root: [String: Any], replacing original: [String: Any]?) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: fileURL, options: .atomic)
    }
}
