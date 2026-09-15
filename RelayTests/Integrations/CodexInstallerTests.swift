import XCTest
@testable import Relay

/// SAFETY: every test in this file points the installer at a unique
/// temporary directory created in `setUp` and removed in `tearDown`. No test
/// may construct `CodexInstaller()` with its default arguments, and no test
/// may read or write the real `~/.codex/hooks.json` or `~/.codex/config.toml`.
final class CodexInstallerTests: XCTestCase {
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

    private func makeInstaller() -> CodexInstaller {
        CodexInstaller(baseDirectory: tempDirectory, helperPath: helperPath)
    }

    private var hooksURL: URL {
        tempDirectory.appendingPathComponent("hooks.json")
    }

    private var configTomlURL: URL {
        tempDirectory.appendingPathComponent("config.toml")
    }

    private func readHooks() throws -> [String: Any] {
        let data = try Data(contentsOf: hooksURL)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private func writeRawHooks(_ json: String) throws {
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        try json.data(using: .utf8)!.write(to: hooksURL)
    }

    private func writeConfigToml(_ contents: String) throws {
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        try contents.data(using: .utf8)!.write(to: configTomlURL)
    }

    private func stopGroups(_ hooksFile: [String: Any]) -> [[String: Any]] {
        (hooksFile["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]] ?? []
    }

    private func commandStrings(_ groups: [[String: Any]]) -> [String] {
        groups.flatMap { group -> [String] in
            let entries = group["hooks"] as? [[String: Any]] ?? []
            return entries.compactMap { $0["command"] as? String }
        }
    }

    private func hookEntries(_ groups: [[String: Any]]) -> [[String: Any]] {
        groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
    }

    // MARK: - Identification logic

    func testRelayOwnedCommandRecognizedRegardlessOfAbsolutePath() {
        XCTAssertTrue(CodexInstaller.isRelayOwnedCommand(
            "\"/Applications/Relay.app/Contents/Helpers/RelayHook\" --provider codex"
        ))
        XCTAssertTrue(CodexInstaller.isRelayOwnedCommand(
            "\"/Users/me/Downloads/Relay 2.app/Contents/Helpers/RelayHook\" --provider codex"
        ))
    }

    func testUnrelatedCommandsAreNotRecognizedAsRelayOwned() {
        XCTAssertFalse(CodexInstaller.isRelayOwnedCommand("echo hello"))
        XCTAssertFalse(CodexInstaller.isRelayOwnedCommand(
            "\"/usr/local/bin/some-other-tool\" --provider codex"
        ))
        XCTAssertFalse(CodexInstaller.isRelayOwnedCommand(
            "\"/Applications/Relay.app/Contents/Helpers/RelayHook\" --provider claude-code"
        ))
        // Same basename, but not the Relay flag suffix.
        XCTAssertFalse(CodexInstaller.isRelayOwnedCommand(
            "\"/Applications/Relay.app/Contents/Helpers/RelayHook\""
        ))
    }

    // MARK: - Base directory resolution

    func testDefaultBaseDirectoryUsesCodexHomeWhenSet() {
        let resolved = CodexInstaller.defaultBaseDirectory(environment: ["CODEX_HOME": "/tmp/fake-codex-home"])
        XCTAssertEqual(resolved.path, "/tmp/fake-codex-home")
    }

    func testDefaultBaseDirectoryFallsBackToDotCodexUnderHome() {
        let resolved = CodexInstaller.defaultBaseDirectory(environment: [:])
        XCTAssertEqual(resolved, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true))
    }

    // MARK: - Install

    func testInstallCreatesHooksFileWhenNoneExists() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: hooksURL.path))

        try makeInstaller().install()

        let hooksFile = try readHooks()
        let groups = stopGroups(hooksFile)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(commandStrings(groups), ["\"\(helperPath)\" --provider codex"])

