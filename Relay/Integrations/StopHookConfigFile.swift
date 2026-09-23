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
/// Ownership is per build (see `EntryOwnership`): this file only ever adds, rewrites, or removes
/// entries pointing at `helperPath` — plus, when `migratesLegacyEntries` (Release), legacy entries
/// from before the stable helper existed. Another build's entry, every non-Relay entry, and every
/// other key, hook event, and matcher group are left untouched, so Debug and Release hooks
/// coexist in one config file.
///
/// Writes are conservative: a merge that changes nothing never touches the file; a symlinked
/// config is updated at its real target (the link survives); the target's POSIX permissions are
/// preserved; and the first modification of a pre-existing file leaves a one-time
/// `<target>.relay-backup` copy beside it.
///
/// Never logs file contents; only structural facts.
struct StopHookConfigFile: Sendable {
    static let helperBasename = "RelayHook"
    static let backupSuffix = ".relay-backup"
    /// Mode for a config file Relay creates from scratch (what `Data.write` produced before under
    /// the default umask).
    static let newFilePermissions = 0o644

    let fileURL: URL
    let provider: AgentProvider
    /// Absolute path of the helper THIS build installs (the stable `RelayHook` copy).
    let helperPath: String
    /// When true (Release only, `BuildFlavor.ownsLegacyHookEntries`), entries whose helper sits
    /// outside every `Application Support/Relay*/bin` (pre-stable-helper installs) are treated as
    /// this build's: migrated on install when no own entry exists, removed on uninstall.
    let migratesLegacyEntries: Bool
    /// `timeout` (seconds) written on a NEWLY appended Relay entry; `nil` writes no timeout key.
    /// An existing Relay entry's keys are never rewritten except `command`.
    let entryTimeoutSeconds: Int?

    init(
        fileURL: URL,
        provider: AgentProvider,
        helperPath: String,
        migratesLegacyEntries: Bool,
        entryTimeoutSeconds: Int? = nil
    ) {
        self.fileURL = fileURL
        self.provider = provider
        self.helperPath = helperPath
        self.migratesLegacyEntries = migratesLegacyEntries
        self.entryTimeoutSeconds = entryTimeoutSeconds
    }

    // MARK: - Identification

    /// Whose entry a Relay hook command is, relative to THIS build.
    enum EntryOwnership: Equatable, Sendable {
        /// Points at exactly this build's stable helper.
        case own
        /// Points at another build's stable helper (`…/Application Support/Relay*/bin/RelayHook`).
        case otherBuild
        /// Points at a `RelayHook` anywhere else (app bundle, DerivedData) — pre-stable installs.
        case legacy
    }

    static func commandSuffix(for provider: AgentProvider) -> String {
        "--provider \(provider.rawValue)"
    }

    /// Structural check only: ends with the exact `--provider <raw>` suffix and the executable
    /// before it has basename `RelayHook`. True for EVERY build's entries.
    static func isRelayHookCommand(_ command: String, provider: AgentProvider) -> Bool {
        helperPath(inCommand: command, provider: provider) != nil
    }

    /// The (unquoted) helper path of a Relay hook command, or `nil` if `command` is not one.
    static func helperPath(inCommand command: String, provider: AgentProvider) -> String? {
        let suffix = commandSuffix(for: provider)
        guard command.hasSuffix(suffix) else { return nil }
        var pathPortion = String(command.dropLast(suffix.count))
        pathPortion = pathPortion.trimmingCharacters(in: .whitespaces)
        pathPortion = pathPortion.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard (pathPortion as NSString).lastPathComponent == helperBasename else { return nil }
        return pathPortion
    }

    /// `nil` for non-Relay commands (including the other provider's).
    func ownership(ofCommand command: String) -> EntryOwnership? {
        guard let path = Self.helperPath(inCommand: command, provider: provider) else { return nil }
        if path == helperPath { return .own }
        return RelayPaths.isStableHelperPath(path) ? .otherBuild : .legacy
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
        let hasOwnEntry = stopGroups.contains { group in
            Self.entries(in: group).contains { ownership(ofEntry: $0) == .own }
        }
        let adoptsLegacy = migratesLegacyEntries && !hasOwnEntry
        func pointedAtUs(_ entry: [String: Any]) -> [String: Any] {
            guard entry["command"] as? String != command else { return entry }
            var updatedEntry = entry
            updatedEntry["command"] = command
            return updatedEntry
        }
        var rewroteAny = false
        var migratedLegacy = false
        stopGroups = stopGroups.compactMap { group -> [String: Any]? in
            guard let hookEntries = group["hooks"] as? [[String: Any]] else { return group }
            let updatedEntries = hookEntries.compactMap { entry -> [String: Any]? in
                switch ownership(ofEntry: entry) {
                case .own:
                    rewroteAny = true
                    return pointedAtUs(entry)
                case .legacy where adoptsLegacy:
                    // The first legacy entry becomes ours in place (keeping its timeout etc.).
                    // Any further legacy entries would be duplicates that each fire the hook, so
                    // they are dropped.
                    guard !migratedLegacy else { return nil }
                    migratedLegacy = true
                    rewroteAny = true
                    return pointedAtUs(entry)
                default:
                    return entry
                }
            }
            // A group emptied by dropping duplicates is removed only if it has no other keys
            // (for example a matcher), mirroring `uninstall()`.
            if updatedEntries.isEmpty, !hookEntries.isEmpty, group.keys.allSatisfy({ $0 == "hooks" }) {
                return nil
            }
            var updatedGroup = group
            updatedGroup["hooks"] = updatedEntries
            return updatedGroup
        }
        if !rewroteAny {
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
            let filteredEntries = hookEntries.filter { !isRemovable($0) }
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
            Self.entries(in: group).contains { ownership(ofEntry: $0) == .own }
        }
    }

