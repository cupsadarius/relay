import Foundation

/// Installs, removes, and reports on the Relay `Stop` hook entry inside Claude Code's
/// user-level `settings.json`. The JSON merge/write lives in `StopHookConfigFile`; this type only
/// adds what is Claude-Code-specific: the `CLAUDE_CONFIG_DIR` base directory, the file name, and
/// the `.installedAwaitingFirstEvent` status.
///
/// Never logs settings file contents; only structural facts.
struct ClaudeCodeInstaller {
    private let configFile: StopHookConfigFile

    /// - Parameters:
    ///   - baseDirectory: Directory containing `settings.json`. Defaults to
    ///     `CLAUDE_CONFIG_DIR` when set, else `~/.claude`. Tests MUST inject a unique temporary
    ///     directory here so the real user config is never read or written.
    ///   - helperPath: Absolute path to the stable `RelayHook` helper.
    init(
        baseDirectory: URL = ClaudeCodeInstaller.defaultBaseDirectory(),
        helperPath: String = ClaudeCodeInstaller.defaultHelperPath()
    ) {
        self.configFile = StopHookConfigFile(
            fileURL: baseDirectory.appendingPathComponent("settings.json"),
            provider: .claudeCode,
            helperPath: helperPath
        )
    }

    /// `CLAUDE_CONFIG_DIR` when set and nonempty, else `~/.claude`.
    static func defaultBaseDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["CLAUDE_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }

    /// The stable, app-bundle-independent helper location `HelperInstaller` maintains.
    static func defaultHelperPath() -> String {
        HelperInstaller.stableHelperURL().path
    }

    static func isRelayOwnedCommand(_ command: String) -> Bool {
        StopHookConfigFile.isRelayOwnedCommand(command, provider: .claudeCode)
    }

    func install() throws {
        try configFile.install()
    }

    func uninstall() throws {
        try configFile.uninstall()
    }

    func status() throws -> IntegrationStatus {
        try configFile.containsRelayEntry() ? .installedAwaitingFirstEvent : .notInstalled
    }
}