        let entries = hookEntries(groups)
        XCTAssertEqual(entries.first?["type"] as? String, "command")
        XCTAssertEqual(entries.first?["timeout"] as? Int, 3)
    }

    func testInstallAppendsToExistingUnrelatedStopHookWithoutDeletingIt() throws {
        try writeRawHooks(#"""
        {
          "otherTopLevelKey": true,
          "hooks": {
            "Stop": [
              { "hooks": [ { "type": "command", "command": "/usr/local/bin/notify-stop.sh" } ] }
            ],
            "SessionStart": [
              { "hooks": [ { "type": "command", "command": "/usr/local/bin/audit.sh" } ] }
            ]
          }
        }
        """#)

        try makeInstaller().install()

        let hooksFile = try readHooks()
        XCTAssertEqual(hooksFile["otherTopLevelKey"] as? Bool, true)

        let groups = stopGroups(hooksFile)
        XCTAssertEqual(groups.count, 2)
        let commands = Set(commandStrings(groups))
        XCTAssertEqual(commands, ["/usr/local/bin/notify-stop.sh", "\"\(helperPath)\" --provider codex"])

        let sessionStart = (hooksFile["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]]
        XCTAssertEqual(sessionStart?.count, 1)
    }

    func testInstallIsIdempotentAndDoesNotDuplicate() throws {
        let installer = makeInstaller()
        try installer.install()
        try installer.install()

        let hooksFile = try readHooks()
        let groups = stopGroups(hooksFile)
        let relayCommands = commandStrings(groups).filter { CodexInstaller.isRelayOwnedCommand($0) }
        XCTAssertEqual(relayCommands.count, 1)
    }

    func testInstallThrowsWhenTopLevelIsNotAnObjectAndLeavesFileUntouched() throws {
        try writeRawHooks("[]")
        let bytesBefore = try Data(contentsOf: hooksURL)

        XCTAssertThrowsError(try makeInstaller().install()) { error in
            XCTAssertEqual(error as? CodexInstallerError, .hooksFileNotObject)
        }

        let bytesAfter = try Data(contentsOf: hooksURL)
        XCTAssertEqual(bytesBefore, bytesAfter)
    }

    func testInstallThrowsWhenHooksIsNotAnObjectAndLeavesFileUntouched() throws {
        try writeRawHooks(#"""
        { "hooks": "x" }
        """#)
        let bytesBefore = try Data(contentsOf: hooksURL)

        XCTAssertThrowsError(try makeInstaller().install()) { error in
            XCTAssertEqual(error as? CodexInstallerError, .hooksFileMalformed)
        }

        let bytesAfter = try Data(contentsOf: hooksURL)
        XCTAssertEqual(bytesBefore, bytesAfter)
    }

    func testInstallThrowsWhenHooksStopIsNotAnArrayAndLeavesFileUntouched() throws {
        try writeRawHooks(#"""
        { "hooks": { "Stop": "x" } }
        """#)
        let bytesBefore = try Data(contentsOf: hooksURL)

        XCTAssertThrowsError(try makeInstaller().install()) { error in
            XCTAssertEqual(error as? CodexInstallerError, .hooksFileMalformed)
        }

        let bytesAfter = try Data(contentsOf: hooksURL)
        XCTAssertEqual(bytesBefore, bytesAfter)
    }

    func testInstallThrowsWhenHooksStopContainsNonObjectElementAndLeavesFileUntouched() throws {
        try writeRawHooks(#"""
        {
          "hooks": {
            "Stop": [
              { "hooks": [ { "type": "command", "command": "/usr/local/bin/notify-stop.sh" } ] },
              123
            ]
          }
        }
        """#)
        let bytesBefore = try Data(contentsOf: hooksURL)

        XCTAssertThrowsError(try makeInstaller().install()) { error in
            XCTAssertEqual(error as? CodexInstallerError, .hooksFileMalformed)
        }

        let bytesAfter = try Data(contentsOf: hooksURL)
        XCTAssertEqual(bytesBefore, bytesAfter)
    }

    func testInstallDoesNotDuplicateWhenRelayEntryWasInstalledFromDifferentPath() throws {
        try writeRawHooks(#"""
        {
          "hooks": {
            "Stop": [
              { "hooks": [ { "type": "command", "command": "\"/old/location/RelayHook\" --provider codex" } ] }
            ]
          }
        }
        """#)

        try makeInstaller().install()

        let hooksFile = try readHooks()
        let groups = stopGroups(hooksFile)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(commandStrings(groups), ["\"/old/location/RelayHook\" --provider codex"])
    }

    // MARK: - Uninstall

    func testUninstallRemovesOnlyRelayCommandLeavingOthersIntact() throws {
        try writeRawHooks(#"""
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

        let hooksFile = try readHooks()
        let groups = stopGroups(hooksFile)
        XCTAssertEqual(commandStrings(groups), ["/usr/local/bin/notify-stop.sh"])
        XCTAssertFalse(commandStrings(groups).contains { CodexInstaller.isRelayOwnedCommand($0) })
    }

    func testUninstallDropsEmptyRelayCreatedGroupButKeepsGroupsWithOtherKeys() throws {
        try writeRawHooks(#"""
        {
          "hooks": {
            "Stop": [
              { "matcher": "", "hooks": [ { "type": "command", "command": "\"\#(helperPath)\" --provider codex" } ] }
            ]
          }
        }
        """#)

        try makeInstaller().uninstall()

        let hooksFile = try readHooks()
        let groups = stopGroups(hooksFile)
        // The group had an extra "matcher" key, so it is preserved with an empty hooks array
        // rather than deleted outright.
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual((groups.first?["hooks"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(groups.first?["matcher"] as? String, "")
    }

    func testUninstallRemovesStopKeyEntirelyWhenOnlyRelayGroupExisted() throws {
        try makeInstaller().install()
        try makeInstaller().uninstall()

        let hooksFile = try readHooks()
        let hooks = hooksFile["hooks"] as? [String: Any]
        XCTAssertNil(hooks?["Stop"])
    }

    func testUninstallRemovesHooksKeyWhenNoHookEventsRemain() throws {
        try makeInstaller().install()
        try makeInstaller().uninstall()

        let hooksFile = try readHooks()
        XCTAssertNil(hooksFile["hooks"])
    }

    func testUninstallPreservesUnrelatedHookEventsWhenRemovingHooksKeyWouldNotApply() throws {
        try writeRawHooks(#"""
        {
          "hooks": {
            "Stop": [
              { "hooks": [ { "type": "command", "command": "\"\#(helperPath)\" --provider codex" } ] }
            ],
            "SessionStart": [
              { "hooks": [ { "type": "command", "command": "/usr/local/bin/audit.sh" } ] }
            ]
          }
        }
        """#)

        try makeInstaller().uninstall()

        let hooksFile = try readHooks()
        let hooks = hooksFile["hooks"] as? [String: Any]
        XCTAssertNil(hooks?["Stop"])
        XCTAssertNotNil(hooks?["SessionStart"])
    }

    func testUninstallIsNoOpWhenNoHooksFileExists() throws {
        XCTAssertNoThrow(try makeInstaller().uninstall())
        XCTAssertFalse(FileManager.default.fileExists(atPath: hooksURL.path))
    }

    func testUninstallIsNoOpWhenNoRelayHookIsPresent() throws {
        try writeRawHooks(#"""
        { "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "/usr/local/bin/notify-stop.sh" } ] } ] } }
        """#)

        try makeInstaller().uninstall()

        let hooksFile = try readHooks()
        XCTAssertEqual(commandStrings(stopGroups(hooksFile)), ["/usr/local/bin/notify-stop.sh"])
    }

    func testUninstallDoesNotRewriteFileWhenNoRelayHookIsPresent() throws {
        try writeRawHooks(#"""
        { "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "/usr/local/bin/notify-stop.sh" } ] } ] } }
        """#)
        let bytesBefore = try Data(contentsOf: hooksURL)

        try makeInstaller().uninstall()

        let bytesAfter = try Data(contentsOf: hooksURL)
        XCTAssertEqual(bytesBefore, bytesAfter)
    }

    // MARK: - Status

    func testStatusIsNotInstalledWhenNoHooksFileExists() throws {
        XCTAssertEqual(try makeInstaller().status(), .notInstalled)
    }

    func testStatusIsNotInstalledWhenHooksExistButRelayHookIsAbsent() throws {
        try writeRawHooks(#"""
        { "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "/usr/local/bin/notify-stop.sh" } ] } ] } }
        """#)
        XCTAssertEqual(try makeInstaller().status(), .notInstalled)
    }

    func testStatusIsTrustRequiredAfterInstall() throws {
        let installer = makeInstaller()
        try installer.install()
        XCTAssertEqual(try installer.status(), .installedTrustRequired)
    }

    // MARK: - CODEX_HOME seam

    func testInstallerCanBePointedAtAnyDirectoryViaInjectedBaseDirectory() throws {
        // Demonstrates the seam used to keep every test off the real ~/.codex:
        // baseDirectory is injected directly rather than relying on environment mutation.
        let otherTemp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: otherTemp) }

        let installer = CodexInstaller(baseDirectory: otherTemp, helperPath: helperPath)
        try installer.install()

        XCTAssertTrue(FileManager.default.fileExists(atPath: otherTemp.appendingPathComponent("hooks.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hooksURL.path))
    }

    // MARK: - config.toml `[features] hooks = false`

    func testInstallThrowsAndLeavesHooksFileUntouchedWhenConfigTomlDisablesHooks() throws {
        try writeRawHooks(#"""
        { "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "/usr/local/bin/notify-stop.sh" } ] } ] } }
        """#)
        try writeConfigToml(#"""
        [features]
        hooks = false
        """#)
        let bytesBefore = try Data(contentsOf: hooksURL)

        XCTAssertThrowsError(try makeInstaller().install()) { error in
            XCTAssertEqual(error as? CodexInstallerError, .hooksDisabledInConfig)
        }

        let bytesAfter = try Data(contentsOf: hooksURL)
        XCTAssertEqual(bytesBefore, bytesAfter)
    }

    func testInstallThrowsAndLeavesHooksFileUntouchedWhenConfigTomlDisablesHooksWithCRLFLineEndings() throws {
        try writeRawHooks(#"""
        { "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "/usr/local/bin/notify-stop.sh" } ] } ] } }
        """#)
        try writeConfigToml("[features]\r\nhooks = false\r\n")
        let bytesBefore = try Data(contentsOf: hooksURL)

        XCTAssertThrowsError(try makeInstaller().install()) { error in
            XCTAssertEqual(error as? CodexInstallerError, .hooksDisabledInConfig)
        }

        let bytesAfter = try Data(contentsOf: hooksURL)
        XCTAssertEqual(bytesBefore, bytesAfter)
    }

    func testInstallSucceedsWhenNoConfigTomlExists() throws {
        XCTAssertNoThrow(try makeInstaller().install())
    }

    func testInstallSucceedsWhenConfigTomlHooksIsCommentedOut() throws {
        try writeConfigToml(#"""
        [features]
        # hooks = false
        """#)

        XCTAssertNoThrow(try makeInstaller().install())
    }

    func testInstallSucceedsWhenFeaturesHeaderLineIsCommentedOut() throws {
        try writeConfigToml(#"""
        # [features]
        hooks = false
        """#)

        XCTAssertNoThrow(try makeInstaller().install())
    }

    func testInstallSucceedsWhenHooksFalseIsUnderADifferentTable() throws {
        try writeConfigToml(#"""
        [other]
        hooks = false
        """#)

        XCTAssertNoThrow(try makeInstaller().install())
    }

    func testInstallSucceedsWhenHooksFalseIsUnderANestedFeaturesTable() throws {
        try writeConfigToml(#"""
        [features.experimental]
        hooks = false
        """#)

        XCTAssertNoThrow(try makeInstaller().install())
    }

    func testInstallSucceedsWhenFeaturesHooksIsTrue() throws {
        try writeConfigToml(#"""
        [features]
        hooks = true
        """#)

        XCTAssertNoThrow(try makeInstaller().install())
    }

    func testInstallSucceedsWithInlineCommentAfterHooksFalseIsStillDetectedAsDisabled() throws {
        // An inline trailing comment must not hide a real disable.
        try writeConfigToml(#"""
        [features]
        hooks = false # temporarily disabled
        """#)

        XCTAssertThrowsError(try makeInstaller().install()) { error in
            XCTAssertEqual(error as? CodexInstallerError, .hooksDisabledInConfig)
        }
    }

    func testStatusReportsConfigurationErrorWhenConfigTomlDisablesHooks() throws {
        try writeConfigToml(#"""
        [features]
        hooks = false
        """#)

        XCTAssertEqual(
            try makeInstaller().status(),
            .configurationError(CodexInstaller.hooksDisabledMessage)
        )
    }

    func testTomlExplicitlyDisablesHooksDirectly() {
        XCTAssertTrue(CodexInstaller.tomlExplicitlyDisablesHooks("[features]\nhooks = false\n"))
        XCTAssertFalse(CodexInstaller.tomlExplicitlyDisablesHooks("[features]\n# hooks = false\n"))
        XCTAssertFalse(CodexInstaller.tomlExplicitlyDisablesHooks(""))
        XCTAssertFalse(CodexInstaller.tomlExplicitlyDisablesHooks("[features]\nhooks = true\n"))
    }
}
