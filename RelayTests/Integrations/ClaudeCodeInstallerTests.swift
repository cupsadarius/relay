import XCTest
@testable import Relay

/// SAFETY: every test in this file points the installer at a unique
/// temporary directory created in `setUp` and removed in `tearDown`. No test
/// may construct `ClaudeCodeInstaller()` with its default arguments, and no
/// test may read or write the real `~/.claude/settings.json`.
final class ClaudeCodeInstallerTests: XCTestCase {
    private var tempDirectory: URL!
    private let helperPath = "/Applications/Relay.app/Contents/Helpers/RelayHook"

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        super.tearDown()
    }

    private func makeInstaller() -> ClaudeCodeInstaller {
        ClaudeCodeInstaller(baseDirectory: tempDirectory, helperPath: helperPath)
    }

    private var settingsURL: URL {
        tempDirectory.appendingPathComponent("settings.json")
    }

    private func readSettings() throws -> [String: Any] {
        let data = try Data(contentsOf: settingsURL)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private func writeRawSettings(_ json: String) throws {
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        try json.data(using: .utf8)!.write(to: settingsURL)
    }

    private func stopGroups(_ settings: [String: Any]) -> [[String: Any]] {
        (settings["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]] ?? []
    }

    private func commandStrings(_ groups: [[String: Any]]) -> [String] {
        groups.flatMap { group -> [String] in
            let entries = group["hooks"] as? [[String: Any]] ?? []
            return entries.compactMap { $0["command"] as? String }
        }
    }

    // MARK: - Identification logic

    func testRelayOwnedCommandRecognizedRegardlessOfAbsolutePath() {
        XCTAssertTrue(ClaudeCodeInstaller.isRelayOwnedCommand(
            "\"/Applications/Relay.app/Contents/Helpers/RelayHook\" --provider claude-code"
        ))
        XCTAssertTrue(ClaudeCodeInstaller.isRelayOwnedCommand(
            "\"/Users/me/Downloads/Relay 2.app/Contents/Helpers/RelayHook\" --provider claude-code"
        ))
    }

    func testUnrelatedCommandsAreNotRecognizedAsRelayOwned() {
        XCTAssertFalse(ClaudeCodeInstaller.isRelayOwnedCommand("echo hello"))
        XCTAssertFalse(ClaudeCodeInstaller.isRelayOwnedCommand(
            "\"/usr/local/bin/some-other-tool\" --provider claude-code"
        ))
        XCTAssertFalse(ClaudeCodeInstaller.isRelayOwnedCommand(
            "\"/Applications/Relay.app/Contents/Helpers/RelayHook\" --provider codex"
        ))
        // Same basename, but not the Relay flag suffix.
        XCTAssertFalse(ClaudeCodeInstaller.isRelayOwnedCommand(
            "\"/Applications/Relay.app/Contents/Helpers/RelayHook\""
        ))
    }

    // MARK: - Base directory resolution

    func testDefaultBaseDirectoryUsesClaudeConfigDirWhenSet() {
        let resolved = ClaudeCodeInstaller.defaultBaseDirectory(environment: ["CLAUDE_CONFIG_DIR": "/tmp/fake-claude-config"])
        XCTAssertEqual(resolved.path, "/tmp/fake-claude-config")
    }

    func testDefaultBaseDirectoryFallsBackToDotClaudeUnderHome() {
        let resolved = ClaudeCodeInstaller.defaultBaseDirectory(environment: [:])
        XCTAssertEqual(resolved, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true))
    }

    // MARK: - Install

    func testInstallCreatesSettingsFileWhenNoneExists() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsURL.path))

        try makeInstaller().install()

        let settings = try readSettings()
        let groups = stopGroups(settings)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(commandStrings(groups), ["\"\(helperPath)\" --provider claude-code"])
    }

    func testInstallAppendsToExistingUnrelatedStopHookWithoutDeletingIt() throws {
        try writeRawSettings(#"""
        {
          "otherTopLevelKey": true,
          "hooks": {
            "Stop": [
              { "hooks": [ { "type": "command", "command": "/usr/local/bin/notify-stop.sh" } ] }
            ],
            "PreToolUse": [
              { "matcher": "Bash", "hooks": [ { "type": "command", "command": "/usr/local/bin/audit.sh" } ] }
            ]
          }
        }
        """#)

        try makeInstaller().install()

        let settings = try readSettings()
        XCTAssertEqual(settings["otherTopLevelKey"] as? Bool, true)

        let groups = stopGroups(settings)
        XCTAssertEqual(groups.count, 2)
        let commands = Set(commandStrings(groups))
        XCTAssertEqual(commands, ["/usr/local/bin/notify-stop.sh", "\"\(helperPath)\" --provider claude-code"])

        let preToolUse = (settings["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]]
        XCTAssertEqual(preToolUse?.count, 1)
        XCTAssertEqual(preToolUse?.first?["matcher"] as? String, "Bash")
    }

    func testInstallIsIdempotentAndDoesNotDuplicate() throws {
        let installer = makeInstaller()
        try installer.install()
        try installer.install()

        let settings = try readSettings()
        let groups = stopGroups(settings)
        let relayCommands = commandStrings(groups).filter { ClaudeCodeInstaller.isRelayOwnedCommand($0) }
        XCTAssertEqual(relayCommands.count, 1)
    }

    func testInstallDoesNotDuplicateWhenRelayEntryWasInstalledFromDifferentPath() throws {
        try writeRawSettings(#"""
        {
          "hooks": {
            "Stop": [
              { "hooks": [ { "type": "command", "command": "\"/old/location/RelayHook\" --provider claude-code" } ] }
            ]
          }
        }
        """#)

        try makeInstaller().install()

        let settings = try readSettings()
        let groups = stopGroups(settings)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(commandStrings(groups), ["\"/old/location/RelayHook\" --provider claude-code"])
    }

    // MARK: - Uninstall

    func testUninstallRemovesOnlyRelayCommandLeavingOthersIntact() throws {
        try writeRawSettings(#"""
        {
          "hooks": {
            "Stop": [
              { "hooks": [ { "type": "command", "command": "/usr/local/bin/notify-stop.sh" } ] }
            ]
          }
        }
        """#)
        let installer = makeInstaller()
        try installer.install()
        try installer.uninstall()

        let settings = try readSettings()
        let groups = stopGroups(settings)
        XCTAssertEqual(commandStrings(groups), ["/usr/local/bin/notify-stop.sh"])
        XCTAssertFalse(commandStrings(groups).contains { ClaudeCodeInstaller.isRelayOwnedCommand($0) })
    }

    func testUninstallDropsEmptyRelayCreatedGroupButKeepsGroupsWithOtherKeys() throws {
        try writeRawSettings(#"""
        {
          "hooks": {
            "Stop": [
              { "matcher": "", "hooks": [ { "type": "command", "command": "\"\#(helperPath)\" --provider claude-code" } ] }
            ]
          }
        }
        """#)

        try makeInstaller().uninstall()

        let settings = try readSettings()
        let groups = stopGroups(settings)
        // The group had an extra "matcher" key, so it is preserved with an empty hooks array
        // rather than deleted outright.
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual((groups.first?["hooks"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(groups.first?["matcher"] as? String, "")
    }

    func testUninstallRemovesStopKeyEntirelyWhenOnlyRelayGroupExisted() throws {
        try makeInstaller().install()
        try makeInstaller().uninstall()

        let settings = try readSettings()
        let hooks = settings["hooks"] as? [String: Any]
        XCTAssertNil(hooks?["Stop"])
    }

    func testUninstallRemovesHooksKeyWhenNoHookEventsRemain() throws {
        try makeInstaller().install()
        try makeInstaller().uninstall()

        let settings = try readSettings()
        XCTAssertNil(settings["hooks"])
    }

    func testUninstallPreservesUnrelatedHookEventsWhenRemovingHooksKeyWouldNotApply() throws {
        try writeRawSettings(#"""
        {
          "hooks": {
            "Stop": [
              { "hooks": [ { "type": "command", "command": "\"\#(helperPath)\" --provider claude-code" } ] }
            ],
            "PreToolUse": [
              { "matcher": "Bash", "hooks": [ { "type": "command", "command": "/usr/local/bin/audit.sh" } ] }
            ]
          }
        }
        """#)

        try makeInstaller().uninstall()

        let settings = try readSettings()
        let hooks = settings["hooks"] as? [String: Any]
        XCTAssertNil(hooks?["Stop"])
        XCTAssertNotNil(hooks?["PreToolUse"])
    }

    func testUninstallIsNoOpWhenNoSettingsFileExists() throws {
        XCTAssertNoThrow(try makeInstaller().uninstall())
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsURL.path))
    }

    func testUninstallIsNoOpWhenNoRelayHookIsPresent() throws {
        try writeRawSettings(#"""
        { "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "/usr/local/bin/notify-stop.sh" } ] } ] } }
        """#)

        try makeInstaller().uninstall()

        let settings = try readSettings()
        XCTAssertEqual(commandStrings(stopGroups(settings)), ["/usr/local/bin/notify-stop.sh"])
    }

    // MARK: - Status

    func testStatusIsNotInstalledWhenNoSettingsFileExists() throws {
        XCTAssertEqual(try makeInstaller().status(), .notInstalled)
    }

    func testStatusIsNotInstalledWhenSettingsExistButRelayHookIsAbsent() throws {
        try writeRawSettings(#"""
        { "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "/usr/local/bin/notify-stop.sh" } ] } ] } }
        """#)
        XCTAssertEqual(try makeInstaller().status(), .notInstalled)
    }

    func testStatusReflectsInstalledAfterInstall() throws {
        let installer = makeInstaller()
        try installer.install()
        XCTAssertEqual(try installer.status(), .installedAwaitingFirstEvent)
    }

    // MARK: - CLAUDE_CONFIG_DIR seam

    func testInstallerCanBePointedAtAnyDirectoryViaInjectedBaseDirectory() throws {
        // Demonstrates the seam used to keep every test off the real ~/.claude:
        // baseDirectory is injected directly rather than relying on environment mutation.
        let otherTemp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: otherTemp) }

        let installer = ClaudeCodeInstaller(baseDirectory: otherTemp, helperPath: helperPath)
        try installer.install()

        XCTAssertTrue(FileManager.default.fileExists(atPath: otherTemp.appendingPathComponent("settings.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsURL.path))
    }
}
