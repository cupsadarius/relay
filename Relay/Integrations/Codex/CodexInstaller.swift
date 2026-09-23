import Foundation

/// Installs, removes, and reports on the Relay `Stop` hook entry inside Codex's user-level
/// `hooks.json`. The JSON merge/write lives in `StopHookConfigFile`; this type only adds what is
/// Codex-specific: the `CODEX_HOME` base directory, `timeout: 3` on a new entry, the
/// `config.toml` opt-out precheck, and the `.installedTrustRequired` status.
///
/// Codex requires non-managed hooks to be trusted via `/hooks` before they run. This installer
/// never edits that trust state and never passes `--dangerously-bypass-hook-trust`.
///
/// Never logs hooks file or config.toml contents; only structural facts.
struct CodexInstaller {
    /// Settings copy shown once install succeeds but Codex has not yet granted trust to the
    /// Relay hook command.
    static let trustRequiredMessage = "Run /hooks in Codex and trust the Relay hook."
    /// Settings copy shown when `config.toml` explicitly disables hooks.
    static let hooksDisabledMessage = "Codex hooks are disabled in config.toml."
    /// Seconds Codex waits for a newly installed Relay hook entry.
    static let hookTimeoutSeconds = 3

    private let configFile: StopHookConfigFile
    private let configTomlURL: URL

    /// - Parameters:
    ///   - baseDirectory: Directory containing `hooks.json` and `config.toml`. Defaults to
    ///     `CODEX_HOME` when set, else `~/.codex`. Tests MUST inject a unique temporary directory.
    ///   - helperPath: Absolute path to the stable `RelayHook` helper.
    init(
        baseDirectory: URL = CodexInstaller.defaultBaseDirectory(),
        helperPath: String = CodexInstaller.defaultHelperPath(),
        migratesLegacyEntries: Bool = BuildFlavor.current.ownsLegacyHookEntries
    ) {
        self.configFile = StopHookConfigFile(
            fileURL: baseDirectory.appendingPathComponent("hooks.json"),
            provider: .codex,
            helperPath: helperPath,
            migratesLegacyEntries: migratesLegacyEntries,
            entryTimeoutSeconds: Self.hookTimeoutSeconds
        )
        self.configTomlURL = baseDirectory.appendingPathComponent("config.toml")
    }

    /// `CODEX_HOME` when set and nonempty, else `~/.codex`.
    static func defaultBaseDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["CODEX_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    /// The stable, app-bundle-independent helper location `HelperInstaller` maintains.
    static func defaultHelperPath() -> String {
        HelperInstaller.stableHelperURL().path
    }

    /// Structural: true for any build's Relay hook command for this provider.
    static func isRelayHookCommand(_ command: String) -> Bool {
        StopHookConfigFile.isRelayHookCommand(command, provider: .codex)
    }

    /// Throws `.hooksDisabledInConfig` without touching `hooks.json` when `config.toml`
    /// explicitly disables hooks; otherwise delegates to `StopHookConfigFile.install`.
    func install() throws {
        if try configExplicitlyDisablesHooks() {
            throw IntegrationInstallerError.hooksDisabledInConfig
        }
        try configFile.install()
    }

    func uninstall() throws {
        try configFile.uninstall()
    }

    /// `.configurationError(hooksDisabledMessage)` when `config.toml` disables hooks, else
    /// `.installedTrustRequired` when the Relay entry is present, else `.notInstalled`.
    func status() throws -> IntegrationStatus {
        if try configExplicitlyDisablesHooks() {
            return .configurationError(Self.hooksDisabledMessage)
        }
        return try configFile.containsRelayEntry() ? .installedTrustRequired : .notInstalled
    }

    // MARK: - config.toml (`[features] hooks = false`)

    /// True when `config.toml` (under this installer's base directory) explicitly disables hooks
    /// via any of the forms `tomlExplicitlyDisablesHooks(_:)` recognises. A missing file, a
    /// commented-out line, `hooks = false` under a different or nested table, or any other value
    /// never counts.
    private func configExplicitlyDisablesHooks() throws -> Bool {
        guard FileManager.default.fileExists(atPath: configTomlURL.path) else { return false }
        let text = try String(contentsOf: configTomlURL, encoding: .utf8)
        return Self.tomlExplicitlyDisablesHooks(text)
    }

    /// A targeted scan — not a full TOML parser — for the three ways `config.toml` can turn
    /// Codex hooks off:
    ///
    /// - `[features]` table, then `hooks = false`
    /// - root-level dotted key `features.hooks = false` (whitespace around `.` allowed)
    /// - root-level inline table `features = { …, hooks = false, … }`
    ///
    /// Comments (`#`, respecting quotes) are stripped first. `hooks = false` under any other table
    /// (`[features.sub]`, `[[features]]`, `[other]`) never counts, and neither do dotted or inline
    /// forms inside a non-root table. Inline-table values containing commas inside strings are
    /// not handled (not produced by Codex's own config).
    static func tomlExplicitlyDisablesHooks(_ text: String) -> Bool {
        var currentTable = "" // "" is the root table.
        for rawLine in text.components(separatedBy: .newlines) {
            let line = stripTomlComment(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                // `[features]` -> "features"; `[[features]]` -> "[features]" (never matches).
                currentTable = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                continue
            }

            guard let equalsIndex = line.firstIndex(of: "=") else { continue }
            let key = normalizedDottedKey(String(line[line.startIndex..<equalsIndex]))
            let value = line[line.index(after: equalsIndex)...].trimmingCharacters(in: .whitespaces)

            switch currentTable {
            case "features":
                if key == "hooks" && value == "false" { return true }
            case "":
                if key == "features.hooks" && value == "false" { return true }
                if key == "features" && inlineTableDisablesHooks(value) { return true }
            default:
                continue
            }
        }
        return false
    }

    /// `"features . hooks "` -> `"features.hooks"`.
    private static func normalizedDottedKey(_ rawKey: String) -> String {
        rawKey
            .split(separator: ".", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: ".")
    }

    /// True for `{ …, hooks = false, … }`.
    private static func inlineTableDisablesHooks(_ value: String) -> Bool {
        guard value.hasPrefix("{"), value.hasSuffix("}") else { return false }
        let body = value.dropFirst().dropLast()
        return body.split(separator: ",").contains { pair in
            guard let equalsIndex = pair.firstIndex(of: "=") else { return false }
            let key = normalizedDottedKey(String(pair[pair.startIndex..<equalsIndex]))
            let entryValue = pair[pair.index(after: equalsIndex)...].trimmingCharacters(in: .whitespaces)
            return key == "hooks" && entryValue == "false"
        }
    }

    /// Strips a trailing `#` comment from a single TOML line, respecting (naively) single- and
    /// double-quoted strings so a `#` inside a quoted value is never mistaken for a comment
    /// marker.
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
}