    // MARK: - Merge helpers

    private func ownership(ofEntry entry: [String: Any]) -> EntryOwnership? {
        guard entry["type"] as? String == "command",
              let command = entry["command"] as? String else { return nil }
        return ownership(ofCommand: command)
    }

    /// Entries uninstall may remove: our own, plus legacy ones when this build adopts them.
    private func isRemovable(_ entry: [String: Any]) -> Bool {
        switch ownership(ofEntry: entry) {
        case .own: true
        case .legacy: migratesLegacyEntries
        case .otherBuild, nil: false
        }
    }

    private static func entries(in group: [String: Any]) -> [[String: Any]] {
        group["hooks"] as? [[String: Any]] ?? []
    }

    private func newEntry(command: String) -> [String: Any] {
        var entry: [String: Any] = ["type": "command", "command": command]
        if let entryTimeoutSeconds { entry["timeout"] = entryTimeoutSeconds }
        return entry
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

    private func write(_ root: [String: Any], replacing original: [String: Any]?) throws {
        if let original, NSDictionary(dictionary: original).isEqual(to: root) { return }

        let fileManager = FileManager.default
        let target = try Self.resolvedWriteTarget(for: fileURL)
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

        let existingPermissions = (try? fileManager.attributesOfItem(atPath: target.path))?[.posixPermissions] as? NSNumber
        if existingPermissions != nil {
            try Self.backUpOnce(target)
        }

        // `.sortedKeys` deliberately kept: Swift dictionary order is randomly seeded per process,
        // so without it every modifying write would reshuffle the user's keys.
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try Self.atomicallyReplace(
            target,
            with: data,
            permissions: existingPermissions?.intValue ?? Self.newFilePermissions
        )
    }

    /// Follows `url` through at most 16 symlink hops (absolute or relative destinations) and
    /// returns the real file to write. A non-link (or missing path) is returned unchanged.
    /// Throws `POSIXError(.ELOOP)` — without writing anything — if it is still a symlink after
    /// 16 hops, rather than risk writing through a symlink loop.
    static func resolvedWriteTarget(for url: URL) throws -> URL {
        var current = url
        for _ in 0..<16 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path) else {
                return current
            }
            current = destination.hasPrefix("/")
                ? URL(fileURLWithPath: destination)
                : current.deletingLastPathComponent().appendingPathComponent(destination)
        }
        throw POSIXError(.ELOOP)
    }

    /// Copies `target` to `<target>.relay-backup` unless that backup already exists.
    private static func backUpOnce(_ target: URL) throws {
        let backup = URL(fileURLWithPath: target.path + backupSuffix)
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        try FileManager.default.copyItem(at: target, to: backup)
    }

    /// Writes `data` to a private sibling temp file, `fsync`s it, then `rename(2)`s it over
    /// `target`: readers never observe a partial file, and the mode is right from the very first
    /// byte on disk — the file is created (`O_EXCL`, mode `0600`) and `fchmod`'d to `permissions`
    /// before any content is written, so a restrictive target (e.g. `0600`) is never briefly
    /// exposed at a looser umask-filtered mode. On ANY failure the temp file descriptor is closed
    /// and the temp file removed before the error is thrown; `target` is never touched.
    private static func atomicallyReplace(_ target: URL, with data: Data, permissions: Int) throws {
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).relay-\(UUID().uuidString)")

        let fd = temporary.path.withCString { path in
            open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        }
        guard fd >= 0 else {
            throw errnoError()
        }

        do {
            // `open`'s mode argument is filtered by the process umask; `fchmod` sets the exact
            // mode regardless, so the file is never briefly world- or group-readable (or, for a
            // looser target, briefly MORE restrictive than it should end up).
            guard fchmod(fd, mode_t(permissions)) == 0 else { throw errnoError() }
            try writeAll(data, to: fd)
            guard fsync(fd) == 0 else { throw errnoError() }
        } catch {
            close(fd)
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        close(fd)

        guard rename(temporary.path, target.path) == 0 else {
            let error = errnoError()
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// Writes every byte of `data` to `fd`, looping over short writes and retrying on `EINTR`.
    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress, buffer.count > 0 else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw errnoError()
                }
            }
        }
    }

    private static func errnoError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
