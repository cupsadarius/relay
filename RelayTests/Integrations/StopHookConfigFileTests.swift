import XCTest
@testable import Relay

/// SAFETY: every test targets a unique temporary directory created in `setUp` and removed in
/// `tearDown`. Nothing here may read or write the real `~/.claude` or `~/.codex`.
final class StopHookConfigFileTests: XCTestCase {
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

    private var fileURL: URL {
        tempDirectory.appendingPathComponent("hooks-config.json")
    }

    private func makeFile(provider: AgentProvider = .claudeCode, timeout: Int? = nil) -> StopHookConfigFile {
        StopHookConfigFile(fileURL: fileURL, provider: provider, helperPath: helperPath, entryTimeoutSeconds: timeout)
    }

    private func relayCommand(_ provider: AgentProvider = .claudeCode) -> String {
        "\"\(helperPath)\" --provider \(provider.rawValue)"
    }

    private func readJSON() throws -> [String: Any] {
        let data = try Data(contentsOf: fileURL)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private func writeRaw(_ json: String) throws {
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        try json.data(using: .utf8)!.write(to: fileURL)
    }

    private func stopGroups(_ root: [String: Any]) -> [[String: Any]] {
        (root["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]] ?? []
    }

    private func hookEntries(_ groups: [[String: Any]]) -> [[String: Any]] {
        groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
    }

    private func commandStrings(_ groups: [[String: Any]]) -> [String] {
        hookEntries(groups).compactMap { $0["command"] as? String }
    }

    // MARK: - Identification

    func testRelayOwnedCommandIsProviderSpecificAndPathIndependent() {
        XCTAssertTrue(StopHookConfigFile.isRelayOwnedCommand(
            "\"/Users/me/Downloads/Relay 2.app/Contents/Helpers/RelayHook\" --provider claude-code",
            provider: .claudeCode
        ))
        XCTAssertFalse(StopHookConfigFile.isRelayOwnedCommand(
            "\"/Applications/Relay.app/Contents/Helpers/RelayHook\" --provider claude-code",
            provider: .codex
        ))
        XCTAssertFalse(StopHookConfigFile.isRelayOwnedCommand(
            "\"/usr/local/bin/other\" --provider codex",
            provider: .codex
        ))
    }

    // MARK: - Install

    func testInstallCreatesFileWithOnlyTheRelayEntry() throws {
        try makeFile().install()

        let entries = hookEntries(stopGroups(try readJSON()))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?["type"] as? String, "command")
        XCTAssertEqual(entries.first?["command"] as? String, relayCommand())
        XCTAssertNil(entries.first?["timeout"])
    }

    func testInstallWritesTimeoutOnNewEntryWhenConfigured() throws {
        try makeFile(provider: .codex, timeout: 3).install()

        let entries = hookEntries(stopGroups(try readJSON()))
        XCTAssertEqual(entries.first?["command"] as? String, relayCommand(.codex))
        XCTAssertEqual(entries.first?["timeout"] as? Int, 3)
    }

    func testInstallAppendsToExistingUnrelatedStopHookWithoutDeletingIt() throws {
        try writeRaw(#"""
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

        try makeFile().install()

        let root = try readJSON()
        XCTAssertEqual(root["otherTopLevelKey"] as? Bool, true)
        let groups = stopGroups(root)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(Set(commandStrings(groups)), ["/usr/local/bin/notify-stop.sh", relayCommand()])
        let preToolUse = (root["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]]
        XCTAssertEqual(preToolUse?.first?["matcher"] as? String, "Bash")
    }

    func testInstallIsIdempotentAndDoesNotDuplicate() throws {
        let file = makeFile()
        try file.install()
        try file.install()

        XCTAssertEqual(commandStrings(stopGroups(try readJSON())), [relayCommand()])
    }

    func testInstallTwiceProducesIdenticalBytes() throws {
        let file = makeFile()
        try file.install()
        let before = try Data(contentsOf: fileURL)

        try file.install()

        XCTAssertEqual(try Data(contentsOf: fileURL), before)
    }

    func testInstallThrowsWhenTopLevelIsNotAnObjectAndLeavesFileUntouched() throws {
        try writeRaw("[]")
        let before = try Data(contentsOf: fileURL)

        XCTAssertThrowsError(try makeFile().install()) { error in
            XCTAssertEqual(error as? IntegrationInstallerError, .configFileNotObject)
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), before)
    }

    func testInstallThrowsWhenHooksIsNotAnObjectAndLeavesFileUntouched() throws {
        try writeRaw(#"{ "hooks": "x" }"#)
        let before = try Data(contentsOf: fileURL)

        XCTAssertThrowsError(try makeFile().install()) { error in
            XCTAssertEqual(error as? IntegrationInstallerError, .configFileMalformed)
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), before)
    }

    func testInstallThrowsWhenHooksStopIsNotAnArrayAndLeavesFileUntouched() throws {
        try writeRaw(#"{ "hooks": { "Stop": "x" } }"#)
        let before = try Data(contentsOf: fileURL)

        XCTAssertThrowsError(try makeFile().install()) { error in
            XCTAssertEqual(error as? IntegrationInstallerError, .configFileMalformed)
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), before)
    }

    func testInstallThrowsWhenHooksStopContainsNonObjectElementAndLeavesFileUntouched() throws {
        try writeRaw(#"""
        { "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "/usr/local/bin/notify-stop.sh" } ] }, 123 ] } }
        """#)
        let before = try Data(contentsOf: fileURL)

        XCTAssertThrowsError(try makeFile().install()) { error in
            XCTAssertEqual(error as? IntegrationInstallerError, .configFileMalformed)
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), before)
    }

    func testInstallMigratesStaleEntryInPlacePreservingItsOtherKeys() throws {
        try writeRaw(#"""
        {
          "hooks": {
            "Stop": [
              { "hooks": [ { "type": "command", "command": "/usr/local/bin/notify-stop.sh" } ] },
              { "hooks": [ { "type": "command", "command": "\"/old/App.app/Contents/Helpers/RelayHook\" --provider codex", "timeout": 7 } ] }
            ]
          }
        }
        """#)

        try makeFile(provider: .codex, timeout: 3).install()

        let groups = stopGroups(try readJSON())
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(Set(commandStrings(groups)), ["/usr/local/bin/notify-stop.sh", relayCommand(.codex)])
        let relayEntry = hookEntries(groups).first { ($0["command"] as? String) == relayCommand(.codex) }
        XCTAssertEqual(relayEntry?["timeout"] as? Int, 7, "an existing entry's other keys are never rewritten")
    }

    func testInstallIgnoresTheOtherProvidersRelayEntry() throws {
        try writeRaw(#"""
        { "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "\"/x/RelayHook\" --provider codex" } ] } ] } }
        """#)

        try makeFile(provider: .claudeCode).install()

        XCTAssertEqual(
            Set(commandStrings(stopGroups(try readJSON()))),
            ["\"/x/RelayHook\" --provider codex", relayCommand(.claudeCode)]
        )
    }

    // MARK: - Uninstall

    func testUninstallRemovesOnlyRelayCommandLeavingOthersIntact() throws {
        try writeRaw(#"""
        { "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "/usr/local/bin/notify-stop.sh" } ] } ] } }
        """#)
        let file = makeFile()
        try file.install()
        try file.uninstall()

        XCTAssertEqual(commandStrings(stopGroups(try readJSON())), ["/usr/local/bin/notify-stop.sh"])
    }

    func testUninstallKeepsGroupsThatHaveOtherKeys() throws {
        try writeRaw(#"""
        { "hooks": { "Stop": [ { "matcher": "", "hooks": [ { "type": "command", "command": "\"\#(helperPath)\" --provider claude-code" } ] } ] } }
        """#)

        try makeFile().uninstall()

        let groups = stopGroups(try readJSON())
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual((groups.first?["hooks"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(groups.first?["matcher"] as? String, "")
    }

    func testUninstallRemovesStopAndHooksKeysWhenOnlyRelayGroupExisted() throws {
        let file = makeFile()
        try file.install()
        try file.uninstall()

        XCTAssertNil(try readJSON()["hooks"])
    }

    func testUninstallPreservesUnrelatedHookEvents() throws {
        try writeRaw(#"""
        {
          "hooks": {
            "Stop": [ { "hooks": [ { "type": "command", "command": "\"\#(helperPath)\" --provider claude-code" } ] } ],
            "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "/usr/local/bin/audit.sh" } ] } ]
          }
        }
        """#)

        try makeFile().uninstall()

        let hooks = try readJSON()["hooks"] as? [String: Any]
        XCTAssertNil(hooks?["Stop"])
        XCTAssertNotNil(hooks?["PreToolUse"])
    }

    func testUninstallIsNoOpWhenNoFileExists() throws {
        XCTAssertNoThrow(try makeFile().uninstall())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testUninstallDoesNotRewriteFileWhenNoRelayHookIsPresent() throws {
        try writeRaw(#"""
        { "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "/usr/local/bin/notify-stop.sh" } ] } ] } }
        """#)
        let before = try Data(contentsOf: fileURL)

        try makeFile().uninstall()

        XCTAssertEqual(try Data(contentsOf: fileURL), before)
    }

    // MARK: - Presence

    func testContainsRelayEntryTracksInstallAndUninstall() throws {
        let file = makeFile()
        XCTAssertFalse(try file.containsRelayEntry())
        try file.install()
        XCTAssertTrue(try file.containsRelayEntry())
        try file.uninstall()
        XCTAssertFalse(try file.containsRelayEntry())
    }

    // MARK: - Safe writes

    private func posixPermissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as! NSNumber).intValue
    }

    private var backupURL: URL {
        URL(fileURLWithPath: fileURL.path + StopHookConfigFile.backupSuffix)
    }

    func testNoOpInstallLeavesBytesAndModificationDateUntouched() throws {
        let file = makeFile()
        try file.install()
        let pastDate = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: pastDate], ofItemAtPath: fileURL.path)
        let before = try Data(contentsOf: fileURL)

        try file.install()

        XCTAssertEqual(try Data(contentsOf: fileURL), before)
        let modified = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
        XCTAssertEqual(modified, pastDate)
    }

    func testInstallThroughSymlinkUpdatesTargetAndKeepsTheLink() throws {
        let realDirectory = tempDirectory.appendingPathComponent("dotfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        let realFile = realDirectory.appendingPathComponent("real-settings.json")
        try Data(#"{"keep":1}"#.utf8).write(to: realFile)
        try FileManager.default.createSymbolicLink(atPath: fileURL.path, withDestinationPath: realFile.path)

        try makeFile().install()

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fileURL.path), realFile.path)
        let real = try JSONSerialization.jsonObject(with: Data(contentsOf: realFile)) as! [String: Any]
        XCTAssertEqual(real["keep"] as? Int, 1)
        XCTAssertEqual(commandStrings(stopGroups(real)), [relayCommand()])
    }

    func testInstallPreservesRestrictivePermissions() throws {
        try writeRaw(#"{"keep":1}"#)
        XCTAssertEqual(chmod(fileURL.path, 0o600), 0)

        try makeFile().install()

        XCTAssertEqual(try posixPermissions(fileURL), 0o600)
    }

    func testNewFileIsCreatedWithDefaultPermissionsAndNoBackup() throws {
        try makeFile().install()

        XCTAssertEqual(try posixPermissions(fileURL), StopHookConfigFile.newFilePermissions)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
    }

    func testFirstModificationCreatesBackupOnceWithOriginalBytes() throws {
        let originalJSON = #"{"keep":1}"#
        try writeRaw(originalJSON)
        let file = makeFile()

        try file.install()
        XCTAssertEqual(try String(contentsOf: backupURL, encoding: .utf8), originalJSON)

        try file.uninstall()
        XCTAssertEqual(
            try String(contentsOf: backupURL, encoding: .utf8), originalJSON,
            "a later modification must never overwrite the one-time backup"
        )
    }

    func testWrittenJSONDoesNotEscapeSlashes() throws {
        try makeFile().install()

        let text = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("/Applications/Relay.app/Contents/Helpers/RelayHook"))
        XCTAssertFalse(text.contains(#"\/"#))
    }
}
