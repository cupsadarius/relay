# Relay Cleanup 3: Integrations and Sessions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the copy-paste between the Claude Code and Codex integrations, make hook-config writes safe, make Debug and Release fully isolated side-by-side apps (own socket, lock, helper and hook entry, shared model downloads, visually distinct Debug menu bar item), share socket/path code between the app and `RelayHook`, fix the socket server and process-runner hot spots, take one process snapshot per focus decision (and log why a decision went silent), and make session identity survive agents that spawn hooks through a wrapper shell.

**Architecture:** One `StopHookConfigFile` owns the read → merge → write cycle for both agents' JSON hook configs; the installers become thin wrappers. One `StopHookIntegration(provider:requiresTurnID:)` replaces both decoders. A new top-level `Shared/` source directory, compiled into both the `Relay` and `RelayHook` targets, holds `BuildFlavor`, `RelayPaths`, `UnixSocketAddress` and `ProcessAncestry`. One per-configuration Info.plist key (`RelayBuildFlavor` = `release`|`debug`) drives the app's per-build support directory (`Relay` / `Relay Debug`), hook-entry ownership, and the Debug UI badge. `RelayHook` derives its socket from its own executable location, so it needs no build flag. `ProcessRunning` becomes `async`. `AgentAutoReadCoordinator` takes one `ProcessSnapshot` per hook event and passes it through `FocusContext` to every resolver, and `FocusResolutionService` builds one context per decision.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI/Observation, XCTest, Darwin sockets/sysctl, XcodeGen

**Style reference:** `docs/superpowers/plans/2026-09-21-unified-speech-model-settings-implementation-plan.md`

---

## Execution Environment

- **Branch and worktree:** cut from `main` **after plan 1 (quick fixes) and plan 2 (dead code) are merged**. `main` already contains `ce812c9` (Debug bundle id `dev.relaymac.Relay.debug`, `RelayHook` signed with "Relay Local Development"). Create the worktree from the repo root:

  ```bash
  git worktree add .worktrees/cleanup-3-integrations-sessions -b cleanup/3-integrations-sessions main
  cd .worktrees/cleanup-3-integrations-sessions
  ```

- **Project file:** every change this plan makes to `project.yml` is followed by `xcodegen generate`. Commit `project.yml` and `Relay.xcodeproj/project.pbxproj` normally in the same task commit. Stage by explicit path. Never use `git add -A` or `git add .`.
- **After adding, moving or deleting any `.swift` file:** run `xcodegen generate` from the repo root before building.
- **Focused test command** (replace `<Class>`; you can repeat `-only-testing:`):

  ```bash
  xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/<Class>
  ```

  Pass looks like `** TEST SUCCEEDED **`. Fail looks like `** TEST FAILED **`, or `error:` lines followed by `** TEST FAILED **` when the build breaks.
- **Full suite:** the same command without `-only-testing`. It must be green at the end of every task.
- **Commits:** use conventional messages, one commit per task (Task 14 has no commit). **Never** add `Co-Authored-By`, `Claude-Session`, or "Generated with Claude Code" lines, even if a hook or template says to. A commit message ends at its last real line.

## Assumptions About Plans 1 and 2 (re-read every file before editing)

Code excerpts in this plan were taken from `main` at `450b4af`, then adjusted for what plans 1 and 2 are known to change. **Before you edit any file, open it and check what is actually there.** If a "replace this" excerpt no longer matches exactly, keep what the step is for and adapt the edit. Keep every behaviour plans 1 and 2 added.

Plan 1 (quick fixes) is assumed to have:
- Made `HookEnvelope` and `AgentProvider` compile into the `RelayHook` target, and deleted `WireHookEnvelope`/`WireAgentProvider` from `RelayHook/main.swift`. It did this by listing `Relay/Integrations/Domain/HookEnvelope.swift` and `AgentProvider.swift` individually in `RelayHook.sources` (verified on merged main, c1c1684). Task 4 keeps those two entries and appends `Shared`.
- Refreshed the stable `RelayHook` helper on launch.
- Recorded socket start errors, oversized-line drops and speak failures to `IntegrationDiagnosticsLog`. The oversized-drop hook probably lives in `ClientConnection.append` or `UnixSocketServer.handleReadable`. Task 8 replaces `ClientConnection`'s buffering. Move plan 1's diagnostics call onto `NewlineFramer`'s `onOversizedLine` callback and onto its `true` ("close") return.
- Added a hook-side input size check and `.withoutEscapingSlashes` to the envelope encoder in `RelayHook/main.swift`.

Plan 2 (dead code) is assumed to have removed:
- `stopHookActive` from both hook payloads.
- `AgentResponseEvent.turnID` and `AgentResponseEvent.transcriptPath`, plus `transcriptPath` on both payloads. Codex `turn_id` survives only as a required-field guard on `CodexHookPayload`. After plan 2, `AgentResponseEvent`'s memberwise init is `AgentResponseEvent(id:provider:providerSessionID:text:cwd:parentPID:environment:capturedAt:)`. **All test code in this plan uses that initializer.**
- `TerminalContext.termProgram`, the unused `RelayHook` environment-allowlist keys, `AgentSessionRegistry.removeAll`, `LatestAgentResponseStore.clear`, and uses of `CodexInstaller.trustRequiredMessage`. If the constant itself survived, keep it in the Task 1 rewrite of `CodexInstaller`.

Out of scope: splitting `AppModel` (plan 5), README/CI (plan 6). Edit `AppModel.swift` only where a task says to.

## Decisions Worth Reviewing

1. **`.sortedKeys` is kept (deviation from the request to drop it).** `JSONSerialization` writes a Swift `Dictionary` in hash order, and Swift seeds that hash randomly for each process. Without `.sortedKeys`, every modifying write would reshuffle the user's keys in a different random order. `JSONSerialization` cannot keep the original order anyway. Keeping `.sortedKeys` means one reorder on the first modifying write, then stable output. The new no-op skip (Task 2a) means an unchanged file is never rewritten at all. If you still want it dropped, remove `.sortedKeys` from `StopHookConfigFile.write`. That is one token.
2. **`ProcessTreeReading` is deleted, not changed to take a snapshot.** The snapshot already answers `ancestry(from:)`. `TmuxFocusResolver` reads `context.processSnapshot` directly. `HerdrHostOwnershipChecking` does take the snapshot, as requested.
3. **`focusedSession(among:)` is deleted.** It is replaced by `SessionFocusResolving.resolveFocus(among:processSnapshot:) -> FocusResolution`. That method shares one context and one snapshot, and returns every `FocusDecision` so the coordinator can log `resolverID` and `reason`. `AppModel.replayLast()` calls it with its own single snapshot, instead of a third copy of the loop.
4. **Transient wrapper shells are trimmed in `RelayHook`.** `ProcessAncestry.agentAncestry(from: getppid())` drops *leading* `sh`/`bash`/`zsh`/… entries, so `processAncestry.first` is the agent. A login shell above the agent is never trimmed, because trimming stops at the first non-shell entry.
5. **`HookEnvelope.processAncestry` is optional and `schemaVersion` stays `1`.** An old helper that omits the field still decodes, and the app falls back to its own `ps` capture.
6. **One flavor key, not a directory-name key.** `RelayBuildFlavor` (`release`|`debug`) is set per configuration in `project.yml` through a user-defined build setting, `RELAY_BUILD_FLAVOR`, expanded into a small `Relay/Info.plist`. Xcode merges that plist with the generated one (`GENERATE_INFOPLIST_FILE: YES` stays on). `INFOPLIST_KEY_*` only works for Apple-defined keys, so a custom key needs the plist. A missing or unknown value reads as `release`. The support directory name (`Relay` / `Relay Debug`), `ownsLegacyHookEntries`, and the Debug UI labels are all derived from the flavor.
7. **Per-build state vs shared state.** Per-build (under `Relay` or `Relay Debug`): `relay.sock`, `relay.lock` (always the socket's sibling, so it follows automatically), and `bin/RelayHook`. `IntegrationDiagnosticsLog` is in memory only, and `UserDefaults` is already separate per bundle id. Shared (always under `Relay`): `Models/…` (Whisper today). Downloads are multi-GB and do not need to happen twice.
8. **Hook-entry ownership across builds.** Every entry whose command ends in `--provider <p>` with a `RelayHook` basename falls into one of three classes:
   - **own**: the helper path equals this build's `bin/RelayHook` exactly.
   - **other build**: the helper sits under a different `…/Application Support/Relay*/bin/RelayHook`.
   - **legacy**: any other location, such as a helper inside a `.app` bundle or DerivedData, from before the stable helper existed.

   Install, uninstall and status act on **own** entries only. **Legacy** entries are adopted only by the **Release** build (`BuildFlavor.ownsLegacyHookEntries`): install migrates them in place when no own entry exists, and uninstall removes them. Debug never touches a Release or legacy entry, and Release never touches a Debug entry. Both builds' hooks can coexist in `~/.claude/settings.json` and `~/.codex/hooks.json`. Status reports "installed" only for an own entry. A stale legacy entry therefore shows as "not installed", and Release's Install repairs it.
9. **RelayHook socket derivation.** If the running helper lives at `…/Application Support/<Relay*>/bin/RelayHook`, it connects to `…/<Relay*>/relay.sock`. Otherwise (a legacy bundle path) it falls back to the Release socket, `~/Library/Application Support/Relay/relay.sock`.
10. **Settings window title in Debug.** `RelayWindowTagger` sets the Settings `NSWindow.title` to "Relay Debug Settings". SwiftUI may rewrite a Settings window's title when you switch tabs, so Task 5 has a manual check and a deterministic fallback (a caption inside `SettingsView`).

---

## File Structure

**Created**
- `Shared/BuildFlavor.swift`: `release`/`debug` parsed from the `RelayBuildFlavor` Info.plist key (default `release`), plus the support directory name and legacy-ownership flag. Compiled into both targets.
- `Shared/RelayPaths.swift`: the per-build support directory, socket path and stable helper URL; the shared `Relay/Models` directory; stable-helper-path recognition; the helper-executable → socket derivation. Compiled into both targets.
- `Relay/Info.plist`: only `RelayBuildFlavor = $(RELAY_BUILD_FLAVOR)`, merged with the generated plist.
- `Relay/App/BuildFlavorPresentation.swift`: menu bar title/image/badge, menu header, and Settings title per flavor (app-only).
- `Shared/UnixSocketAddress.swift`: `sockaddr_un` builder (sets `sun_len`), `withSockaddr`, `connect(_:to:withDeadline:)`, `setNonBlocking`, `waitWritable`. Compiled into both targets.
- `Shared/ProcessAncestry.swift`: `sysctl(KERN_PROC_PID)` parent-chain walk (max depth 16) and wrapper-shell trimming. Compiled into both targets.
- `Relay/Integrations/StopHookConfigFile.swift`: the merged installer engine and `IntegrationInstallerError`.
- `Relay/Integrations/StopHookIntegration.swift`: `StopHookPayload`, `StopHookIntegrationError`, `StopHookIntegration`.
- `Relay/Integrations/Domain/AgentSpeech.swift`: `AgentProvider.speechSource` and `AgentResponseEvent.sessionID`/`speechRequest(text:mode:)` (app-only, because `SpeechSource` is app-only).
- `Relay/Integrations/Transport/NewlineFramer.swift`: O(n) newline framing used by `UnixSocketServer`.
- Tests: `RelayTests/Integrations/StopHookConfigFileTests.swift`, `StopHookIntegrationTests.swift`, `AgentSpeechTests.swift`, `NewlineFramerTests.swift`, `RelayTests/Shared/BuildFlavorTests.swift`, `RelayPathsTests.swift`, `UnixSocketAddressTests.swift`, `ProcessAncestryTests.swift`, `RelayTests/App/BuildFlavorPresentationTests.swift`.

**Deleted**
- `Relay/Integrations/ClaudeCode/ClaudeCodeHookPayload.swift`, `ClaudeCodeIntegration.swift`
- `Relay/Integrations/Codex/CodexHookPayload.swift`, `CodexIntegration.swift`
- `RelayTests/Integrations/ClaudeCodeIntegrationTests.swift`, `CodexIntegrationTests.swift` (their cases move into `StopHookIntegrationTests`)

**Modified (main ones)**
- `Relay/Integrations/ClaudeCode/ClaudeCodeInstaller.swift`, `Relay/Integrations/Codex/CodexInstaller.swift`: thin wrappers.
- `Relay/Integrations/Transport/UnixSocketServer.swift`, `HookEnvelopeReceiver.swift`
- `RelayHook/HookTransportClient.swift`, `RelayHook/main.swift`
- `Relay/System/BoundedProcessRunner.swift`, `Relay/Sessions/ProcessInspector.swift`, `AgentAutoReadCoordinator.swift`, `AgentSessionRegistry.swift`, `FocusResolutionService.swift`, `Domain/FocusModels.swift`, `Domain/AgentSession.swift`, `Herdr/HerdrHostOwnership.swift`, `Herdr/HerdrSocketClient.swift`, `Tmux/TmuxClient.swift`, `Resolvers/*.swift`
- `Relay/Integrations/IntegrationManager.swift`, `HelperInstaller.swift`, `Domain/HookEnvelope.swift` (or wherever plan 1 moved it), `Domain/AgentResponseEvent.swift`
- `Relay/App/AppModel.swift` (installer error mapping, socket path, `replayLast`), `Relay/App/RelayRuntime.swift` (wiring)
- `project.yml` (add `Shared` to both targets; `INFOPLIST_FILE`, `RELAY_BUILD_FLAVOR` per config)
- `Relay/App/RelayApp.swift`, `MenuBarContentView.swift`, `RelayWindowTagger.swift` (Debug visuals)

---

### Task 1: Extract `StopHookConfigFile` (refactor, tests stay green)

**Files:**
- Create: `Relay/Integrations/StopHookConfigFile.swift`
- Create: `RelayTests/Integrations/StopHookConfigFileTests.swift`
- Modify: `Relay/Integrations/ClaudeCode/ClaudeCodeInstaller.swift` (full rewrite)
- Modify: `Relay/Integrations/Codex/CodexInstaller.swift` (full rewrite, TOML section unchanged)
- Modify: `Relay/App/AppModel.swift` (`configurationErrorStatus(for:error:)`)
- Modify: `RelayTests/Integrations/ClaudeCodeInstallerTests.swift`, `RelayTests/Integrations/CodexInstallerTests.swift`

**Interfaces:**
- Produces: `IntegrationInstallerError { configFileNotObject, configFileMalformed, hooksDisabledInConfig }`. This replaces both `ClaudeCodeInstallerError` and `CodexInstallerError`.
- Produces: `StopHookConfigFile(fileURL:provider:helperPath:entryTimeoutSeconds:)` with `install()`, `uninstall()`, `containsRelayEntry()`, `static isRelayOwnedCommand(_:provider:)`, `static relayCommand(helperPath:provider:)`. `helperPath` is stored, not passed to `install()`, because Task 6's per-build ownership also needs it in `uninstall()` and `containsRelayEntry()`.
- Keeps: `ClaudeCodeInstaller`/`CodexInstaller` public surface (`init(baseDirectory:helperPath:)`, `defaultBaseDirectory(environment:)`, `defaultHelperPath()`, `static isRelayOwnedCommand(_:)`, `install()`, `uninstall()`, `status()`, `CodexInstaller.hooksDisabledMessage`, `CodexInstaller.tomlExplicitlyDisablesHooks(_:)`). The unused `relayCommand` instance property is dropped.

- [ ] **Step 1: Write the failing shared-engine tests**

Create `RelayTests/Integrations/StopHookConfigFileTests.swift`:

```swift
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
}
```

- [ ] **Step 2: Run to verify RED**

Run: `xcodegen generate && xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/StopHookConfigFileTests`
Expected: build fails with `cannot find 'StopHookConfigFile' in scope` and `cannot find type 'IntegrationInstallerError'`.

- [ ] **Step 3: Implement `StopHookConfigFile`**

Create `Relay/Integrations/StopHookConfigFile.swift`. `write` keeps today's always-write behaviour. Task 2 replaces only its body.

```swift
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
```

- [ ] **Step 4: Run the new tests to verify GREEN**

Run: `xcodegen generate && xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/StopHookConfigFileTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Rewrite `ClaudeCodeInstaller` as a thin wrapper**

Replace the whole of `Relay/Integrations/ClaudeCode/ClaudeCodeInstaller.swift`:

```swift
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
```

- [ ] **Step 6: Rewrite `CodexInstaller` as a thin wrapper**

Replace everything in `Relay/Integrations/Codex/CodexInstaller.swift` **except** the `// MARK: - config.toml` section (`configExplicitlyDisablesHooks()`, `tomlExplicitlyDisablesHooks(_:)`, `stripTomlComment(_:)`). Keep that section verbatim. Remove the `// MARK: - hooks.json validation helpers` section and the file I/O helpers. The type becomes:

```swift
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
        helperPath: String = CodexInstaller.defaultHelperPath()
    ) {
        self.configFile = StopHookConfigFile(
            fileURL: baseDirectory.appendingPathComponent("hooks.json"),
            provider: .codex,
            helperPath: helperPath,
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

    static func isRelayOwnedCommand(_ command: String) -> Bool {
        StopHookConfigFile.isRelayOwnedCommand(command, provider: .codex)
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
    // <-- keep the existing configExplicitlyDisablesHooks / tomlExplicitlyDisablesHooks /
    //     stripTomlComment implementations here, unchanged -->
}
```

If `trustRequiredMessage` still exists after plan 2, keep its declaration and doc comment.

- [ ] **Step 7: Update `AppModel`'s installer error mapping**

In `Relay/App/AppModel.swift`, in `configurationErrorStatus(for:error:)`, replace:

```swift
        if provider == .codex, case CodexInstallerError.hooksDisabledInConfig = error {
```

with:

```swift
        if provider == .codex, case IntegrationInstallerError.hooksDisabledInConfig = error {
```

- [ ] **Step 8: Trim the installer test files to provider-specific cases**

In `RelayTests/Integrations/ClaudeCodeInstallerTests.swift`, delete these tests. They now live in `StopHookConfigFileTests`:
`testInstallAppendsToExistingUnrelatedStopHookWithoutDeletingIt`, `testInstallIsIdempotentAndDoesNotDuplicate`, `testInstallThrowsWhenHooksIsNotAnObjectAndLeavesFileUntouched`, `testInstallThrowsWhenHooksStopIsNotAnArrayAndLeavesFileUntouched`, `testInstallThrowsWhenHooksStopContainsNonObjectElementAndLeavesFileUntouched`, `testInstallMigratesStaleBundlePathEntryToStablePath`, `testInstallIsNoOpWhenRelayEntryAlreadyMatchesStablePath`, `testUninstallRemovesOnlyRelayCommandLeavingOthersIntact`, `testUninstallDropsEmptyRelayCreatedGroupButKeepsGroupsWithOtherKeys`, `testUninstallRemovesStopKeyEntirelyWhenOnlyRelayGroupExisted`, `testUninstallRemovesHooksKeyWhenNoHookEventsRemain`, `testUninstallPreservesUnrelatedHookEventsWhenRemovingHooksKeyWouldNotApply`, `testUninstallIsNoOpWhenNoSettingsFileExists`, `testUninstallIsNoOpWhenNoRelayHookIsPresent`, `testUninstallDoesNotRewriteFileWhenNoRelayHookIsPresent`.

Keep: the two identification tests, the two base-directory tests, `testInstallCreatesSettingsFileWhenNoneExists`, the three status tests, and `testInstallerCanBePointedAtAnyDirectoryViaInjectedBaseDirectory`. Add one wrapper smoke test under `// MARK: - Status`:

```swift
    func testStatusIsNotInstalledAfterUninstall() throws {
        let installer = makeInstaller()
        try installer.install()
        try installer.uninstall()
        XCTAssertEqual(try installer.status(), .notInstalled)
    }
```

In `RelayTests/Integrations/CodexInstallerTests.swift`, delete the same list with Codex names (`...NoHooksFileExists` for `...NoSettingsFileExists`), and also delete `testInstallThrowsWhenTopLevelIsNotAnObjectAndLeavesFileUntouched`. Keep: identification, base directory, `testInstallCreatesHooksFileWhenNoneExists` (it covers `timeout: 3`), status, the injected-directory seam, and every `config.toml` test. Add the same `testStatusIsNotInstalledAfterUninstall` (with `CodexInstaller`). Then retarget the remaining error casts. The kept `config.toml` tests (today at about lines 417, 432 and 496) use `XCTAssertEqual(error as? CodexInstallerError, .hooksDisabledInConfig)`:

```bash
sed -i '' 's/as? CodexInstallerError/as? IntegrationInstallerError/g' RelayTests/Integrations/CodexInstallerTests.swift
sed -i '' 's/as? ClaudeCodeInstallerError/as? IntegrationInstallerError/g' RelayTests/Integrations/ClaudeCodeInstallerTests.swift
grep -rn "ClaudeCodeInstallerError\|CodexInstallerError" Relay RelayTests
```

Expected: the `grep` prints nothing. Remove any private test helper that no test uses any more (the compiler only warns, but keep the files tidy).

- [ ] **Step 9: Run installer + app integration tests**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/StopHookConfigFileTests -only-testing:RelayTests/ClaudeCodeInstallerTests -only-testing:RelayTests/CodexInstallerTests -only-testing:RelayTests/AppModelIntegrationsTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 10: Run the full suite, then commit**

Run the full suite. Expected: `** TEST SUCCEEDED **`.

```bash
git add Relay/Integrations/StopHookConfigFile.swift Relay/Integrations/ClaudeCode/ClaudeCodeInstaller.swift Relay/Integrations/Codex/CodexInstaller.swift Relay/App/AppModel.swift RelayTests/Integrations/StopHookConfigFileTests.swift RelayTests/Integrations/ClaudeCodeInstallerTests.swift RelayTests/Integrations/CodexInstallerTests.swift Relay.xcodeproj/project.pbxproj
git commit -m "refactor(integrations): share one StopHookConfigFile between installers"
```

---

### Task 2: Safe config writes

**Files:**
- Modify: `Relay/Integrations/StopHookConfigFile.swift` (`write`, plus new static helpers)
- Test: `RelayTests/Integrations/StopHookConfigFileTests.swift`

**Behaviour:** (a) a merge that changes nothing never touches the file; (b) a symlinked config is written at its real target and the link survives; (c) the target's POSIX mode is preserved; (d) slashes are not escaped (`.sortedKeys` is kept, see Decision 1); (e) the first modification of a pre-existing file leaves `<target>.relay-backup` if none exists.

- [ ] **Step 1: Write the failing tests**

Append inside `StopHookConfigFileTests`, before the final `}`:

```swift
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
```

- [ ] **Step 2: Run to verify RED**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/StopHookConfigFileTests`
Expected: build fails with `type 'StopHookConfigFile' has no member 'backupSuffix'` / `'newFilePermissions'`. Once Step 3 adds only those two constants, the five behaviour tests fail: mtime changed, the symlink was replaced, the mode is 0644, there is no backup, and `\/` is present.

- [ ] **Step 3: Implement safe writes**

In `StopHookConfigFile`, add under `static let helperBasename`:

```swift
    static let backupSuffix = ".relay-backup"
    /// Mode for a config file Relay creates from scratch (what `Data.write` produced before under
    /// the default umask).
    static let newFilePermissions = 0o644
```

Replace the doc-comment paragraph `/// Never logs file contents; only structural facts.` on the type with:

```swift
/// Writes are conservative: a merge that changes nothing never touches the file; a symlinked
/// config is updated at its real target (the link survives); the target's POSIX permissions are
/// preserved; and the first modification of a pre-existing file leaves a one-time
/// `<target>.relay-backup` copy beside it.
///
/// Never logs file contents; only structural facts.
```

Replace the whole `write(_:replacing:)` method with:

```swift
    private func write(_ root: [String: Any], replacing original: [String: Any]?) throws {
        if let original, NSDictionary(dictionary: original).isEqual(to: root) { return }

        let fileManager = FileManager.default
        let target = Self.resolvedWriteTarget(for: fileURL)
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
    static func resolvedWriteTarget(for url: URL) -> URL {
        var current = url
        for _ in 0..<16 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path) else {
                return current
            }
            current = destination.hasPrefix("/")
                ? URL(fileURLWithPath: destination)
                : current.deletingLastPathComponent().appendingPathComponent(destination)
        }
        return current
    }

    /// Copies `target` to `<target>.relay-backup` unless that backup already exists.
    private static func backUpOnce(_ target: URL) throws {
        let backup = URL(fileURLWithPath: target.path + backupSuffix)
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        try FileManager.default.copyItem(at: target, to: backup)
    }

    /// Writes `data` to a sibling temp file created with `permissions`, then `rename(2)`s it over
    /// `target`: readers never observe a partial file, and the mode is right from the first byte.
    private static func atomicallyReplace(_ target: URL, with data: Data, permissions: Int) throws {
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).relay-\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: permissions]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temporary.path, target.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
```

- [ ] **Step 4: Run to verify GREEN**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/StopHookConfigFileTests -only-testing:RelayTests/ClaudeCodeInstallerTests -only-testing:RelayTests/CodexInstallerTests -only-testing:RelayTests/AppModelIntegrationsTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Full suite, then commit**

Run the full suite. Expected: `** TEST SUCCEEDED **`.

```bash
git add Relay/Integrations/StopHookConfigFile.swift RelayTests/Integrations/StopHookConfigFileTests.swift
git commit -m "fix(integrations): make hook config writes no-op-safe, symlink- and mode-preserving"
```


---

### Task 3: One `StopHookIntegration`, one speech mapping

**Files:**
- Create: `Relay/Integrations/StopHookIntegration.swift`
- Create: `Relay/Integrations/Domain/AgentSpeech.swift`
- Create: `RelayTests/Integrations/StopHookIntegrationTests.swift`, `RelayTests/Integrations/AgentSpeechTests.swift`
- Delete: `Relay/Integrations/ClaudeCode/ClaudeCodeHookPayload.swift`, `Relay/Integrations/ClaudeCode/ClaudeCodeIntegration.swift`, `Relay/Integrations/Codex/CodexHookPayload.swift`, `Relay/Integrations/Codex/CodexIntegration.swift`, `RelayTests/Integrations/ClaudeCodeIntegrationTests.swift`, `RelayTests/Integrations/CodexIntegrationTests.swift`
- Modify: `Relay/Sessions/Domain/AgentSession.swift`, `Relay/Integrations/IntegrationManager.swift` (`speakResponse`), `Relay/Sessions/AgentAutoReadCoordinator.swift` (`speak`, `label`), `Relay/Sessions/AgentSessionRegistry.swift` (`upsert`), `Relay/App/RelayRuntime.swift` (~:355), `Relay/App/AppModel.swift` (~:244)

**Interfaces:**
- Produces: `StopHookIntegration(provider:requiresTurnID:decoder:)`, with `StopHookIntegration.claudeCode` and `StopHookIntegration.codex` (`requiresTurnID: true`).
- Produces: `StopHookIntegrationError { malformedPayload, unsupportedHookEvent, missingFinalMessage }`.
- Produces: `AgentSessionID.qualifiedName` (`"<provider>:<sessionID>"`), `AgentProvider.speechSource`, `AgentResponseEvent.sessionID`, `AgentResponseEvent.speechRequest(text:mode:)`.

- [ ] **Step 1: Write the failing tests**

Create `RelayTests/Integrations/StopHookIntegrationTests.swift`:

```swift
import XCTest
@testable import Relay

final class StopHookIntegrationTests: XCTestCase {
    private func envelope(provider: AgentProvider, rawPayload: String) -> HookEnvelope {
        HookEnvelope(
            schemaVersion: 1,
            provider: provider,
            rawPayload: rawPayload,
            parentPID: 4242,
            environment: ["TMUX_PANE": "%3"],
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func payload(
        event: String = "Stop",
        message: String? = "I've completed the refactoring.",
        turnID: String? = nil,
        extra: [String: Any] = [:]
    ) -> String {
        var object: [String: Any] = ["session_id": "abc123", "cwd": "/Users/me/project", "hook_event_name": event]
        if let message { object["last_assistant_message"] = message }
        if let turnID { object["turn_id"] = turnID }
        object.merge(extra) { current, _ in current }
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    func testClaudeCodeDecodesStopEventWithoutTurnID() throws {
        let event = try StopHookIntegration.claudeCode.decode(envelope(provider: .claudeCode, rawPayload: payload()))

        XCTAssertEqual(event.provider, .claudeCode)
        XCTAssertEqual(event.providerSessionID, "abc123")
        XCTAssertEqual(event.cwd, "/Users/me/project")
        XCTAssertEqual(event.text, "I've completed the refactoring.")
        XCTAssertEqual(event.parentPID, 4242)
        XCTAssertEqual(event.environment, ["TMUX_PANE": "%3"])
        XCTAssertEqual(event.capturedAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testCodexDecodesStopEventWithTurnID() throws {
        let event = try StopHookIntegration.codex.decode(envelope(provider: .codex, rawPayload: payload(turnID: "turn_456")))

        XCTAssertEqual(event.provider, .codex)
        XCTAssertEqual(event.providerSessionID, "abc123")
    }

    func testCodexRejectsMissingTurnIDAsMalformed() {
        XCTAssertThrowsError(try StopHookIntegration.codex.decode(envelope(provider: .codex, rawPayload: payload()))) { error in
            XCTAssertEqual(error as? StopHookIntegrationError, .malformedPayload)
        }
    }

    func testUnknownFieldsFromEitherAgentAreIgnored() throws {
        let raw = payload(extra: ["transcript_path": "/tmp/t.jsonl", "stop_hook_active": false, "model": "x"])
        XCTAssertNoThrow(try StopHookIntegration.claudeCode.decode(envelope(provider: .claudeCode, rawPayload: raw)))
    }

    func testMissingOrBlankFinalMessageIsRejectedForBothProviders() {
        for (integration, turnID) in [(StopHookIntegration.claudeCode, nil), (StopHookIntegration.codex, "t")] as [(StopHookIntegration, String?)] {
            for raw in [payload(message: nil, turnID: turnID), payload(message: "   \n", turnID: turnID)] {
                XCTAssertThrowsError(try integration.decode(envelope(provider: integration.provider, rawPayload: raw))) { error in
                    XCTAssertEqual(error as? StopHookIntegrationError, .missingFinalMessage)
                }
            }
        }
    }

    func testNonStopHookEventIsRejected() {
        let raw = payload(event: "PreToolUse")
        XCTAssertThrowsError(try StopHookIntegration.claudeCode.decode(envelope(provider: .claudeCode, rawPayload: raw))) { error in
            XCTAssertEqual(error as? StopHookIntegrationError, .unsupportedHookEvent)
        }
    }

    func testMalformedRawPayloadIsRejected() {
        XCTAssertThrowsError(try StopHookIntegration.codex.decode(envelope(provider: .codex, rawPayload: "not json"))) { error in
            XCTAssertEqual(error as? StopHookIntegrationError, .malformedPayload)
        }
    }
}
```

Create `RelayTests/Integrations/AgentSpeechTests.swift`:

```swift
import XCTest
@testable import Relay

final class AgentSpeechTests: XCTestCase {
    private func event(_ provider: AgentProvider, session: String) -> AgentResponseEvent {
        AgentResponseEvent(
            id: UUID(), provider: provider, providerSessionID: session,
            text: "raw", cwd: "/tmp", parentPID: 1, environment: [:], capturedAt: Date()
        )
    }

    func testQualifiedNameIsProviderColonSession() {
        XCTAssertEqual(AgentSessionID(provider: .codex, providerSessionID: "t1").qualifiedName, "codex:t1")
    }

    func testClaudeCodeEventBuildsClaudeSpeechRequest() {
        let source = event(.claudeCode, session: "abc")
        XCTAssertEqual(source.sessionID, AgentSessionID(provider: .claudeCode, providerSessionID: "abc"))
        XCTAssertEqual(
            source.speechRequest(text: "prepared", mode: .automatic),
            SpeechRequest(text: "prepared", source: .claudeCode, mode: .automatic, sessionID: "claude-code:abc")
        )
    }

    func testCodexEventBuildsCodexSpeechRequest() {
        XCTAssertEqual(
            event(.codex, session: "thr").speechRequest(text: "p", mode: .userRequested),
            SpeechRequest(text: "p", source: .codex, mode: .userRequested, sessionID: "codex:thr")
        )
    }
}
```

- [ ] **Step 2: Run to verify RED**

Run: `xcodegen generate && xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/StopHookIntegrationTests -only-testing:RelayTests/AgentSpeechTests`
Expected: build fails with `cannot find 'StopHookIntegration' in scope`, and `value of type 'AgentSessionID' has no member 'qualifiedName'`.

- [ ] **Step 3: Implement `StopHookIntegration`**

Create `Relay/Integrations/StopHookIntegration.swift`:

```swift
import Foundation

/// The fields Relay reads from a Claude Code or Codex `Stop` hook payload. Both agents use the
/// same snake_case names; unknown fields are ignored. `turnID` is optional here and enforced per
/// provider by `StopHookIntegration.requiresTurnID`.
struct StopHookPayload: Decodable {
    let sessionID: String
    let cwd: String
    let hookEventName: String
    let turnID: String?
    let lastAssistantMessage: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd
        case hookEventName = "hook_event_name"
        case turnID = "turn_id"
        case lastAssistantMessage = "last_assistant_message"
    }
}

/// Why a hook envelope was rejected. Never carries payload content — only the structural reason.
enum StopHookIntegrationError: Error, Equatable, Sendable {
    /// Not UTF-8/JSON, not the expected shape, or missing a required `turn_id`.
    case malformedPayload
    /// `hook_event_name` was not `"Stop"`.
    case unsupportedHookEvent
    /// `last_assistant_message` was missing, empty, or blank.
    case missingFinalMessage
}

/// Normalizes a `Stop` hook envelope from either agent into Relay's provider-neutral
/// `AgentResponseEvent`. Only `Stop` events with a nonblank `last_assistant_message` are
/// accepted.
struct StopHookIntegration: RelayIntegration {
    static let claudeCode = StopHookIntegration(provider: .claudeCode)
    /// Codex always sends `turn_id` on `Stop`; a payload without it is not a real Codex `Stop`.
    static let codex = StopHookIntegration(provider: .codex, requiresTurnID: true)

    let provider: AgentProvider
    let requiresTurnID: Bool
    private let decoder: JSONDecoder

    init(provider: AgentProvider, requiresTurnID: Bool = false, decoder: JSONDecoder = JSONDecoder()) {
        self.provider = provider
        self.requiresTurnID = requiresTurnID
        self.decoder = decoder
    }

    func decode(_ envelope: HookEnvelope) throws -> AgentResponseEvent {
        guard let data = envelope.rawPayload.data(using: .utf8),
              let payload = try? decoder.decode(StopHookPayload.self, from: data) else {
            throw StopHookIntegrationError.malformedPayload
        }
        if requiresTurnID, payload.turnID == nil {
            throw StopHookIntegrationError.malformedPayload
        }
        guard payload.hookEventName == "Stop" else {
            throw StopHookIntegrationError.unsupportedHookEvent
        }
        guard let text = payload.lastAssistantMessage,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StopHookIntegrationError.missingFinalMessage
        }

        return AgentResponseEvent(
            id: UUID(),
            provider: provider,
            providerSessionID: payload.sessionID,
            text: text,
            cwd: payload.cwd,
            parentPID: envelope.parentPID,
            environment: envelope.environment,
            capturedAt: envelope.capturedAt
        )
    }
}
```

Delete the old adapters and their tests:

```bash
git rm Relay/Integrations/ClaudeCode/ClaudeCodeHookPayload.swift Relay/Integrations/ClaudeCode/ClaudeCodeIntegration.swift Relay/Integrations/Codex/CodexHookPayload.swift Relay/Integrations/Codex/CodexIntegration.swift RelayTests/Integrations/ClaudeCodeIntegrationTests.swift RelayTests/Integrations/CodexIntegrationTests.swift
```

In `Relay/App/RelayRuntime.swift` and `Relay/App/AppModel.swift`, replace both occurrences of:

```swift
            integrations: [ClaudeCodeIntegration(), CodexIntegration()],
```

with:

```swift
            integrations: [StopHookIntegration.claudeCode, StopHookIntegration.codex],
```

- [ ] **Step 4: Centralise the speech mapping**

Append to `Relay/Sessions/Domain/AgentSession.swift`:

```swift
extension AgentSessionID {
    /// `"<provider raw value>:<providerSessionID>"`, e.g. `"claude-code:abc"`. The one spelling
    /// used for speech-request session IDs and privacy-reviewed diagnostics labels.
    var qualifiedName: String { "\(provider.rawValue):\(providerSessionID)" }
}
```

Create `Relay/Integrations/Domain/AgentSpeech.swift` (app target only, because `SpeechSource` does not exist in `RelayHook`):

```swift
import Foundation

extension AgentProvider {
    /// The `SpeechSource` attributed to speech produced from this agent's responses.
    var speechSource: SpeechSource {
        switch self {
        case .claudeCode: .claudeCode
        case .codex: .codex
        }
    }
}

extension AgentResponseEvent {
    var sessionID: AgentSessionID {
        AgentSessionID(provider: provider, providerSessionID: providerSessionID)
    }

    /// The single place an agent response becomes a `SpeechRequest`: source from the provider,
    /// session ID from `AgentSessionID.qualifiedName`. `text` is the already-preprocessed text.
    func speechRequest(text: String, mode: SpeechMode) -> SpeechRequest {
        SpeechRequest(text: text, source: provider.speechSource, mode: mode, sessionID: sessionID.qualifiedName)
    }
}
```

In `Relay/Integrations/IntegrationManager.swift`, replace the body of `speakResponse(_:)` with:

```swift
    func speakResponse(_ event: AgentResponseEvent) async throws {
        let prepared = preprocessor.prepare(text: event.text, mode: .automatic)
        try await speechCoordinator.speak(event.speechRequest(text: prepared, mode: .userRequested))
    }
```

In `Relay/Sessions/AgentAutoReadCoordinator.swift`, replace `speak(session:event:reason:)` and `label(_:)` with the following. Only the request construction changes: keep plan 1's `do`/`catch` with its `speak-cancelled` and `speak-failed` diagnostics, which `testSpeechFailureRecordsSpeakFailedDiagnosticsEntry` depends on.

```swift
    private func speak(session: AgentSession, event: AgentResponseEvent, reason: String) async {
        diagnostics.append(stage: "coordinator", outcome: "spoke", detail: "provider=\(event.provider.rawValue) reason=\(reason)")
        let request = event.speechRequest(text: preprocess(event.text), mode: .automatic)
        do {
            try await speech.speak(request)
        } catch is CancellationError {
            // Superseded by newer speech or stopped by the user: expected, but still visible.
            diagnostics.append(stage: "coordinator", outcome: "speak-cancelled", detail: "provider=\(event.provider.rawValue)")
        } catch {
            // Structural only: never the error's own text, which could carry content.
            diagnostics.append(stage: "coordinator", outcome: "speak-failed", detail: "provider=\(event.provider.rawValue)")
        }
    }

    private static func label(_ id: AgentSessionID) -> String {
        id.qualifiedName
    }
```

In `Relay/Sessions/AgentSessionRegistry.swift`, in `upsert(response:processAncestry:tty:)`, replace:

```swift
        let id = AgentSessionID(provider: response.provider, providerSessionID: response.providerSessionID)
```

with:

```swift
        let id = response.sessionID
```

- [ ] **Step 5: Run to verify GREEN**

Run: `xcodegen generate && xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/StopHookIntegrationTests -only-testing:RelayTests/AgentSpeechTests -only-testing:RelayTests/IntegrationManagerTests -only-testing:RelayTests/AgentAutoReadCoordinatorTests -only-testing:RelayTests/AppModelIntegrationsTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Confirm nothing references the old types, run the full suite, commit**

```bash
grep -rn "ClaudeCodeIntegration\|CodexIntegration\|ClaudeCodeHookPayload\|CodexHookPayload" Relay RelayTests RelayHook
```

Expected: no output. Run the full suite. Expected: `** TEST SUCCEEDED **`.

```bash
git add Relay/Integrations/StopHookIntegration.swift Relay/Integrations/Domain/AgentSpeech.swift Relay/Sessions/Domain/AgentSession.swift Relay/Integrations/IntegrationManager.swift Relay/Sessions/AgentAutoReadCoordinator.swift Relay/Sessions/AgentSessionRegistry.swift Relay/App/RelayRuntime.swift Relay/App/AppModel.swift RelayTests/Integrations/StopHookIntegrationTests.swift RelayTests/Integrations/AgentSpeechTests.swift Relay.xcodeproj/project.pbxproj
git commit -m "refactor(integrations): merge Claude Code and Codex decoders into StopHookIntegration"
```

(The `git rm` in Step 3 already staged the deletions.)

---

### Task 4: `BuildFlavor` + per-build `RelayPaths` (shared with `RelayHook`)

**Files:**
- Create: `Shared/BuildFlavor.swift`, `Shared/RelayPaths.swift`, `Relay/Info.plist`
- Create: `RelayTests/Shared/BuildFlavorTests.swift`, `RelayTests/Shared/RelayPathsTests.swift`
- Modify: `project.yml` (`Shared` in both targets; `INFOPLIST_FILE`; `RELAY_BUILD_FLAVOR` per config; exclude `Info.plist` from sources)
- Modify: `Relay/Integrations/HelperInstaller.swift` (`defaultBaseDirectory()`, `stableHelperURL()`)
- Modify: `Relay/App/AppModel.swift` (`integrationSocketPath`, ~:820)
- Modify: `RelayHook/HookTransportClient.swift` (`defaultSocketPath`)
- Modify: `Relay/App/RelayRuntime.swift` (Whisper cache directory, ~:243-248)
- Modify: `RelayTests/Integrations/HelperInstallerTests.swift` (`testStableHelperURLPointsUnderApplicationSupportRelayBin`)

**Interfaces:**
- Produces: `BuildFlavor { release, debug }`, with `init(infoDictionary:)`, `.current`, `supportDirectoryName`, `displayName`, `ownsLegacyHookEntries`.
- Produces: `RelayPaths.supportDirectory(flavor:home:)`, `socketPath(flavor:home:)`, `stableHelperURL(flavor:home:)`, `sharedModelsDirectory(home:)`, `supportDirectory(ofStableHelperPath:)`, `isStableHelperPath(_:)`, `socketPath(forHelperExecutablePath:home:)`.
- Per-build after this task: the socket, `relay.lock` (`UnixSocketServer` puts it next to the socket, so no code change there), and `bin/RelayHook`. Shared: `Relay/Models`.

- [ ] **Step 1: Write the failing tests**

Create `RelayTests/Shared/BuildFlavorTests.swift`:

```swift
import XCTest
@testable import Relay

final class BuildFlavorTests: XCTestCase {
    func testMissingOrUnknownValueIsRelease() {
        XCTAssertEqual(BuildFlavor(infoDictionary: nil), .release)
        XCTAssertEqual(BuildFlavor(infoDictionary: [:]), .release)
        XCTAssertEqual(BuildFlavor(infoDictionary: ["RelayBuildFlavor": "beta"]), .release)
        XCTAssertEqual(BuildFlavor(infoDictionary: ["RelayBuildFlavor": 1]), .release)
        XCTAssertEqual(BuildFlavor(infoDictionary: ["RelayBuildFlavor": ""]), .release)
    }

    func testKnownValuesParseCaseAndWhitespaceInsensitively() {
        XCTAssertEqual(BuildFlavor(infoDictionary: ["RelayBuildFlavor": "release"]), .release)
        XCTAssertEqual(BuildFlavor(infoDictionary: ["RelayBuildFlavor": "debug"]), .debug)
        XCTAssertEqual(BuildFlavor(infoDictionary: ["RelayBuildFlavor": " Debug\n"]), .debug)
    }

    func testDerivedNamesAndLegacyOwnership() {
        XCTAssertEqual(BuildFlavor.release.supportDirectoryName, "Relay")
        XCTAssertEqual(BuildFlavor.debug.supportDirectoryName, "Relay Debug")
        XCTAssertEqual(BuildFlavor.debug.displayName, "Relay Debug")
        XCTAssertTrue(BuildFlavor.release.ownsLegacyHookEntries)
        XCTAssertFalse(BuildFlavor.debug.ownsLegacyHookEntries)
    }

    /// The unit tests are hosted in the Debug `Relay.app` (TEST_HOST), so this proves the
    /// `RELAY_BUILD_FLAVOR` build setting reaches the built Info.plist end to end.
    func testTestHostDebugBuildReportsDebugFlavor() {
        XCTAssertEqual(BuildFlavor.current, .debug)
    }
}
```

Create `RelayTests/Shared/RelayPathsTests.swift`:

```swift
import XCTest
@testable import Relay

final class RelayPathsTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
    private let support = "/Users/test/Library/Application Support"

    func testPerBuildSocketAndHelperLiveInSeparateDirectories() {
        XCTAssertEqual(RelayPaths.socketPath(flavor: .release, home: home), "\(support)/Relay/relay.sock")
        XCTAssertEqual(RelayPaths.socketPath(flavor: .debug, home: home), "\(support)/Relay Debug/relay.sock")
        XCTAssertEqual(RelayPaths.stableHelperURL(flavor: .release, home: home).path, "\(support)/Relay/bin/RelayHook")
        XCTAssertEqual(RelayPaths.stableHelperURL(flavor: .debug, home: home).path, "\(support)/Relay Debug/bin/RelayHook")
    }

    func testModelsDirectoryIsSharedByEveryBuild() {
        XCTAssertEqual(RelayPaths.sharedModelsDirectory(home: home).path, "\(support)/Relay/Models")
    }

    func testStableHelperPathRecognition() {
        XCTAssertTrue(RelayPaths.isStableHelperPath("\(support)/Relay/bin/RelayHook"))
        XCTAssertTrue(RelayPaths.isStableHelperPath("\(support)/Relay Debug/bin/RelayHook"))
        XCTAssertFalse(RelayPaths.isStableHelperPath("/Applications/Relay.app/Contents/Helpers/RelayHook"))
        XCTAssertFalse(RelayPaths.isStableHelperPath("\(support)/Other/bin/RelayHook"))
        XCTAssertFalse(RelayPaths.isStableHelperPath("\(support)/Relay/bin/other"))
    }

    func testHelperDerivesItsSocketFromItsOwnLocation() {
        XCTAssertEqual(
            RelayPaths.socketPath(forHelperExecutablePath: "\(support)/Relay Debug/bin/RelayHook", home: home),
            "\(support)/Relay Debug/relay.sock"
        )
        XCTAssertEqual(
            RelayPaths.socketPath(forHelperExecutablePath: "\(support)/Relay/bin/RelayHook", home: home),
            "\(support)/Relay/relay.sock"
        )
    }

    func testHelperOutsideAStableDirectoryFallsBackToReleaseSocket() {
        XCTAssertEqual(
            RelayPaths.socketPath(forHelperExecutablePath: "/Applications/Relay.app/Contents/Helpers/RelayHook", home: home),
            "\(support)/Relay/relay.sock"
        )
    }

    /// `@MainActor`: `AppModel` (and its static `integrationSocketPath`) is MainActor-isolated.
    @MainActor
    func testAppAndHelperDefaultsAgreeWithRelayPaths() {
        // Test host is the Debug app, so the app listens on the Debug socket...
        XCTAssertEqual(AppModel.integrationSocketPath, RelayPaths.socketPath(flavor: .debug))
        XCTAssertNotEqual(AppModel.integrationSocketPath, RelayPaths.socketPath(flavor: .release))
        // ...and HookTransportClient's default (computed from the running executable, which here
        // is not a stable helper) falls back to Release.
        XCTAssertEqual(HookTransportClient.defaultSocketPath, RelayPaths.socketPath(flavor: .release))
        XCTAssertEqual(HelperInstaller.stableHelperURL(), RelayPaths.stableHelperURL(flavor: .debug))
    }
}
```

- [ ] **Step 2: Run to verify RED**

Run: `xcodegen generate && xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/BuildFlavorTests -only-testing:RelayTests/RelayPathsTests`
Expected: build fails with `cannot find 'BuildFlavor' in scope` / `cannot find 'RelayPaths' in scope`.

- [ ] **Step 3: Add the shared files**

Create `Shared/BuildFlavor.swift`:

```swift
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
```

Create `Shared/RelayPaths.swift`:

```swift
import Foundation

/// Filesystem locations Relay owns under `~/Library/Application Support`.
///
/// Per build (Release `Relay/`, Debug `Relay Debug/`): the socket, the single-instance lock
/// (always the socket's sibling), and the stable `bin/RelayHook`. Shared by every build:
/// `Relay/Models/` — multi-GB downloads are never duplicated.
///
/// Compiled into BOTH the `Relay` app target and the `RelayHook` helper target. Foundation-only.
enum RelayPaths {
    static let socketFileName = "relay.sock"
    static let helperBasename = "RelayHook"
    /// Shared state (models) always lives under the Release directory name.
    static let sharedDirectoryName = BuildFlavor.release.supportDirectoryName

    /// `~/Library/Application Support`. `home` is injectable for tests only.
    static func applicationSupportRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
    }

    /// This build's own directory: `…/Relay` or `…/Relay Debug`.
    static func supportDirectory(
        flavor: BuildFlavor = .current,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        applicationSupportRoot(home: home).appendingPathComponent(flavor.supportDirectoryName, isDirectory: true)
    }

    /// The Unix-domain socket this build's app listens on.
    static func socketPath(
        flavor: BuildFlavor = .current,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        supportDirectory(flavor: flavor, home: home).appendingPathComponent(socketFileName, isDirectory: false).path
    }

    /// The stable, app-bundle-independent helper this build installs and points hooks at.
    static func stableHelperURL(
        flavor: BuildFlavor = .current,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        supportDirectory(flavor: flavor, home: home)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent(helperBasename, isDirectory: false)
    }

    /// `…/Relay/Models` for EVERY flavor.
    static func sharedModelsDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        applicationSupportRoot(home: home)
            .appendingPathComponent(sharedDirectoryName, isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// The Relay support directory a stable helper lives in, or `nil` when `path` is not
    /// `…/Application Support/<Relay*>/bin/RelayHook` (any flavor, including future ones).
    static func supportDirectory(ofStableHelperPath path: String) -> URL? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let components = url.pathComponents
        guard components.count >= 4 else { return nil }
        let tail = Array(components.suffix(4))
        guard tail[3] == helperBasename,
              tail[2] == "bin",
              tail[1].hasPrefix(sharedDirectoryName),
              tail[0] == "Application Support" else { return nil }
        return url.deletingLastPathComponent().deletingLastPathComponent()
    }

    static func isStableHelperPath(_ path: String) -> Bool {
        supportDirectory(ofStableHelperPath: path) != nil
    }

    /// The socket `RelayHook` should connect to, derived from where the helper binary itself
    /// lives: `<support>/bin/RelayHook` -> `<support>/relay.sock`. Any other location (a legacy
    /// hook pointing into an app bundle) falls back to the Release socket. No build flags.
    static func socketPath(
        forHelperExecutablePath executablePath: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        guard let supportDirectory = supportDirectory(ofStableHelperPath: executablePath) else {
            return socketPath(flavor: .release, home: home)
        }
        return supportDirectory.appendingPathComponent(socketFileName, isDirectory: false).path
    }
}
```

Create `Relay/Info.plist`. Xcode merges it with the generated plist:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>RelayBuildFlavor</key>
	<string>$(RELAY_BUILD_FLAVOR)</string>
</dict>
</plist>
```

- [ ] **Step 4: Wire `project.yml`**

In `project.yml`:

1. Replace `targets.Relay.sources` with the block below. Today the `Relay` path has no `excludes` (plan 2 removed the dead ones), so this adds a new `excludes` holding only `Info.plist`, plus a `Shared` source:

```yaml
    sources:
      - path: Relay
        excludes:
          - Info.plist
      - path: Shared
        group: Shared
      - path: RelayHook/HookTransportClient.swift
        group: RelayHook
      - path: RelayHook/BoundedStdinReader.swift
        group: RelayHook
```

2. Under `targets.Relay.settings.base`, add:

```yaml
        INFOPLIST_FILE: Relay/Info.plist
        RELAY_BUILD_FLAVOR: release
```

3. Under `targets.Relay.settings.configs.debug` (it already has `PRODUCT_BUNDLE_IDENTIFIER: dev.relaymac.Relay.debug` and `INFOPLIST_KEY_CFBundleDisplayName: "Relay Debug"`; leave those alone), add:

```yaml
          RELAY_BUILD_FLAVOR: debug
```

4. Replace `targets.RelayHook.sources` with the block below. It keeps plan 1's two shared domain files and appends `Shared`:

```yaml
    sources:
      - path: RelayHook
      - path: Relay/Integrations/Domain/HookEnvelope.swift
      - path: Relay/Integrations/Domain/AgentProvider.swift
      - path: Shared
        group: Shared
```

Keep `GENERATE_INFOPLIST_FILE: YES`. Then:

```bash
xcodegen generate
```

- [ ] **Step 5: Point every hard-coded path at `RelayPaths`**

In `Relay/Integrations/HelperInstaller.swift`, replace the bodies of `defaultBaseDirectory()` and `stableHelperURL()`, and update their doc comments:

```swift
    /// This build's own directory under `~/Library/Application Support` (`Relay` or
    /// `Relay Debug`, see `BuildFlavor`).
    static func defaultBaseDirectory() -> URL {
        RelayPaths.supportDirectory()
    }

    /// The stable, bundle-independent path this build's hook commands point at:
    /// `<support dir>/bin/RelayHook`.
    static func stableHelperURL() -> URL {
        RelayPaths.stableHelperURL()
    }
```

In `Relay/App/AppModel.swift`, replace `integrationSocketPath` with:

```swift
    /// This build's Unix-domain socket for agent-hook envelopes (`Relay/relay.sock` for Release,
    /// `Relay Debug/relay.sock` for Debug). `RelayHook` derives the same path from its own
    /// location — see `RelayPaths.socketPath(forHelperExecutablePath:)`.
    static var integrationSocketPath: String {
        RelayPaths.socketPath()
    }
```

In `RelayHook/HookTransportClient.swift`, replace `defaultSocketPath` with:

```swift
    /// The socket for the running helper, derived from this executable's own location
    /// (`<support>/bin/RelayHook` -> `<support>/relay.sock`), else the Release socket. Only
    /// meaningful inside `RelayHook`; in the app target it always yields the Release socket.
    static var defaultSocketPath: String {
        let executablePath = Bundle.main.executableURL?.path ?? CommandLine.arguments.first ?? ""
        return RelayPaths.socketPath(forHelperExecutablePath: executablePath)
    }
```

In `Relay/App/RelayRuntime.swift`, replace the `whisperCacheDirectory` construction with:

```swift
        // Models are shared by Debug and Release (see `RelayPaths.sharedModelsDirectory`).
        let whisperCacheDirectory = RelayPaths.sharedModelsDirectory()
            .appendingPathComponent("Whisper", isDirectory: true)
```

In `RelayTests/Integrations/HelperInstallerTests.swift`, replace `testStableHelperURLPointsUnderApplicationSupportRelayBin` with:

```swift
    func testStableHelperURLPointsUnderThisBuildsSupportDirectory() {
        let resolved = HelperInstaller.stableHelperURL()
        XCTAssertEqual(resolved, RelayPaths.supportDirectory().appendingPathComponent("bin/RelayHook"))
        XCTAssertTrue(resolved.path.contains("/Library/Application Support/Relay"))
    }
```

- [ ] **Step 6: Run to verify GREEN**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/BuildFlavorTests -only-testing:RelayTests/RelayPathsTests -only-testing:RelayTests/HelperInstallerTests -only-testing:RelayTests/HookTransportClientTests -only-testing:RelayTests/AppModelIntegrationsTests`
Expected: `** TEST SUCCEEDED **`. If `testTestHostDebugBuildReportsDebugFlavor` fails, the Info.plist merge did not happen. Check `INFOPLIST_FILE` and `RELAY_BUILD_FLAVOR` in the regenerated project (`xcodebuild -scheme Relay -configuration Debug -showBuildSettings | grep -E 'INFOPLIST_FILE|RELAY_BUILD_FLAVOR'`).

- [ ] **Step 7: Verify both configurations' built plists**

```bash
for config in Debug Release; do
  xcodebuild build -scheme Relay -configuration "$config" -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -quiet
  dir=$(xcodebuild -scheme Relay -configuration "$config" -showBuildSettings 2>/dev/null | awk -F' = ' '/^ *BUILT_PRODUCTS_DIR /{print $2; exit}')
  echo "$config: $(plutil -extract RelayBuildFlavor raw "$dir/Relay.app/Contents/Info.plist") $(plutil -extract CFBundleIdentifier raw "$dir/Relay.app/Contents/Info.plist")"
done
```

Expected:

```
Debug: debug dev.relaymac.Relay.debug
Release: release dev.relaymac.Relay
```

- [ ] **Step 8: Full suite, then commit**

Run the full suite. Expected: `** TEST SUCCEEDED **`.

```bash
git add Shared/BuildFlavor.swift Shared/RelayPaths.swift Relay/Info.plist project.yml Relay.xcodeproj/project.pbxproj Relay/Integrations/HelperInstaller.swift Relay/App/AppModel.swift RelayHook/HookTransportClient.swift Relay/App/RelayRuntime.swift RelayTests/Shared/BuildFlavorTests.swift RelayTests/Shared/RelayPathsTests.swift RelayTests/Integrations/HelperInstallerTests.swift
git commit -m "feat(paths): isolate Debug and Release support directories via BuildFlavor"
```

---

### Task 5: Make the Debug build visually distinct

**Files:**
- Create: `Relay/App/BuildFlavorPresentation.swift`
- Create: `RelayTests/App/BuildFlavorPresentationTests.swift`
- Modify: `Relay/App/RelayApp.swift`, `Relay/App/MenuBarContentView.swift`, `Relay/App/RelayWindowTagger.swift`

**Behaviour:** Release looks exactly as it does today: a `waveform` template image, accessibility title "Relay", no header, "Quit Relay". Debug shows `waveform` followed by a small bold "DEV" in the menu bar (both follow the menu bar appearance), the accessibility title "Relay Debug", a "Relay Debug" header at the top of the menu, "Quit Relay Debug", and a Settings window titled "Relay Debug Settings". The activity overlay is unchanged.

- [ ] **Step 1: Write the failing tests**

Create `RelayTests/App/BuildFlavorPresentationTests.swift`:

```swift
import SwiftUI
import XCTest
@testable import Relay

final class BuildFlavorPresentationTests: XCTestCase {
    func testReleaseMatchesTodaysMenuBarItem() {
        let presentation = BuildFlavorPresentation(flavor: .release)
        XCTAssertEqual(presentation.menuBarTitle, "Relay")
        XCTAssertEqual(presentation.menuBarSystemImage, "waveform")
        XCTAssertNil(presentation.menuBarBadge)
        XCTAssertNil(presentation.menuHeader)
        XCTAssertNil(presentation.settingsWindowTitle)
        XCTAssertEqual(presentation.quitTitle, "Quit Relay")
    }

    func testDebugIsBadgedAndTitled() {
        let presentation = BuildFlavorPresentation(flavor: .debug)
        XCTAssertEqual(presentation.menuBarTitle, "Relay Debug")
        XCTAssertEqual(presentation.menuBarSystemImage, "waveform")
        XCTAssertEqual(presentation.menuBarBadge, "DEV")
        XCTAssertEqual(presentation.menuHeader, "Relay Debug")
        XCTAssertEqual(presentation.settingsWindowTitle, "Relay Debug Settings")
        XCTAssertEqual(presentation.quitTitle, "Quit Relay Debug")
    }

    @MainActor
    func testMenuBarLabelConstructsForBothFlavors() {
        for flavor in BuildFlavor.allCases {
            _ = MenuBarLabel(presentation: BuildFlavorPresentation(flavor: flavor)).body
        }
    }
}
```

- [ ] **Step 2: Run to verify RED**

Run: `xcodegen generate && xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/BuildFlavorPresentationTests`
Expected: build fails with `cannot find 'BuildFlavorPresentation' in scope`.

- [ ] **Step 3: Implement the presentation and label**

Create `Relay/App/BuildFlavorPresentation.swift`:

```swift
import SwiftUI

/// User-visible chrome that differs between the Release and Debug builds, so the two
/// side-by-side apps are distinguishable at a glance. Release values match the app as it
/// shipped before flavors existed. The activity overlay deliberately does not use this.
struct BuildFlavorPresentation: Equatable, Sendable {
    let menuBarTitle: String
    let menuBarSystemImage: String
    /// Short text shown next to the menu bar image; `nil` shows the image alone.
    let menuBarBadge: String?
    /// First line of the menu bar menu; `nil` shows no header.
    let menuHeader: String?
    /// Title forced onto the Settings window; `nil` leaves SwiftUI's default.
    let settingsWindowTitle: String?
    let quitTitle: String

    init(flavor: BuildFlavor) {
        let name = flavor.displayName
        menuBarTitle = name
        menuBarSystemImage = "waveform"
        quitTitle = "Quit \(name)"
        switch flavor {
        case .release:
            menuBarBadge = nil
            menuHeader = nil
            settingsWindowTitle = nil
        case .debug:
            menuBarBadge = "DEV"
            menuHeader = name
            settingsWindowTitle = "\(name) Settings"
        }
    }

    static var current: BuildFlavorPresentation { BuildFlavorPresentation(flavor: .current) }
}

/// The menu bar item's label. The SF Symbol renders as a template image and the badge text
/// uses the menu bar's own text colour, so both follow light/dark menu bar appearance.
struct MenuBarLabel: View {
    let presentation: BuildFlavorPresentation

    var body: some View {
        if let badge = presentation.menuBarBadge {
            HStack(spacing: 2) {
                Image(systemName: presentation.menuBarSystemImage)
                Text(badge)
                    .font(.system(size: 9, weight: .bold))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.menuBarTitle)
        } else {
            Image(systemName: presentation.menuBarSystemImage)
                .accessibilityLabel(presentation.menuBarTitle)
        }
    }
}
```

- [ ] **Step 4: Use it in the app scenes and menu**

In `Relay/App/RelayApp.swift`, replace `body` with:

```swift
    private let presentation = BuildFlavorPresentation.current

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(model: appDelegate.model, presentation: presentation)
        } label: {
            MenuBarLabel(presentation: presentation)
        }
        Settings {
            SettingsView(model: appDelegate.model)
                .background(
                    RelayWindowTagger(target: .settings, title: presentation.settingsWindowTitle)
                        .frame(width: 0, height: 0)
                )
        }
        Window("Diagnostics", id: "diagnostics") {
            DiagnosticsView(model: appDelegate.model)
                .background(RelayWindowTagger(target: .diagnostics).frame(width: 0, height: 0))
        }
    }
```

In `Relay/App/MenuBarContentView.swift`, add a stored property after `@Bindable var model: AppModel`:

```swift
    var presentation: BuildFlavorPresentation = .current
```

Put the header first inside the `VStack`, before `Text(model.activityStatusText)`:

```swift
            if let header = presentation.menuHeader {
                Text(header)
                    .font(.headline)
                Divider()
            }
```

Replace `Button("Quit Relay") { NSApplication.shared.terminate(nil) }` with:

```swift
            Button(presentation.quitTitle) { NSApplication.shared.terminate(nil) }
```

In `Relay/App/RelayWindowTagger.swift`, replace the whole file with:

```swift
import AppKit
import SwiftUI

struct RelayWindowTagger: NSViewRepresentable {
    let target: RelayWindowTarget
    /// When non-nil, forced onto the hosting window's title (Debug Settings window).
    var title: String? = nil

    func makeNSView(context: Context) -> TaggedWindowView { TaggedWindowView(target: target, title: title) }
    func updateNSView(_ view: TaggedWindowView, context: Context) {
        view.target = target
        view.title = title
        view.tagWindow()
    }
}

final class TaggedWindowView: NSView {
    var target: RelayWindowTarget
    var title: String?

    init(target: RelayWindowTarget, title: String? = nil) {
        self.target = target
        self.title = title
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); tagWindow() }
    func tagWindow() {
        window?.identifier = target.identifier
        if let title { window?.title = title }
    }
}
```

- [ ] **Step 5: Run to verify GREEN**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/BuildFlavorPresentationTests -only-testing:RelayTests/SettingsViewsSmokeTests -only-testing:RelayTests/WindowFocusCoordinatorTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Manual check (Debug build)**

Build and run the Debug app (`xcodebuild build -scheme Relay -configuration Debug -destination 'platform=macOS'`, then open the built `Relay.app`). Check four things:
- The menu bar shows the waveform with a small "DEV", in both light and dark menu bars. `MenuBarExtra` flattens its label into a status-item image and title, and can drop the font modifier or the `HStack` layout. If "DEV" is missing, full-size, or on a separate line, apply **Label fallback** below.
- The menu's first line is "Relay Debug", and the last item is "Quit Relay Debug".
- Settings opens with the title "Relay Debug Settings", and keeps it after you switch between two tabs.
- A Release build (`-configuration Release`) shows the plain waveform only.

**Label fallback (only if the check above fails).** Try the steps in order and re-check after each one:

1. In `MenuBarLabel`, drop the font modifier and keep plain `Text(badge)` next to the `Image`. `MenuBarExtra` then shows it as the status item's title, in normal menu bar text size.
2. If that is still wrong, render the badge into one template `NSImage`. Add to `Relay/App/BuildFlavorPresentation.swift`:

```swift
import AppKit

/// Draws the waveform plus badge text into a single template image, for when `MenuBarExtra`
/// will not lay out a composite SwiftUI label. Template rendering means AppKit tints it for
/// light and dark menu bars, like any SF Symbol.
@MainActor
enum MenuBarBadgeImage {
    static func make(systemImage: String, badge: String) -> NSImage? {
        let content = HStack(spacing: 2) {
            Image(systemName: systemImage)
            Text(badge).font(.system(size: 9, weight: .bold))
        }
        .foregroundStyle(.black)
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true
        return image
    }
}
```

and change the badge branch of `MenuBarLabel.body` to:

```swift
        if let badge = presentation.menuBarBadge,
           let image = MenuBarBadgeImage.make(systemImage: presentation.menuBarSystemImage, badge: badge) {
            Image(nsImage: image)
                .accessibilityLabel(presentation.menuBarTitle)
        } else {
            Image(systemName: presentation.menuBarSystemImage)
                .accessibilityLabel(presentation.menuBarTitle)
        }
```

`testMenuBarLabelConstructsForBothFlavors` (already `@MainActor`) still covers it. Re-run the manual check in both menu bar appearances.

**Fallback if SwiftUI rewrites the Settings title when you switch tabs:** keep the tagger change, and also add this to `SettingsView` below the `TabView` (wrap both in a `VStack(spacing: 0)`). It shows the build name deterministically:

```swift
if let title = BuildFlavorPresentation.current.settingsWindowTitle {
    Text(title).font(.caption).foregroundStyle(.secondary).padding(.bottom, 6)
}
```

- [ ] **Step 7: Full suite, then commit**

Run the full suite. Expected: `** TEST SUCCEEDED **`.

```bash
git add Relay/App/BuildFlavorPresentation.swift Relay/App/RelayApp.swift Relay/App/MenuBarContentView.swift Relay/App/RelayWindowTagger.swift RelayTests/App/BuildFlavorPresentationTests.swift Relay.xcodeproj/project.pbxproj
git commit -m "feat(app): badge the Debug build's menu bar item and window titles"
```

Also stage `Relay/App/Settings/SettingsView.swift` if you applied the fallback.

---

### Task 6: Per-build hook-entry ownership

**Files:**
- Modify: `Relay/Integrations/StopHookConfigFile.swift`
- Modify: `Relay/Integrations/ClaudeCode/ClaudeCodeInstaller.swift`, `Relay/Integrations/Codex/CodexInstaller.swift`
- Test: `RelayTests/Integrations/StopHookConfigFileTests.swift`, `ClaudeCodeInstallerTests.swift`, `CodexInstallerTests.swift`

**Rules (Decision 8):** own = exact own helper path; other build = another `…/Application Support/Relay*/bin/RelayHook`; legacy = anything else. Install, uninstall and status touch own entries. Only Release (`migratesLegacyEntries`) adopts legacy entries. When it has no own entry, it migrates the first legacy entry in place and drops any further ones, so there are no duplicates. It removes them all on uninstall. Debug and Release entries coexist.

**Interfaces:**
- Changes: `StopHookConfigFile.init(fileURL:provider:helperPath:migratesLegacyEntries:entryTimeoutSeconds:)`.
- Renames: `isRelayOwnedCommand` becomes `isRelayHookCommand`, on both `StopHookConfigFile` and the installers. It is purely structural and true for every build's entries.
- Adds: `StopHookConfigFile.EntryOwnership { own, otherBuild, legacy }` and `ownership(ofCommand:) -> EntryOwnership?`.
- Installers gain `migratesLegacyEntries: Bool = BuildFlavor.current.ownsLegacyHookEntries`.

- [ ] **Step 1: Write the failing tests**

In `RelayTests/Integrations/StopHookConfigFileTests.swift`, change `makeFile` to pass the new argument (existing tests keep Release-like migration):

```swift
    private func makeFile(provider: AgentProvider = .claudeCode, timeout: Int? = nil) -> StopHookConfigFile {
        StopHookConfigFile(
            fileURL: fileURL,
            provider: provider,
            helperPath: helperPath,
            migratesLegacyEntries: true,
            entryTimeoutSeconds: timeout
        )
    }
```

Rename the structural check in the identification test:

```bash
sed -i '' 's/isRelayOwnedCommand/isRelayHookCommand/g' RelayTests/Integrations/StopHookConfigFileTests.swift RelayTests/Integrations/ClaudeCodeInstallerTests.swift RelayTests/Integrations/CodexInstallerTests.swift
```

Append inside the class:

```swift
    // MARK: - Per-build ownership

    private let releaseHelper = "/Users/test/Library/Application Support/Relay/bin/RelayHook"
    private let debugHelper = "/Users/test/Library/Application Support/Relay Debug/bin/RelayHook"
    private let legacyHelper = "/Applications/Old Relay.app/Contents/Helpers/RelayHook"

    private func buildFile(_ flavor: BuildFlavor) -> StopHookConfigFile {
        StopHookConfigFile(
            fileURL: fileURL,
            provider: .codex,
            helperPath: flavor == .release ? releaseHelper : debugHelper,
            migratesLegacyEntries: flavor.ownsLegacyHookEntries,
            entryTimeoutSeconds: 3
        )
    }

    private func codexCommand(_ helper: String) -> String {
        "\"\(helper)\" --provider codex"
    }

    private func writeLegacyEntry() throws {
        try writeRaw(#"""
        { "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "\"/Applications/Old Relay.app/Contents/Helpers/RelayHook\" --provider codex", "timeout": 7 } ] } ] } }
        """#)
    }

    func testOwnershipClassification() {
        let debug = buildFile(.debug)
        XCTAssertEqual(debug.ownership(ofCommand: codexCommand(debugHelper)), .own)
        XCTAssertEqual(debug.ownership(ofCommand: codexCommand(releaseHelper)), .otherBuild)
        XCTAssertEqual(debug.ownership(ofCommand: codexCommand(legacyHelper)), .legacy)
        XCTAssertNil(debug.ownership(ofCommand: "echo hi"))
        XCTAssertNil(debug.ownership(ofCommand: "\"\(debugHelper)\" --provider claude-code"))
    }

    func testDebugInstallLeavesReleaseEntryUntouchedAndBothCoexist() throws {
        try buildFile(.release).install()
        try buildFile(.debug).install()

        XCTAssertEqual(
            Set(commandStrings(stopGroups(try readJSON()))),
            [codexCommand(releaseHelper), codexCommand(debugHelper)]
        )
    }

    func testReleaseInstallLeavesDebugEntryUntouched() throws {
        try buildFile(.debug).install()
        try buildFile(.release).install()

        XCTAssertEqual(
            Set(commandStrings(stopGroups(try readJSON()))),
            [codexCommand(releaseHelper), codexCommand(debugHelper)]
        )
    }

    func testEachUninstallRemovesOnlyItsOwnEntry() throws {
        try buildFile(.release).install()
        try buildFile(.debug).install()

        try buildFile(.debug).uninstall()
        XCTAssertEqual(commandStrings(stopGroups(try readJSON())), [codexCommand(releaseHelper)])

        try buildFile(.debug).install()
        try buildFile(.release).uninstall()
        XCTAssertEqual(commandStrings(stopGroups(try readJSON())), [codexCommand(debugHelper)])
    }

    func testStatusSeesOnlyTheBuildsOwnEntry() throws {
        try buildFile(.release).install()
        XCTAssertTrue(try buildFile(.release).containsRelayEntry())
        XCTAssertFalse(try buildFile(.debug).containsRelayEntry())
    }

    func testReleaseMigratesLegacyEntryInPlace() throws {
        try writeLegacyEntry()

        try buildFile(.release).install()

        let entries = hookEntries(stopGroups(try readJSON()))
        XCTAssertEqual(entries.compactMap { $0["command"] as? String }, [codexCommand(releaseHelper)])
        XCTAssertEqual(entries.first?["timeout"] as? Int, 7)
    }

    func testReleaseMigratesTheFirstOfSeveralLegacyEntriesAndDropsTheRest() throws {
        try writeRaw(#"""
        { "hooks": { "Stop": [
          { "hooks": [ { "type": "command", "command": "\"/Applications/Old Relay.app/Contents/Helpers/RelayHook\" --provider codex", "timeout": 7 } ] },
          { "hooks": [ { "type": "command", "command": "\"/Users/test/Library/Developer/Xcode/DerivedData/Relay-abc/Build/Products/Debug/Relay.app/Contents/Helpers/RelayHook\" --provider codex" } ] },
          { "matcher": "keep", "hooks": [ { "type": "command", "command": "echo other" } ] }
        ] } }
        """#)

        try buildFile(.release).install()

        let groups = stopGroups(try readJSON())
        XCTAssertEqual(commandStrings(groups).filter { $0.contains("RelayHook") }, [codexCommand(releaseHelper)], "no duplicate Relay entries")
        XCTAssertEqual(hookEntries(groups).first?["timeout"] as? Int, 7, "the first legacy entry is the one migrated in place")
        XCTAssertEqual(groups.count, 2, "the emptied legacy-only group is dropped; the unrelated group stays")
        XCTAssertTrue(commandStrings(groups).contains("echo other"))
    }

    func testDebugNeverMigratesLegacyEntry() throws {
        try writeLegacyEntry()

        try buildFile(.debug).install()

        XCTAssertEqual(
            Set(commandStrings(stopGroups(try readJSON()))),
            [codexCommand(legacyHelper), codexCommand(debugHelper)]
        )
    }

    func testOnlyReleaseUninstallRemovesLegacyEntry() throws {
        try writeLegacyEntry()
        let before = try Data(contentsOf: fileURL)

        try buildFile(.debug).uninstall()
        XCTAssertEqual(try Data(contentsOf: fileURL), before)

        try buildFile(.release).uninstall()
        XCTAssertNil(try readJSON()["hooks"])
    }

    func testLegacyEntryIsNotReportedAsInstalled() throws {
        try writeLegacyEntry()
        XCTAssertFalse(try buildFile(.release).containsRelayEntry())
    }

    func testReleaseMigratesLegacyOnceAndNeverTouchesTheDebugEntry() throws {
        try writeLegacyEntry()
        try buildFile(.debug).install()          // legacy + debug
        try buildFile(.release).install()        // migrates legacy -> release
        try buildFile(.release).install()        // no-op

        XCTAssertEqual(
            Set(commandStrings(stopGroups(try readJSON()))),
            [codexCommand(releaseHelper), codexCommand(debugHelper)]
        )
    }

    func testReleaseLeavesLegacyEntryAloneWhenItAlreadyHasItsOwn() throws {
        try writeRaw(#"""
        { "hooks": { "Stop": [
          { "hooks": [ { "type": "command", "command": "\"/Users/test/Library/Application Support/Relay/bin/RelayHook\" --provider codex" } ] },
          { "hooks": [ { "type": "command", "command": "\"/Applications/Old Relay.app/Contents/Helpers/RelayHook\" --provider codex" } ] }
        ] } }
        """#)
        let before = try Data(contentsOf: fileURL)

        try buildFile(.release).install()

        XCTAssertEqual(try Data(contentsOf: fileURL), before, "no duplicate own entry, no write")
    }
```

Add one installer-level coexistence test to `RelayTests/Integrations/ClaudeCodeInstallerTests.swift`:

```swift
    func testDebugAndReleaseInstallersCoexistInOneSettingsFile() throws {
        let release = ClaudeCodeInstaller(
            baseDirectory: tempDirectory,
            helperPath: RelayPaths.stableHelperURL(flavor: .release).path,
            migratesLegacyEntries: true
        )
        let debug = ClaudeCodeInstaller(
            baseDirectory: tempDirectory,
            helperPath: RelayPaths.stableHelperURL(flavor: .debug).path,
            migratesLegacyEntries: false
        )

        try release.install()
        try debug.install()
        XCTAssertEqual(try release.status(), .installedAwaitingFirstEvent)
        XCTAssertEqual(try debug.status(), .installedAwaitingFirstEvent)

        try debug.uninstall()
        XCTAssertEqual(try release.status(), .installedAwaitingFirstEvent)
        XCTAssertEqual(try debug.status(), .notInstalled)
    }
```

- [ ] **Step 2: Run to verify RED**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/StopHookConfigFileTests -only-testing:RelayTests/ClaudeCodeInstallerTests -only-testing:RelayTests/CodexInstallerTests`
Expected: build fails with `extra argument 'migratesLegacyEntries' in call`, and `type 'StopHookConfigFile' has no member 'isRelayHookCommand'`.

- [ ] **Step 3: Implement ownership in `StopHookConfigFile`**

1. Add a stored property and init parameter:

```swift
    /// When true (Release only, `BuildFlavor.ownsLegacyHookEntries`), entries whose helper sits
    /// outside every `Application Support/Relay*/bin` (pre-stable-helper installs) are treated as
    /// this build's: migrated on install when no own entry exists, removed on uninstall.
    let migratesLegacyEntries: Bool

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
```

2. Replace `isRelayOwnedCommand(_:provider:)` with the structural check, a path extractor, and the classifier:

```swift
    /// Whose entry a Relay hook command is, relative to THIS build.
    enum EntryOwnership: Equatable, Sendable {
        /// Points at exactly this build's stable helper.
        case own
        /// Points at another build's stable helper (`…/Application Support/Relay*/bin/RelayHook`).
        case otherBuild
        /// Points at a `RelayHook` anywhere else (app bundle, DerivedData) — pre-stable installs.
        case legacy
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
```

3. Replace `isRelayEntry(_:)` and `migratingRelayCommand(in:to:)` with:

```swift
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
```

4. In `install()`, replace everything from `let command = …` through the `if !migrated.foundRelayEntry { … }` block with:

```swift
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
```

5. In `uninstall()`, replace `let filteredEntries = hookEntries.filter { !isRelayEntry($0) }` with:

```swift
            let filteredEntries = hookEntries.filter { !isRemovable($0) }
```

6. Replace the body of `containsRelayEntry()`'s final `return` with:

```swift
        return stopGroups.contains { group in
            Self.entries(in: group).contains { ownership(ofEntry: $0) == .own }
        }
```

Update the type's doc comment. Replace the paragraph starting "Only the Relay-owned command entry" with:

```swift
/// Ownership is per build (see `EntryOwnership`): this file only ever adds, rewrites, or removes
/// entries pointing at `helperPath` — plus, when `migratesLegacyEntries` (Release), legacy entries
/// from before the stable helper existed. Another build's entry, every non-Relay entry, and every
/// other key, hook event, and matcher group are left untouched, so Debug and Release hooks
/// coexist in one config file.
```

- [ ] **Step 4: Thread the flag through the installers**

In both installers, add a parameter to `init` and pass it on. `ClaudeCodeInstaller` shown; `CodexInstaller` is identical with its own file and timeout:

```swift
    init(
        baseDirectory: URL = ClaudeCodeInstaller.defaultBaseDirectory(),
        helperPath: String = ClaudeCodeInstaller.defaultHelperPath(),
        migratesLegacyEntries: Bool = BuildFlavor.current.ownsLegacyHookEntries
    ) {
        self.configFile = StopHookConfigFile(
            fileURL: baseDirectory.appendingPathComponent("settings.json"),
            provider: .claudeCode,
            helperPath: helperPath,
            migratesLegacyEntries: migratesLegacyEntries
        )
    }
```

For `CodexInstaller`:

```swift
        self.configFile = StopHookConfigFile(
            fileURL: baseDirectory.appendingPathComponent("hooks.json"),
            provider: .codex,
            helperPath: helperPath,
            migratesLegacyEntries: migratesLegacyEntries,
            entryTimeoutSeconds: Self.hookTimeoutSeconds
        )
```

Rename the static helper in both installers:

```swift
    /// Structural: true for any build's Relay hook command for this provider.
    static func isRelayHookCommand(_ command: String) -> Bool {
        StopHookConfigFile.isRelayHookCommand(command, provider: .claudeCode)   // `.codex` in CodexInstaller
    }
```

Then confirm the old name is gone:

```bash
grep -rn "isRelayOwnedCommand" Relay RelayTests
```

Expected: no output.

- [ ] **Step 5: Run to verify GREEN**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/StopHookConfigFileTests -only-testing:RelayTests/ClaudeCodeInstallerTests -only-testing:RelayTests/CodexInstallerTests -only-testing:RelayTests/AppModelIntegrationsTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Full suite, then commit**

Run the full suite. Expected: `** TEST SUCCEEDED **`.

```bash
git add Relay/Integrations/StopHookConfigFile.swift Relay/Integrations/ClaudeCode/ClaudeCodeInstaller.swift Relay/Integrations/Codex/CodexInstaller.swift RelayTests/Integrations/StopHookConfigFileTests.swift RelayTests/Integrations/ClaudeCodeInstallerTests.swift RelayTests/Integrations/CodexInstallerTests.swift
git commit -m "feat(integrations): scope hook entries to the installing build"
```


---

### Task 7: Shared `UnixSocketAddress` + Herdr timeout fix

**Files:**
- Create: `Shared/UnixSocketAddress.swift`
- Create: `RelayTests/Shared/UnixSocketAddressTests.swift`
- Modify: `Relay/Integrations/Transport/UnixSocketServer.swift` (`bind`, `probeLiveListener`, `setNonBlocking`, `probeDeadline`)
- Modify: `RelayHook/HookTransportClient.swift` (`send`, delete `setNonBlocking`/`waitWritable`)
- Modify: `Relay/Sessions/Herdr/HerdrSocketClient.swift` (`UnixLineRequest.sendBlocking`, new `receiveTimeout(milliseconds:)`)
- Test: `RelayTests/Sessions/HerdrSocketClientTests.swift`

**Interfaces:**
- Produces: `UnixSocketAddress.make(path:) throws -> sockaddr_un` (sets `sun_len`), `withSockaddr(_:_:)`, `connect(_:to:withDeadline:) -> Bool`, `setNonBlocking(_:_:)`, `waitWritable(fd:deadline:) -> Bool`, `UnixSocketAddressError.pathTooLong`.
- Produces: `UnixLineRequest.receiveTimeout(milliseconds:) -> timeval`.
- Fixes: `HerdrSocketClient`'s `tv_usec = ms * 1000`, which gives an out-of-range `tv_usec` for any value ≥ 1000 ms. Herdr's connect is now bounded too.

- [ ] **Step 1: Write the failing tests**

Create `RelayTests/Shared/UnixSocketAddressTests.swift`:

```swift
import Darwin
import XCTest
@testable import Relay

final class UnixSocketAddressTests: XCTestCase {
    func testMakeSetsLengthFamilyAndTerminatedPath() throws {
        let address = try UnixSocketAddress.make(path: "/tmp/relay-test.sock")

        XCTAssertEqual(Int(address.sun_len), MemoryLayout<sockaddr_un>.size)
        XCTAssertEqual(Int32(address.sun_family), AF_UNIX)
        let path = withUnsafeBytes(of: address.sun_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        XCTAssertEqual(path, "/tmp/relay-test.sock")
    }

    func testMakeRejectsAPathThatCannotFitItsTerminator() {
        let capacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        XCTAssertNoThrow(try UnixSocketAddress.make(path: "/" + String(repeating: "a", count: capacity - 2)))
        XCTAssertThrowsError(try UnixSocketAddress.make(path: "/" + String(repeating: "a", count: capacity - 1))) { error in
            XCTAssertEqual(error as? UnixSocketAddressError, .pathTooLong)
        }
    }

    func testConnectToAMissingSocketFailsFast() {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        let start = Date()

        XCTAssertFalse(UnixSocketAddress.connect(
            fd, to: "/tmp/relay-missing-\(UUID().uuidString).sock", withDeadline: Date().addingTimeInterval(0.4)
        ))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.3)
    }

    func testConnectReachesALiveListener() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let server = UnixSocketServer()
        try server.start(path: path) { _ in }
        defer { server.stop() }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }

        XCTAssertTrue(UnixSocketAddress.connect(fd, to: path, withDeadline: Date().addingTimeInterval(1)))
    }
}
```

Append to `HerdrSocketClientTests` (inside the class):

```swift
    func testReceiveTimeoutSplitsMillisecondsIntoSecondsAndMicroseconds() {
        let long = UnixLineRequest.receiveTimeout(milliseconds: 1_500)
        XCTAssertEqual(long.tv_sec, 1)
        XCTAssertEqual(long.tv_usec, 500_000)

        let short = UnixLineRequest.receiveTimeout(milliseconds: 400)
        XCTAssertEqual(short.tv_sec, 0)
        XCTAssertEqual(short.tv_usec, 400_000)
    }

    func testSendRejectsAnOverlongSocketPath() async {
        do {
            _ = try await UnixLineRequest.send(path: "/" + String(repeating: "a", count: 200), line: "x\n", timeoutMilliseconds: 400)
            XCTFail("expected pathTooLong")
        } catch HerdrQueryError.pathTooLong {
            // expected
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
```

- [ ] **Step 2: Run to verify RED**

Run: `xcodegen generate && xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/UnixSocketAddressTests -only-testing:RelayTests/HerdrSocketClientTests`
Expected: build fails with `cannot find 'UnixSocketAddress' in scope` and `type 'UnixLineRequest' has no member 'receiveTimeout'`.

- [ ] **Step 3: Create `Shared/UnixSocketAddress.swift`**

```swift
import Darwin
import Foundation

enum UnixSocketAddressError: Error, Equatable {
    case pathTooLong
}

/// `sockaddr_un` construction and bounded, non-blocking `connect` for local `AF_UNIX` stream
/// sockets — the single copy of code that used to be duplicated four times across
/// `UnixSocketServer`, `HookTransportClient`, and `UnixLineRequest`.
///
/// Compiled into BOTH the `Relay` app target and the `RelayHook` helper target. Darwin/Foundation
/// only.
enum UnixSocketAddress {
    /// Builds a fully initialised `sockaddr_un` for `path`: `sun_len`, `sun_family`, and a
    /// NUL-terminated `sun_path`. Throws `.pathTooLong` when `path` plus its terminator does not
    /// fit in `sun_path` (104 bytes on Darwin).
    static func make(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else { throw UnixSocketAddressError.pathTooLong }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { rawPath in
            rawPath.copyBytes(from: pathBytes)
        }
        return address
    }

    /// Calls `body` with `address` viewed as a generic `sockaddr` plus its length, for
    /// `bind`/`connect`.
    static func withSockaddr<Result>(
        _ address: sockaddr_un,
        _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Result
    ) rethrows -> Result {
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        return try withUnsafePointer(to: address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, length) }
        }
    }

    /// Connects `fd` to the socket at `path` without ever blocking past `deadline`. Leaves `fd`
    /// in NON-blocking mode; callers that want blocking I/O afterwards call
    /// `setNonBlocking(fd, false)`. Returns `true` only once the peer has accepted.
    static func connect(_ fd: Int32, to path: String, withDeadline deadline: Date) -> Bool {
        guard let address = try? make(path: path) else { return false }
        setNonBlocking(fd, true)
        let result = withSockaddr(address) { Darwin.connect(fd, $0, $1) }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        guard waitWritable(fd: fd, deadline: deadline) else { return false }

        // poll(POLLOUT) also fires for a failed connect; confirm success explicitly.
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else { return false }
        return socketError == 0
    }

    /// Sets or clears `O_NONBLOCK` on `fd`. Best-effort.
    static func setNonBlocking(_ fd: Int32, _ enabled: Bool) {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else { return }
        _ = fcntl(fd, F_SETFL, enabled ? (flags | O_NONBLOCK) : (flags & ~O_NONBLOCK))
    }

    /// Waits, via `poll()`, for `fd` to become writable, bounded by `deadline`. Returns `false`
    /// once the deadline has elapsed, or if `poll` reports error/hang-up.
    static func waitWritable(fd: Int32, deadline: Date) -> Bool {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }

            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let timeoutMilliseconds = Int32(min(remaining * 1000, Double(Int32.max - 1)))
            let result = poll(&descriptor, 1, max(timeoutMilliseconds, 0))

            if result < 0 {
                if errno == EINTR { continue }
                return false
            }
            if result == 0 { return false }

            let badEvents = Int16(POLLERR | POLLHUP | POLLNVAL)
            if (descriptor.revents & badEvents) != 0 { return false }
            return (descriptor.revents & Int16(POLLOUT)) != 0
        }
    }
}
```

- [ ] **Step 4: Adopt it in `UnixSocketServer`**

1. Change `probeDeadline` to a `TimeInterval`:

```swift
    private static let probeDeadline: TimeInterval = 0.2
```

2. Replace the whole `probeLiveListener(at:)` method (keep its doc comment) with:

```swift
    private static func probeLiveListener(at path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return UnixSocketAddress.connect(fd, to: path, withDeadline: Date().addingTimeInterval(probeDeadline))
    }
```

3. Replace the whole `bind(fd:toPath:)` method with:

```swift
    private static func bind(fd: Int32, toPath path: String) throws {
        let address: sockaddr_un
        do {
            address = try UnixSocketAddress.make(path: path)
        } catch {
            throw UnixSocketServerError.pathTooLong
        }
        let bindResult = UnixSocketAddress.withSockaddr(address) { Darwin.bind(fd, $0, $1) }
        guard bindResult == 0 else {
            throw UnixSocketServerError.bindFailed(errno)
        }
    }
```

4. Delete `private static func setNonBlocking(_:)`, and replace its two call sites (`Self.setNonBlocking(fd)` in `start`, and `Self.setNonBlocking(clientFD)` in `acceptPendingConnections`) with `UnixSocketAddress.setNonBlocking(fd, true)` / `UnixSocketAddress.setNonBlocking(clientFD, true)`.

- [ ] **Step 5: Adopt it in `HookTransportClient`**

Replace `send(_:)`, `setNonBlocking(_:)` and `waitWritable(fd:deadline:)` in `RelayHook/HookTransportClient.swift` with this single method. Keep the type's doc comment, `init`, and `defaultSocketPath`:

```swift
    @discardableResult
    func send(_ payload: Data) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        // Prevent SIGPIPE from killing the process if the peer closes the connection mid-write;
        // short/failed writes are handled via return values instead.
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        let deadline = Date().addingTimeInterval(totalDeadline)
        // A missing socket (Relay not running), an overlong path, or a peer that never accepts
        // all fail here within the deadline.
        guard UnixSocketAddress.connect(fd, to: socketPath, withDeadline: deadline) else { return false }

        var outgoing = payload
        if outgoing.last != UInt8(ascii: "\n") {
            outgoing.append(UInt8(ascii: "\n"))
        }

        return outgoing.withUnsafeBytes { rawBuf -> Bool in
            guard let base = rawBuf.baseAddress else { return true }
            var totalWritten = 0
            while totalWritten < rawBuf.count {
                guard UnixSocketAddress.waitWritable(fd: fd, deadline: deadline) else { return false }

                let written = write(fd, base + totalWritten, rawBuf.count - totalWritten)
                if written > 0 {
                    totalWritten += written
                    continue
                }
                if written < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                    continue // Spurious wake or interrupt; poll again with the remaining budget.
                }
                return false
            }
            return true
        }
    }
```

Update the file's header comment. It already says the file is compiled into both targets. Add: "Depends on `Shared/UnixSocketAddress.swift` and `Shared/RelayPaths.swift`, which are compiled into both targets too."

- [ ] **Step 6: Adopt it in `UnixLineRequest` and fix the timeout split**

In `Relay/Sessions/Herdr/HerdrSocketClient.swift`, replace the start of `sendBlocking`, from `let deadline = …` through `guard connected == 0 else { throw HerdrQueryError.socketFailure }`, with:

```swift
        let deadline = DispatchTime.now() + .nanoseconds(Int(totalDeadlineNanoseconds))
        guard (try? UnixSocketAddress.make(path: path)) != nil else {
            throw HerdrQueryError.pathTooLong
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HerdrQueryError.socketFailure }
        defer { Darwin.close(fd) }

        let connectDeadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1_000)
        guard UnixSocketAddress.connect(fd, to: path, withDeadline: connectDeadline) else {
            throw HerdrQueryError.socketFailure
        }
        // Back to blocking I/O; each read/write below is bounded by SO_RCVTIMEO/SO_SNDTIMEO and
        // the whole request by `deadline`.
        UnixSocketAddress.setNonBlocking(fd, false)

        var tv = receiveTimeout(milliseconds: timeoutMilliseconds)
        _ = withUnsafePointer(to: &tv) { ptr in
            Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }
        _ = withUnsafePointer(to: &tv) { ptr in
            Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }
```

Leave the write loop and the read loop that follow unchanged. Add this to `UnixLineRequest`:

```swift
    /// `SO_RCVTIMEO`/`SO_SNDTIMEO` value for `milliseconds`, split into whole seconds plus the
    /// microsecond remainder (`tv_usec` must stay below 1_000_000).
    static func receiveTimeout(milliseconds: Int32) -> timeval {
        timeval(tv_sec: Int(milliseconds / 1_000), tv_usec: Int32((milliseconds % 1_000) * 1_000))
    }
```

- [ ] **Step 7: Confirm the builders are gone, run the tests**

```bash
grep -rn "sockaddr_un()" Relay RelayHook Shared
```

Expected: only `Shared/UnixSocketAddress.swift`.

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/UnixSocketAddressTests -only-testing:RelayTests/HerdrSocketClientTests -only-testing:RelayTests/UnixSocketServerTests -only-testing:RelayTests/UnixSocketServerOwnershipTests -only-testing:RelayTests/HookTransportClientTests -only-testing:RelayTests/HookEnvelopeReceiverTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 8: Full suite, then commit**

Run the full suite. Expected: `** TEST SUCCEEDED **`.

```bash
git add Shared/UnixSocketAddress.swift Relay/Integrations/Transport/UnixSocketServer.swift RelayHook/HookTransportClient.swift Relay/Sessions/Herdr/HerdrSocketClient.swift RelayTests/Shared/UnixSocketAddressTests.swift RelayTests/Sessions/HerdrSocketClientTests.swift Relay.xcodeproj/project.pbxproj
git commit -m "refactor(transport): share one sockaddr_un builder and bounded connect"
```

---

### Task 8: `UnixSocketServer` fixes

**Files:**
- Create: `Relay/Integrations/Transport/NewlineFramer.swift`
- Create: `RelayTests/Integrations/NewlineFramerTests.swift`
- Modify: `Relay/Integrations/Transport/UnixSocketServer.swift`
- Test: `RelayTests/Integrations/UnixSocketServerTests.swift`

**Fixes:**
- Reuse one 256 KiB read buffer instead of allocating one per readable event.
- `NewlineFramer` scans each byte once and compacts once per read. It replaces `UnixSocketClientConnection.append`'s loop, which rescanned from the start and did `removeSubrange` at the front for every line (O(n²)).
- `EINTR` on `read` no longer closes the connection.
- `directoryCreationFailed` carries the real POSIX code from the thrown error, not a stale `errno`.
- Peers whose `getpeereid` uid is not `getuid()` are rejected at accept.

- [ ] **Step 1: Write the failing tests**

Create `RelayTests/Integrations/NewlineFramerTests.swift`:

```swift
import XCTest
@testable import Relay

final class NewlineFramerTests: XCTestCase {
    private struct Result {
        var lines: [String] = []
        var oversized = 0
        var closeRequests: [Bool] = []
    }

    private func feed(_ chunks: [[UInt8]], maxLineBytes: Int = 16) -> Result {
        var framer = NewlineFramer(maxLineBytes: maxLineBytes)
        var result = Result()
        for chunk in chunks {
            let shouldClose = framer.append(
                ArraySlice(chunk),
                onLine: { result.lines.append($0) },
                onOversizedLine: { _ in result.oversized += 1 },
                onOversizedUnterminated: { _ in }
            )
            result.closeRequests.append(shouldClose)
        }
        return result
    }

    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    func testLinesSplitAcrossReadsAreReassembledInOrder() {
        let result = feed([bytes("ab"), bytes("c\nde"), bytes("f\n\ng\n")])
        XCTAssertEqual(result.lines, ["abc", "def", "", "g"])
        XCTAssertEqual(result.closeRequests, [false, false, false])
    }

    func testOversizedTerminatedLineIsReportedAndSkipped() {
        let result = feed([bytes(String(repeating: "x", count: 17) + "\nok\n")])
        XCTAssertEqual(result.lines, ["ok"])
        XCTAssertEqual(result.oversized, 1)
    }

    func testUnterminatedOverflowRequestsCloseReportsItsSizeAndDiscardsTheBuffer() {
        var framer = NewlineFramer(maxLineBytes: 4)
        var unterminated: [Int] = []
        XCTAssertTrue(framer.append(
            ArraySlice(bytes("12345")),
            onLine: { _ in XCTFail() },
            onOversizedLine: { _ in XCTFail() },
            onOversizedUnterminated: { unterminated.append($0) }
        ))
        XCTAssertEqual(unterminated, [5])
        XCTAssertEqual(framer.bufferedByteCount, 0)
    }

    /// Ported from `UnixSocketServerTests.testOversizedTerminatedLineIsReportedAndFollowingLinesStillArrive`
    /// (which drove `UnixSocketClientConnection.append` directly) at the real limit.
    func testOversizedTerminatedLineReportsItsByteCountAndFollowingLinesStillArrive() {
        var framer = NewlineFramer(maxLineBytes: UnixSocketServer.maxLineBytes)
        var lines: [String] = []
        var oversizedByteCounts: [Int] = []
        var chunk = [UInt8](repeating: UInt8(ascii: "a"), count: UnixSocketServer.maxLineBytes + 1)
        chunk.append(UInt8(ascii: "\n"))
        chunk.append(contentsOf: Array(#"{"ok":1}"#.utf8))
        chunk.append(UInt8(ascii: "\n"))

        let shouldClose = framer.append(
            chunk[...],
            onLine: { lines.append($0) },
            onOversizedLine: { oversizedByteCounts.append($0) },
            onOversizedUnterminated: { _ in XCTFail("no unterminated oversized line in this test") }
        )

        XCTAssertFalse(shouldClose)
        XCTAssertEqual(oversizedByteCounts, [UnixSocketServer.maxLineBytes + 1])
        XCTAssertEqual(lines, [#"{"ok":1}"#])
    }

    func testLongLineArrivingInManySmallReadsIsDeliveredOnce() {
        let chunks = Array(repeating: bytes("abcd"), count: 512) + [bytes("\n")]
        let result = feed(chunks, maxLineBytes: 4_096)
        XCTAssertEqual(result.lines.count, 1)
        XCTAssertEqual(result.lines.first?.utf8.count, 2_048)
    }

    func testInvalidUTF8LineIsSkippedWithoutAffectingTheNextLine() {
        let result = feed([[0xFF, 0x0A] + bytes("ok\n")])
        XCTAssertEqual(result.lines, ["ok"])
    }
}
```

In `RelayTests/Integrations/UnixSocketServerTests.swift`, delete `testOversizedTerminatedLineIsReportedAndFollowingLinesStillArrive` (today at about line 266). It moves to `NewlineFramerTests` above. Keep `testOversizedUnterminatedLineIsRecordedInDiagnosticsAndClosesTheConnection` and `testOversizedLineIsDroppedAndConnectionIsClosedWithoutHangingTheServer` unchanged: they go through a real socket. Delete the `LineBox` helper if nothing else uses it. Then append inside the class:

```swift
    func testPeerIsCurrentUserAcceptsASameUserSocketPair() {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }

        XCTAssertTrue(UnixSocketServer.peerIsCurrentUser(fds[0]))
        XCTAssertFalse(UnixSocketServer.peerIsCurrentUser(-1))
    }

    func testRejectedPeerIsClosedAndRecordedWithoutDeliveringLines() async throws {
        let path = temporarySocketPath()
        let diagnostics = IntegrationDiagnosticsLog()
        let delivered = expectation(description: "no line delivered")
        delivered.isInverted = true
        let server = UnixSocketServer(diagnostics: diagnostics, peerCredentialCheck: { _ in false })
        try server.start(path: path) { _ in delivered.fulfill() }
        defer { server.stop() }

        let fd = try await UnixSocketTestClient.connectAndHold(to: path)
        defer { close(fd) }

        let closedByServer = try await UnixSocketTestClient.waitForEOF(fd: fd, timeout: 1)
        XCTAssertTrue(closedByServer)
        await fulfillment(of: [delivered], timeout: 0.2)
        XCTAssertTrue(diagnostics.snapshot().contains { $0.stage == "socket" && $0.outcome == "rejected-peer" })
    }

    func testDirectoryCreationFailureReportsTheRealPOSIXCode() throws {
        let locked = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o500])
        defer {
            chmod(locked.path, 0o700)
            try? FileManager.default.removeItem(at: locked)
        }

        XCTAssertThrowsError(try UnixSocketServer().start(path: locked.appendingPathComponent("sub/relay.sock").path) { _ in }) { error in
            XCTAssertEqual(error as? UnixSocketServerError, .directoryCreationFailed(EACCES))
        }
    }
```

- [ ] **Step 2: Run to verify RED**

Run: `xcodegen generate && xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/NewlineFramerTests -only-testing:RelayTests/UnixSocketServerTests`
Expected: build fails with `cannot find 'NewlineFramer' in scope`, `type 'UnixSocketServer' has no member 'peerIsCurrentUser'`, and `extra argument 'peerCredentialCheck'`. `testDirectoryCreationFailureReportsTheRealPOSIXCode` might pass by coincidence once the rest compiles, because the stale `errno` sometimes still holds `EACCES`. It is there to pin the fix.

- [ ] **Step 3: Create `NewlineFramer`**

Create `Relay/Integrations/Transport/NewlineFramer.swift`:

```swift
import Foundation

/// Splits a byte stream into newline-terminated UTF-8 lines in O(n): every byte is scanned once
/// (`scannedCount` remembers how far a partial line has been searched), and consumed lines are
/// compacted out of the buffer once per `append`, not once per line.
///
/// Value type, confined to `UnixSocketServer`'s serial queue through its owning connection.
struct NewlineFramer {
    let maxLineBytes: Int
    private var buffer: [UInt8] = []
    private var scannedCount = 0

    init(maxLineBytes: Int) {
        self.maxLineBytes = maxLineBytes
    }

    var bufferedByteCount: Int { buffer.count }

    /// Appends `bytes` and calls `onLine` once per complete line (without its newline).
    /// Newline-terminated lines longer than `maxLineBytes` are skipped and reported via
    /// `onOversizedLine` with their byte count, and the lines after them still arrive. Lines
    /// that are not valid UTF-8 are skipped silently. Returns `true` when the pending partial
    /// line already exceeds `maxLineBytes`: that is reported via `onOversizedUnterminated` with
    /// the buffered byte count, the buffer is discarded, and the caller must close the
    /// connection, bounding memory.
    mutating func append(
        _ bytes: ArraySlice<UInt8>,
        onLine: (String) -> Void,
        onOversizedLine: (Int) -> Void,
        onOversizedUnterminated: (Int) -> Void
    ) -> Bool {
        buffer.append(contentsOf: bytes)

        var lineStart = 0
        var searchStart = scannedCount
        while let newlineIndex = buffer[searchStart...].firstIndex(of: UInt8(ascii: "\n")) {
            if newlineIndex - lineStart > maxLineBytes {
                onOversizedLine(newlineIndex - lineStart)
            } else if let line = String(bytes: buffer[lineStart..<newlineIndex], encoding: .utf8) {
                onLine(line)
            }
            lineStart = newlineIndex + 1
            searchStart = lineStart
        }
        if lineStart > 0 {
            buffer.removeFirst(lineStart)
        }
        scannedCount = buffer.count

        if buffer.count > maxLineBytes {
            onOversizedUnterminated(buffer.count)
            buffer.removeAll(keepingCapacity: false)
            scannedCount = 0
            return true
        }
        return false
    }
}
```

- [ ] **Step 4: Apply the server fixes**

In `Relay/Integrations/Transport/UnixSocketServer.swift`:

1. Add stored properties next to `connections`:

```swift
    /// One receive buffer reused for every readable event (confined to `queue`), instead of a
    /// fresh 256 KiB allocation per event.
    private var readBuffer = [UInt8](repeating: 0, count: 256 * 1024)
    /// Decides whether an accepted peer may talk to us. Production: same uid as this process.
    private let peerCredentialCheck: @Sendable (Int32) -> Bool
```

2. Replace `init`:

```swift
    init(
        diagnostics: IntegrationDiagnosticsLog = IntegrationDiagnosticsLog(),
        peerCredentialCheck: @escaping @Sendable (Int32) -> Bool = { UnixSocketServer.peerIsCurrentUser($0) }
    ) {
        self.diagnostics = diagnostics
        self.peerCredentialCheck = peerCredentialCheck
    }

    /// True when the process on the other end of connected socket `fd` runs as this process's
    /// uid (`getpeereid`). Any failure reads as `false`.
    static func peerIsCurrentUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return false }
        return uid == getuid()
    }
```

3. In `acceptPendingConnections`, immediately after the `guard clientFD >= 0 else { … }` block, add:

```swift
            guard peerCredentialCheck(clientFD) else {
                // The socket is already 0600 in a 0700 directory; this is defence in depth
                // against a different-uid peer that still reached it.
                close(clientFD)
                diagnostics.append(stage: "socket", outcome: "rejected-peer", detail: "uid-mismatch")
                continue
            }
```

4. Replace `handleReadable(clientFD:)`:

```swift
    private func handleReadable(clientFD: Int32) {
        guard let connection = connections[clientFD] else { return }

        let bytesRead = readBuffer.withUnsafeMutableBytes { rawBuffer -> Int in
            read(clientFD, rawBuffer.baseAddress, rawBuffer.count)
        }

        if bytesRead > 0 {
            let onLine = self.onLine
            let diagnostics = self.diagnostics
            let shouldClose = connection.framer.append(
                readBuffer[0..<bytesRead],
                onLine: { onLine?($0) },
                onOversizedLine: { byteCount in
                    diagnostics.append(stage: "socket", outcome: "dropped", detail: "oversized-line (\(byteCount) bytes)")
                },
                onOversizedUnterminated: { byteCount in
                    diagnostics.append(stage: "socket", outcome: "dropped", detail: "oversized-unterminated (\(byteCount) bytes)")
                }
            )
            if shouldClose {
                closeConnection(clientFD)
            }
        } else if bytesRead == 0 {
            closeConnection(clientFD) // EOF
        } else {
            let capturedErrno = errno
            if capturedErrno == EAGAIN || capturedErrno == EWOULDBLOCK || capturedErrno == EINTR {
                return // Nothing to read right now, or interrupted: the read source fires again.
            }
            closeConnection(clientFD)
        }
    }
```

The two diagnostics strings are exactly the ones `handleReadable` records today, so the existing socket-level oversized tests keep passing.

5. Replace `ensureParentDirectoryExists(_:)`'s `catch` block and add the helper:

```swift
        } catch {
            throw UnixSocketServerError.directoryCreationFailed(posixCode(from: error))
        }
    }

    /// The POSIX errno behind a Foundation file error (`NSPOSIXErrorDomain` directly or as the
    /// underlying error of a Cocoa error), else `EIO`. Never reads the global `errno`, which
    /// Foundation may have overwritten by the time the error reaches us.
    static func posixCode(from error: Error) -> Int32 {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain { return Int32(nsError.code) }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return Int32(underlying.code)
        }
        return EIO
    }
```

(`ensureParentDirectoryExists` is `private static`, so this helper is `static` too. Keep the `}` structure balanced.)

6. Replace the `UnixSocketClientConnection` class at the bottom of the file. It stays `final class` and internal, with the same name, so `beginReading` and `connections` need no change. Only its buffer and `append` are replaced by a framer:

```swift
/// Per-connection state, confined to `UnixSocketServer`'s serial queue. Not `Sendable`: never
/// touch it off that queue. Framing lives in `NewlineFramer`, which is tested directly.
final class UnixSocketClientConnection {
    let fd: Int32
    var source: DispatchSourceRead?
    var framer = NewlineFramer(maxLineBytes: UnixSocketServer.maxLineBytes)

    init(fd: Int32) {
        self.fd = fd
    }
}
```

Check that nothing else calls the old `append`:

```bash
grep -rn "connection.append(\|UnixSocketClientConnection(fd: -1)" Relay RelayTests
```

Expected: no output.

- [ ] **Step 5: Run to verify GREEN**

Run: `xcodegen generate && xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/NewlineFramerTests -only-testing:RelayTests/UnixSocketServerTests -only-testing:RelayTests/UnixSocketServerOwnershipTests -only-testing:RelayTests/HookEnvelopeReceiverTests`
Expected: `** TEST SUCCEEDED **`. That includes the existing oversized-line, connection-cap and mid-write-disconnect tests.

- [ ] **Step 6: Full suite, then commit**

Run the full suite. Expected: `** TEST SUCCEEDED **`.

```bash
git add Relay/Integrations/Transport/NewlineFramer.swift Relay/Integrations/Transport/UnixSocketServer.swift RelayTests/Integrations/NewlineFramerTests.swift RelayTests/Integrations/UnixSocketServerTests.swift Relay.xcodeproj/project.pbxproj
git commit -m "fix(transport): O(n) line framing, reused read buffer, EINTR, peer uid check"
```

---

### Task 9: Bounded hook event stream

**Files:**
- Modify: `Relay/Integrations/Transport/HookEnvelopeReceiver.swift`
- Test: `RelayTests/Integrations/HookEnvelopeReceiverTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `HookEnvelopeReceiverTests`:

```swift
    func testEventStreamKeepsOnlyTheNewestEnvelopesWhenNobodyIsConsuming() async throws {
        let path = temporarySocketPath()
        let diagnostics = IntegrationDiagnosticsLog()
        let receiver = HookEnvelopeReceiver(diagnostics: diagnostics)
        try receiver.start(path: path)

        for pid in 1...20 {
            let line = #"{"schemaVersion":1,"provider":"codex","rawPayload":"{}","#
                + #""parentPID":\#(pid),"environment":{},"capturedAt":1700000000}"# + "\n"
            try await UnixSocketTestClient.send(line, to: path)
        }
        let deadline = Date().addingTimeInterval(2)
        while diagnostics.snapshot().filter({ $0.outcome == "envelope-decoded" }).count < 20, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        receiver.stop() // finishes the stream; buffered elements are still delivered
        var pids: [Int32] = []
        for await envelope in receiver.events {
            pids.append(envelope.parentPID)
        }

        XCTAssertEqual(HookEnvelopeReceiver.eventBufferLimit, 16)
        // 20 separate connections are not guaranteed to be decoded in send order, so compare
        // counts and membership, not order: 16 distinct envelopes kept, 4 dropped.
        XCTAssertEqual(pids.count, 16)
        XCTAssertEqual(Set(pids).count, 16)
        XCTAssertTrue(Set(pids).isSubset(of: Set(Int32(1)...Int32(20))))
        XCTAssertEqual(diagnostics.snapshot().filter { $0.detail.hasPrefix("event-buffer-full") }.count, 4)
    }
```

- [ ] **Step 2: Run to verify RED**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/HookEnvelopeReceiverTests/testEventStreamKeepsOnlyTheNewestEnvelopesWhenNobodyIsConsuming`
Expected: build fails with `type 'HookEnvelopeReceiver' has no member 'eventBufferLimit'`. With only the constant added, the test fails because `pids` has 20 elements.

- [ ] **Step 3: Bound the stream**

In `HookEnvelopeReceiver`, add:

```swift
    /// At most this many decoded envelopes wait for `IntegrationManager`; older ones are dropped
    /// (and recorded) first, so a burst while the consumer is slow can never grow memory without
    /// bound. Speech only ever cares about recent responses.
    static let eventBufferLimit = 16
```

Replace `events = AsyncStream { continuation in` with:

```swift
        events = AsyncStream(bufferingPolicy: .bufferingNewest(Self.eventBufferLimit)) { continuation in
```

In `handle(line:)`, replace `continuation.yield(envelope)` with:

```swift
        if case .dropped = continuation.yield(envelope) {
            diagnostics.append(
                stage: "receiver",
                outcome: "dropped",
                detail: "event-buffer-full provider=\(envelope.provider.rawValue)"
            )
        }
```

- [ ] **Step 4: Run to verify GREEN**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/HookEnvelopeReceiverTests -only-testing:RelayTests/IntegrationManagerTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Full suite, then commit**

Run the full suite. Expected: `** TEST SUCCEEDED **`.

```bash
git add Relay/Integrations/Transport/HookEnvelopeReceiver.swift RelayTests/Integrations/HookEnvelopeReceiverTests.swift
git commit -m "fix(integrations): bound the hook envelope stream to the newest 16"
```

---

### Task 10: Async process running, off-pool Herdr I/O

**Files:**
- Modify: `Relay/System/BoundedProcessRunner.swift` (full rewrite; `LockedBox` deleted, since it had no other user)
- Modify: `Relay/Sessions/ProcessInspector.swift` (`snapshot()` async; `ProcessTreeReading` extension)
- Modify: `Relay/Sessions/AgentAutoReadCoordinator.swift` (`AgentProcessContextCapture.capture`)
- Modify: `Relay/Sessions/AgentSessionRegistry.swift` (`pruneDeadSessions`)
- Modify: `Relay/Sessions/Herdr/HerdrHostOwnership.swift`, `Relay/Sessions/Tmux/TmuxClient.swift`, `Relay/Sessions/Herdr/HerdrSocketClient.swift` (`UnixLineRequest.send`)
- Test: `RelayTests/System/BoundedProcessRunnerTests.swift` (rewrite), `RelayTests/Sessions/ProcessInspectorTests.swift`

**Note:** a synchronous `throws` method still satisfies an `async throws` protocol requirement. The `ProcessRunning` fakes in `AgentAutoReadCoordinatorTests`, `AppModelTests`, `AppModelIntegrationsTests` and `TmuxClientBoundsTests` therefore need no changes.

- [ ] **Step 1: Write the failing tests**

Replace the whole of `RelayTests/System/BoundedProcessRunnerTests.swift`:

```swift
import XCTest
@testable import Relay

final class BoundedProcessRunnerTests: XCTestCase {
    private let runner = BoundedProcessRunner()

    private func expectError(_ expected: BoundedProcessError, _ body: () async throws -> ProcessResult) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected)")
        } catch {
            XCTAssertEqual(error as? BoundedProcessError, expected)
        }
    }

    func testSuccessReturnsStdoutAndZeroStatus() async throws {
        let result = try await runner.run(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["hello"], timeout: 5, maxOutputBytes: 1024)
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "hello\n")
    }

    func testNonZeroExitReportsStatusNotThrow() async throws {
        let result = try await runner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 3"], timeout: 5, maxOutputBytes: 1024)
        XCTAssertEqual(result.terminationStatus, 3)
    }

    func testOversizedOutputThrows() async {
        await expectError(.outputTooLarge) {
            try await runner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "yes ABCDEFGH | head -c 1000000"], timeout: 5, maxOutputBytes: 4096)
        }
    }

    func testBlockedProcessTimesOut() async {
        let start = Date()
        await expectError(.timedOut) {
            try await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 0.3, maxOutputBytes: 1024)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testStderrFloodDoesNotDeadlock() async throws {
        let result = try await runner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "yes ERR | head -c 200000 1>&2; echo done"], timeout: 5, maxOutputBytes: 4096)
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "done\n")
    }

    func testMissingExecutableThrowsLaunchFailedInsteadOfCrashing() async {
        await expectError(.launchFailed) {
            try await runner.run(
                executable: URL(fileURLWithPath: "/nonexistent/definitely-not-a-binary-\(UUID().uuidString)"),
                arguments: [], timeout: 5, maxOutputBytes: 1024
            )
        }
    }

    /// With the old semaphore-based runner, each run pinned a cooperative-pool thread, so
    /// 3x-pool-width concurrent `sleep 0.5`s took >= 3 rounds (~1.5 s). Suspending runs overlap.
    /// Capped at 24 so that even on a many-core machine this stays well below any OS or GCD
    /// thread limit (each run owns one drain `Thread` while its child sleeps).
    func testConcurrentRunsDoNotSerialiseOnTheCooperativePool() async throws {
        let runner = BoundedProcessRunner()
        let count = min(ProcessInfo.processInfo.activeProcessorCount * 3, 24)
        let start = Date()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<count {
                group.addTask {
                    _ = try await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["0.5"], timeout: 5, maxOutputBytes: 64)
                }
            }
            try await group.waitForAll()
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.4)
    }
}
```

In `RelayTests/Sessions/ProcessInspectorTests.swift`, replace the two `snapshot()` tests with:

```swift
    /// Exercises the real `/bin/ps` drain path end to end (the regression that deadlocked once
    /// ps output exceeded the 64 KB pipe buffer). The runner's own 5 s watchdog bounds it.
    func testSnapshotReturnsAndIncludesCurrentProcessAncestry() async throws {
        let snapshot = try await ProcessInspector().snapshot()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        XCTAssertNotNil(snapshot.record(pid: ownPID), "snapshot should include the current test process")
        XCTAssertFalse(snapshot.ancestry(from: ownPID).isEmpty)
    }

    func testSnapshotThrowsTimedOutWhenProcessHangs() async {
        let inspector = ProcessInspector(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            timeout: 0.2
        )
        do {
            _ = try await inspector.snapshot()
            XCTFail("expected timedOut")
        } catch {
            XCTAssertEqual(error as? ProcessInspectionError, .timedOut)
        }
    }
```

- [ ] **Step 2: Run to verify RED**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/BoundedProcessRunnerTests -only-testing:RelayTests/ProcessInspectorTests`
Expected: `testConcurrentRunsDoNotSerialiseOnTheCooperativePool` fails (elapsed ≈ 1.5 s or more, not less than 1.4). The other tests pass with "no 'async' operations occur within 'await'" warnings.

- [ ] **Step 3: Rewrite `BoundedProcessRunner.swift`**

Replace the whole file:

```swift
import Foundation

struct ProcessResult: Sendable {
    let stdout: Data
    let terminationStatus: Int32
}

enum BoundedProcessError: Error, Equatable {
    case launchFailed
    case timedOut
    case outputTooLarge
}

/// Runs a child process with three hard bounds: stderr is discarded (never an unread pipe that
/// can wedge the child), stdout is drained concurrently and capped at `maxOutputBytes`, and the
/// whole call is bounded by `timeout` (the child is terminated on expiry).
///
/// `async`: callers suspend instead of blocking a Swift Concurrency cooperative-pool thread while
/// the child runs. A synchronous `throws` implementation (as test fakes use) still satisfies it.
protocol ProcessRunning: Sendable {
    func run(executable: URL, arguments: [String], timeout: TimeInterval, maxOutputBytes: Int) async throws -> ProcessResult
}

struct BoundedProcessRunner: ProcessRunning {
    func run(executable: URL, arguments: [String], timeout: TimeInterval, maxOutputBytes: Int) async throws -> ProcessResult {
        let process = Process()
        let stdoutPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        let completion = ProcessCompletion()
        let child = ChildProcess(process)
        process.terminationHandler = { finished in
            completion.processExited(status: finished.terminationStatus)
        }

        return try await withCheckedThrowingContinuation { continuation in
            completion.install(continuation)

            do {
                try process.run()
            } catch {
                completion.fail(BoundedProcessError.launchFailed)
                return
            }

            // Drain stdout on a dedicated thread: `availableData` blocks until data or EOF. A
            // `Thread` rather than `DispatchQueue.global()`, so many concurrent runs never
            // exhaust GCD's worker-thread limit (about 64) and stall each other's drains.
            let handle = stdoutPipe.fileHandleForReading
            let drain = Thread {
                var accumulated = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    accumulated.append(chunk)
                    if accumulated.count > maxOutputBytes {
                        if completion.fail(BoundedProcessError.outputTooLarge) { child.terminate() }
                        return
                    }
                }
                completion.stdoutFinished(accumulated)
            }
            drain.name = "BoundedProcessRunner.drain"
            drain.start()

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if completion.fail(BoundedProcessError.timedOut) { child.terminate() }
            }
        }
    }
}

/// Lets the `@Sendable` drain/timeout closures terminate the child without capturing `Process`
/// itself across isolation domains.
private final class ChildProcess: @unchecked Sendable {
    private let process: Process
    init(_ process: Process) { self.process = process }
    func terminate() { process.terminate() }
}

/// Resumes the run's continuation exactly once: with the result once BOTH stdout has hit EOF and
/// the child has exited, or with the first failure (launch, overflow, timeout). Later signals are
/// ignored.
private final class ProcessCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ProcessResult, Error>?
    private var stdout: Data?
    private var status: Int32?

    func install(_ continuation: CheckedContinuation<ProcessResult, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    /// Returns `true` if this call resumed the continuation (the run had not finished yet).
    @discardableResult
    func fail(_ error: Error) -> Bool {
        let pending = lock.withLock { () -> CheckedContinuation<ProcessResult, Error>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(throwing: error)
        return pending != nil
    }

    func stdoutFinished(_ data: Data) {
        lock.withLock { stdout = data }
        resumeIfComplete()
    }

    func processExited(status: Int32) {
        lock.withLock { self.status = status }
        resumeIfComplete()
    }

    private func resumeIfComplete() {
        let ready = lock.withLock { () -> (CheckedContinuation<ProcessResult, Error>, ProcessResult)? in
            guard let continuation, let stdout, let status else { return nil }
            self.continuation = nil
            return (continuation, ProcessResult(stdout: stdout, terminationStatus: status))
        }
        if let (continuation, result) = ready {
            continuation.resume(returning: result)
        }
    }
}
```

- [ ] **Step 4: Propagate `async` to the callers**

`Relay/Sessions/ProcessInspector.swift`:

```swift
    func snapshot() async throws -> ProcessSnapshot {
        let result: ProcessResult
        do {
            result = try await runner.run(executable: executableURL, arguments: arguments, timeout: timeout, maxOutputBytes: 4 * 1024 * 1024)
        } catch BoundedProcessError.timedOut {
            throw ProcessInspectionError.timedOut
        } catch {
            throw ProcessInspectionError.psFailed
        }
        guard result.terminationStatus == 0 else { throw ProcessInspectionError.psFailed }
        return try ProcessSnapshot.parse(String(decoding: result.stdout, as: UTF8.self))
    }
```

and in the `ProcessTreeReading` extension: `try await snapshot().ancestry(from: pid).map(\.pid)`.

`Relay/Sessions/AgentAutoReadCoordinator.swift`, in `AgentProcessContextCapture.capture`: `guard let snapshot = try? await processInspector.snapshot() else {`.

`Relay/Sessions/AgentSessionRegistry.swift`, in `pruneDeadSessions`: `guard let snapshot = try? await processInspector.snapshot() else { return }`.

`Relay/Sessions/Herdr/HerdrHostOwnership.swift`:

```swift
    func frontmostAppOwnsClient(frontmostPID: Int32, socketPath: String) async -> Bool {
        guard let snapshot = try? await processInspector.snapshot() else { return false }
        let candidates = snapshot.descendants(of: frontmostPID).filter {
            URL(fileURLWithPath: $0.command).lastPathComponent.lowercased() == "herdr"
        }
        for candidate in candidates {
            if await lsof(pid: candidate.pid, contains: socketPath) { return true }
        }
        return false
    }

    private func lsof(pid: Int32, contains socketPath: String) async -> Bool {
        guard FileManager.default.isExecutableFile(atPath: lsofExecutableURL.path) else { return false }
        // Bounded via the shared runner (stderr discarded, stdout drained, `lsofTimeout`).
        // Ownership is unproven on any failure, so the fallback is always `false`.
        guard let result = try? await runner.run(executable: lsofExecutableURL, arguments: lsofArguments(pid), timeout: lsofTimeout, maxOutputBytes: 1024 * 1024) else {
            return false
        }
        guard result.terminationStatus == 0 else { return false }
        let text = String(decoding: result.stdout, as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).contains { line in
            line.first == "n" && String(line.dropFirst()) == socketPath
        }
    }
```

`Relay/Sessions/Tmux/TmuxClient.swift`: make `run` `async` and await it in both callers:

```swift
    func listClients(socketPath: String) async throws -> [TmuxClientListing] {
        let output = try await run(["-S", socketPath, "list-clients", "-F", "#{client_name}\\t#{client_pid}"])
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, let pid = Int32(parts[1]) else { return nil }
            return .init(name: parts[0], pid: pid)
        }
    }

    func activePane(socketPath: String, clientName: String) async throws -> String {
        try await run(["-S", socketPath, "display-message", "-p", "-c", clientName, "#{pane_id}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func run(_ arguments: [String]) async throws -> String {
        let result = try await runner.run(executable: URL(fileURLWithPath: executable), arguments: arguments, timeout: timeout, maxOutputBytes: 256 * 1024)
        guard result.terminationStatus == 0 else { throw TmuxError.commandFailed }
        return String(decoding: result.stdout, as: UTF8.self)
    }
```

`Relay/Sessions/Herdr/HerdrSocketClient.swift`: in `UnixLineRequest`, replace `send(path:line:timeoutMilliseconds:)` and add the queue:

```swift
    /// Dedicated queue for the blocking socket I/O in `sendBlocking`, so a slow herdr peer ties
    /// up one of this queue's threads instead of a Swift Concurrency cooperative-pool thread
    /// (which `Task.detached` would have used).
    private static let ioQueue = DispatchQueue(
        label: "dev.relaymac.Relay.UnixLineRequest",
        qos: .userInitiated,
        attributes: .concurrent
    )

    static func send(path: String, line: String, timeoutMilliseconds: Int32) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async {
                continuation.resume(with: Result {
                    try sendBlocking(path: path, line: line, timeoutMilliseconds: timeoutMilliseconds)
                })
            }
        }
    }
```

- [ ] **Step 5: Run to verify GREEN**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/BoundedProcessRunnerTests -only-testing:RelayTests/ProcessInspectorTests -only-testing:RelayTests/HerdrHostOwnershipCheckerTests -only-testing:RelayTests/TmuxClientBoundsTests -only-testing:RelayTests/HerdrSocketClientTests -only-testing:RelayTests/AgentAutoReadCoordinatorTests -only-testing:RelayTests/AppModelTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Full suite, then commit**

```bash
grep -rn "LockedBox\|waitUntilExit\|DispatchSemaphore" Relay
```

Expected: no output. Run the full suite. Expected: `** TEST SUCCEEDED **`.

```bash
git add Relay/System/BoundedProcessRunner.swift Relay/Sessions/ProcessInspector.swift Relay/Sessions/AgentAutoReadCoordinator.swift Relay/Sessions/AgentSessionRegistry.swift Relay/Sessions/Herdr/HerdrHostOwnership.swift Relay/Sessions/Tmux/TmuxClient.swift Relay/Sessions/Herdr/HerdrSocketClient.swift RelayTests/System/BoundedProcessRunnerTests.swift RelayTests/Sessions/ProcessInspectorTests.swift
git commit -m "perf(system): run child processes asynchronously and keep herdr I/O off the pool"
```


---

### Task 11: One process snapshot per focus decision, and log why

**Files:**
- Modify: `Relay/Sessions/Domain/FocusModels.swift` (`FocusContext.processSnapshot` replaces `now`; `FocusResolution`; `resolveFocus(among:processSnapshot:)` replaces `focusedSession(among:)`)
- Modify: `Relay/Sessions/FocusResolutionService.swift` (full rewrite)
- Modify: `Relay/Sessions/ProcessInspector.swift` (delete `ProcessTreeReading`; add `ProcessSnapshotProviding`)
- Modify: `Relay/Sessions/Resolvers/TmuxFocusResolver.swift`, `HerdrFocusResolver.swift`
- Modify: `Relay/Sessions/Herdr/HerdrHostOwnership.swift` (takes the snapshot; no `ProcessInspector`)
- Modify: `Relay/Sessions/AgentAutoReadCoordinator.swift` (full rewrite of the file; `AgentProcessContextCapturing`/`AgentProcessContextCapture` deleted)
- Modify: `Relay/Sessions/AgentSessionRegistry.swift` (`pruneDeadSessions(in:snapshot:)`)
- Modify: `Relay/App/AppModel.swift` (`replayLast()`), `Relay/App/RelayRuntime.swift` (wiring)
- Test: `RelayTests/Sessions/FocusResolutionServiceTests.swift`, `TmuxFocusResolverTests.swift` (rewrite), `HerdrFocusResolverTests.swift`, `GenericTerminalFocusResolverTests.swift`, `HerdrHostOwnershipCheckerTests.swift` (rewrite), `AgentAutoReadCoordinatorTests.swift`, `RelayTests/App/AppModelIntegrationsTests.swift`

**Before:** each hook event ran `ps` for capture and `ps` for prune, then per session a frontmost lookup, `ps` per tmux client, and `ps` plus N×`lsof` per herdr session. **After:** one `ps` and one frontmost lookup per decision. The per-session `FocusDecision` (`resolverID`, `state`, `confidence`, `reason`) is written to `IntegrationDiagnosticsLog` under stage `focus`. That is the "why silent?" signal.

- [ ] **Step 1: Update the resolver-level tests (RED)**

Replace the whole of `RelayTests/Sessions/TmuxFocusResolverTests.swift`:

```swift
import XCTest
@testable import Relay

final class TmuxFocusResolverTests: XCTestCase {
    /// Ghostty (20) -> login (100) -> tmux clients 300 and 301.
    private let snapshot = try! ProcessSnapshot.parse("""
      1   0 ??      launchd
     20   1 ??      Ghostty
    100  20 ttys001 login
    300 100 ttys001 tmux
    301 100 ttys002 tmux
    """)

    private func context(frontmostPID: Int32 = 20, snapshot: ProcessSnapshot?) -> FocusContext {
        FocusContext(
            frontmostApplication: .init(pid: frontmostPID, bundleIdentifier: nil, localizedName: "Terminal"),
            sessions: [],
            processSnapshot: snapshot
        )
    }

    func testMatchingFrontmostClientAndPaneIsFocused() async {
        let runner = StubTmuxRunner(clients: [.init(name: "/dev/ttys001", pid: 300)], activePaneByClient: ["/dev/ttys001": "%7"])
        let decision = await TmuxFocusResolver(runner: runner).resolve(session: makeTmuxSession(pane: "%7"), context: context(snapshot: snapshot))
        XCTAssertEqual(decision.state, .focused)
    }

    func testSameClientDifferentPaneIsNotFocused() async {
        let runner = StubTmuxRunner(clients: [.init(name: "/dev/ttys001", pid: 300)], activePaneByClient: ["/dev/ttys001": "%9"])
        let decision = await TmuxFocusResolver(runner: runner).resolve(session: makeTmuxSession(pane: "%7"), context: context(snapshot: snapshot))
        XCTAssertEqual(decision.state, .notFocused)
    }

    func testTwoTmuxClientsUnderSameFrontmostAppAreUnknown() async {
        let runner = StubTmuxRunner(
            clients: [.init(name: "c1", pid: 300), .init(name: "c2", pid: 301)],
            activePaneByClient: ["c1": "%7", "c2": "%8"]
        )
        let decision = await TmuxFocusResolver(runner: runner).resolve(session: makeTmuxSession(pane: "%7"), context: context(snapshot: snapshot))
        XCTAssertEqual(decision.state, .unknown)
    }

    func testMissingProcessSnapshotIsUnknown() async {
        let runner = StubTmuxRunner(clients: [.init(name: "c1", pid: 300)], activePaneByClient: ["c1": "%7"])
        let decision = await TmuxFocusResolver(runner: runner).resolve(session: makeTmuxSession(pane: "%7"), context: context(snapshot: nil))
        XCTAssertEqual(decision.state, .unknown)
        XCTAssertEqual(decision.reason, "process snapshot unavailable")
    }
}

private struct StubTmuxRunner: TmuxCommandRunning {
    let clients: [TmuxClientListing]
    let activePaneByClient: [String: String]
    func listClients(socketPath: String) async throws -> [TmuxClientListing] { clients }
    func activePane(socketPath: String, clientName: String) async throws -> String {
        activePaneByClient[clientName] ?? ""
    }
}

private func makeTmuxSession(pane: String) -> AgentSession {
    let event = AgentResponseEvent(
        id: UUID(), provider: .claudeCode, providerSessionID: "a",
        text: "done", cwd: "/tmp/repo", parentPID: 900,
        environment: ["TMUX": "/tmp/tmux.sock,10,0", "TMUX_PANE": pane], capturedAt: Date()
    )
    return AgentSession(
        id: .init(provider: .claudeCode, providerSessionID: "a"), cwd: event.cwd,
        terminalContext: TerminalContext(event: event), processAncestry: [], tty: nil,
        latestResponse: event, lastActivityAt: event.capturedAt
    )
}
```

In `RelayTests/Sessions/GenericTerminalFocusResolverTests.swift`:

```bash
sed -i '' 's/now: Date()/processSnapshot: nil/' RelayTests/Sessions/GenericTerminalFocusResolverTests.swift
```

In `RelayTests/Sessions/HerdrFocusResolverTests.swift`:
1. Add a file-scope fixture: `private let emptySnapshot = try! ProcessSnapshot.parse("")`.
2. Replace every `now: Date()` with `processSnapshot: emptySnapshot` (`sed -i '' 's/now: Date()/processSnapshot: emptySnapshot/' RelayTests/Sessions/HerdrFocusResolverTests.swift`).
3. Change the stub:

```swift
private struct StubHerdrHostOwnership: HerdrHostOwnershipChecking {
    let owns: Bool
    func frontmostAppOwnsClient(frontmostPID: Int32, socketPath: String, processSnapshot: ProcessSnapshot) async -> Bool { owns }
}
```

4. Add:

```swift
    func testMissingProcessSnapshotIsUnknown() async {
        let resolver = HerdrFocusResolver(
            herdr: StubHerdrQuery(pane: .init(paneID: "w1:p2", focused: true, agentSession: nil)),
            hostOwnership: StubHerdrHostOwnership(owns: true)
        )
        let session = makeHerdrSession(provider: .claudeCode, sessionID: "a", pane: "w1:p2")
        let context = FocusContext(
            frontmostApplication: .init(pid: 20, bundleIdentifier: nil, localizedName: "Ghostty"),
            sessions: [session],
            processSnapshot: nil
        )
        let decision = await resolver.resolve(session: session, context: context)
        XCTAssertEqual(decision.state, .unknown)
    }
```

Replace the whole of `RelayTests/Sessions/HerdrHostOwnershipCheckerTests.swift`:

```swift
import XCTest
@testable import Relay

final class HerdrHostOwnershipCheckerTests: XCTestCase {
    private final class CountingRunner: ProcessRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var runCount: Int { lock.withLock { count } }
        func run(executable: URL, arguments: [String], timeout: TimeInterval, maxOutputBytes: Int) throws -> ProcessResult {
            lock.withLock { count += 1 }
            return ProcessResult(stdout: Data(), terminationStatus: 0)
        }
    }

    /// `sleep 30` stands in for a hung `lsof`: the checker must give up after its own short
    /// timeout and report "not owned" rather than hang the focus path.
    func testHangingLsofTimesOutAndReturnsFalsePromptly() async throws {
        let snapshot = try ProcessSnapshot.parse("1 0 ?? launchd\n100 1 ttys001 herdr")
        let checker = HerdrHostOwnershipChecker(
            lsofExecutableURL: URL(fileURLWithPath: "/bin/sleep"),
            lsofArguments: { _ in ["30"] },
            lsofTimeout: 0.2
        )
        let start = Date()

        let owns = await checker.frontmostAppOwnsClient(frontmostPID: 1, socketPath: "/tmp/does-not-matter.sock", processSnapshot: snapshot)

        XCTAssertFalse(owns)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testNoHerdrDescendantMeansNoLsofAtAll() async throws {
        let snapshot = try ProcessSnapshot.parse("1 0 ?? launchd\n100 1 ttys001 zsh")
        let runner = CountingRunner()
        let checker = HerdrHostOwnershipChecker(runner: runner)

        let owns = await checker.frontmostAppOwnsClient(frontmostPID: 1, socketPath: "/tmp/x.sock", processSnapshot: snapshot)

        XCTAssertFalse(owns)
        XCTAssertEqual(runner.runCount, 0)
    }
}
```

In `RelayTests/Sessions/FocusResolutionServiceTests.swift`, replace the two `focusedSession(among:)` tests with these, and add the helpers at file scope:

```swift
    func testResolveFocusReturnsTheFirstConfidentlyFocusedSessionAndStopsThere() async {
        let a = makeSession(providerSessionID: "a")
        let b = makeSession(providerSessionID: "b")
        let c = makeSession(providerSessionID: "c")
        let service = FocusResolutionService(
            registry: AgentSessionRegistry(),
            frontmostApps: StubFrontmostApp(pid: 20),
            resolvers: [SelectiveFocusResolver(focusedSessionID: b.id)]
        )

        let result = await service.resolveFocus(among: [a, b, c], processSnapshot: nil)

        XCTAssertEqual(result.focused?.id, b.id)
        XCTAssertEqual(result.decisions.map(\.state), [.unknown, .focused])
    }

    func testResolveFocusReturnsNilWhenNoneAreConfidentlyFocused() async {
        let service = FocusResolutionService(
            registry: AgentSessionRegistry(),
            frontmostApps: StubFrontmostApp(pid: 20),
            resolvers: [StubFocusResolver(id: "x", decision: .unknown(resolverID: "x", reason: "ambiguous"))]
        )

        let result = await service.resolveFocus(among: [makeSession(), makeSession(providerSessionID: "b")], processSnapshot: nil)

        XCTAssertNil(result.focused)
        XCTAssertEqual(result.decisions.count, 2)
    }

    func testResolveFocusLooksUpTheFrontmostAppOnceAndSharesOneSnapshot() async throws {
        let frontmost = CountingFrontmostApp(pid: 20)
        let recorder = SnapshotRecordingResolver()
        let service = FocusResolutionService(registry: AgentSessionRegistry(), frontmostApps: frontmost, resolvers: [recorder])
        let snapshot = try ProcessSnapshot.parse("42 1 ?? agent")

        _ = await service.resolveFocus(
            among: [makeSession(providerSessionID: "a"), makeSession(providerSessionID: "b"), makeSession(providerSessionID: "c")],
            processSnapshot: snapshot
        )

        let lookups = await frontmost.lookups
        XCTAssertEqual(lookups, 1)
        XCTAssertEqual(recorder.sawSnapshotContainingPID42, [true, true, true])
    }

    func testUnresolvedSessionKeepsTheResolversSpecificReason() async {
        let service = FocusResolutionService(
            registry: AgentSessionRegistry(),
            frontmostApps: StubFrontmostApp(pid: 20),
            resolvers: [StubFocusResolver(id: "generic-terminal", decision: .unknown(resolverID: "generic-terminal", reason: "ambiguous"))]
        )

        let decision = await service.resolve(session: makeSession())

        XCTAssertEqual(decision.resolverID, "generic-terminal")
        XCTAssertEqual(decision.reason, "ambiguous")
    }
```

```swift
private actor CountingFrontmostApp: FrontmostAppMonitoring {
    let pid: Int32
    private(set) var lookups = 0
    init(pid: Int32) { self.pid = pid }
    func current() async -> FrontmostApplication? {
        lookups += 1
        return .init(pid: pid, bundleIdentifier: nil, localizedName: "Test Terminal")
    }
}

private final class SnapshotRecordingResolver: FocusResolver, @unchecked Sendable {
    let id = "recorder"
    private let lock = NSLock()
    private var seen: [Bool] = []
    var sawSnapshotContainingPID42: [Bool] { lock.withLock { seen } }
    func supports(_ session: AgentSession) -> Bool { true }
    func resolve(session: AgentSession, context: FocusContext) async -> FocusDecision {
        let saw = context.processSnapshot?.record(pid: 42) != nil
        lock.withLock { seen.append(saw) }
        return .unknown(resolverID: id, reason: "recording")
    }
}
```

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/TmuxFocusResolverTests -only-testing:RelayTests/HerdrFocusResolverTests -only-testing:RelayTests/GenericTerminalFocusResolverTests -only-testing:RelayTests/HerdrHostOwnershipCheckerTests -only-testing:RelayTests/FocusResolutionServiceTests`
Expected: build fails with `extra argument 'processSnapshot' in call`, `value of type 'FocusResolutionService' has no member 'resolveFocus'`, and `missing argument for parameter 'processTrees'`.

- [ ] **Step 2: Update the coordinator tests (RED)**

In `RelayTests/Sessions/AgentAutoReadCoordinatorTests.swift`:

1. Delete `StubProcessContextCapture`, and delete the `processContext: StubProcessContextCapture(),` argument in `makeCoordinatorHarness`. In the doc comment on `testDeadSessionIsPrunedBeforeFocusResolution`, change `focusedSession(among:)` to `resolveFocus(among:processSnapshot:)`. Existing tests now get ancestry from the `AlwaysAliveProcessRunner` snapshot, where every pid's parent is 1, instead of the stub's `[parentPID, 20, 1]`. No existing assertion reads ancestry.
2. Replace `MutableStubFocusResolver` with:

```swift
private final class MutableStubFocusResolver: SessionFocusResolving, @unchecked Sendable {
    var focusedSessionID: AgentSessionID?
    /// Decisions `resolveFocus` reports, so tests can check what reaches diagnostics.
    var decisions: [FocusDecision] = []
    /// The ids `resolveFocus` was most recently called with, so tests can prove pruning happened
    /// before this resolver ever saw a candidate list.
    private(set) var lastAmongIDs: [AgentSessionID] = []
    private(set) var lastSnapshotWasProvided = false

    func resolve(session: AgentSession) async -> FocusDecision {
        session.id == focusedSessionID
            ? .focused(resolverID: "stub", reason: "stubbed focused session")
            : .unknown(resolverID: "stub", reason: "not the stubbed focused session")
    }

    func resolveFocus(among sessions: [AgentSession], processSnapshot: ProcessSnapshot?) async -> FocusResolution {
        lastAmongIDs = sessions.map(\.id)
        lastSnapshotWasProvided = processSnapshot != nil
        let focused = focusedSessionID.flatMap { id in sessions.first { $0.id == id } }
        return FocusResolution(focused: focused, decisions: decisions)
    }
}
```

3. Add a counting runner and two tests:

```swift
private final class CountingProcessRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var runCount: Int { lock.withLock { count } }
    func run(executable: URL, arguments: [String], timeout: TimeInterval, maxOutputBytes: Int) throws -> ProcessResult {
        lock.withLock { count += 1 }
        let lines = (1...2_000).map { "\($0) 1 ttys001 fake" }.joined(separator: "\n")
        return ProcessResult(stdout: Data(lines.utf8), terminationStatus: 0)
    }
}
```

```swift
    // MARK: - One snapshot per decision

    func testOneProcessSnapshotServesCapturePruneAndFocus() async {
        let runner = CountingProcessRunner()
        let focus = MutableStubFocusResolver()
        let coordinator = makeCoordinator(
            focus: focus, speech: RecordingSpeechSink(), autoRead: true,
            processInspector: ProcessInspector(runner: runner)
        )

        await coordinator.handle(makeAutoReadEvent(providerSessionID: "a", text: "done"))

        XCTAssertEqual(runner.runCount, 1)
        XCTAssertTrue(focus.lastSnapshotWasProvided)
    }

    func testFocusDecisionReasonsAreRecordedForDiagnostics() async {
        let diagnostics = IntegrationDiagnosticsLog()
        let focus = MutableStubFocusResolver()
        focus.decisions = [.unknown(resolverID: "generic-terminal", reason: "multiple direct agent sessions share the frontmost terminal process")]
        let coordinator = makeCoordinator(focus: focus, speech: RecordingSpeechSink(), autoRead: true, diagnostics: diagnostics)

        await coordinator.handle(makeAutoReadEvent(providerSessionID: "a", text: "done"))

        let entry = diagnostics.snapshot().first { $0.stage == "focus" }
        XCTAssertEqual(entry?.outcome, "unknown")
        XCTAssertEqual(
            entry?.detail,
            "resolver=generic-terminal confidence=low reason=multiple direct agent sessions share the frontmost terminal process"
        )
    }
```

In `RelayTests/App/AppModelIntegrationsTests.swift`, delete the `processContext: StubWiringProcessContextCapture(),` argument and the `StubWiringProcessContextCapture` struct.

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/AgentAutoReadCoordinatorTests`
Expected: build fails with `cannot find type 'FocusResolution' in scope`.

- [ ] **Step 3: Rewrite the focus domain types**

In `Relay/Sessions/Domain/FocusModels.swift`, replace everything from `struct FocusContext: Sendable {` to the end of the file with the block below. That range covers `FocusContext`, `FocusResolver`, `SessionFocusResolving` and its extension. `FocusState`, `FocusConfidence` and `FocusDecision` above it stay as they are.

```swift
extension FocusDecision {
    var isConfidentlyFocused: Bool { state == .focused && confidence == .high }
}

/// Everything a resolver may consult for ONE focus decision. Built once per decision and shared
/// by every resolver and every candidate session, so the frontmost app is looked up once and the
/// process table is read once.
struct FocusContext: Sendable {
    let frontmostApplication: FrontmostApplication?
    let sessions: [AgentSession]
    /// One `ps` snapshot for this decision; `nil` when it could not be taken (resolvers that
    /// need it answer `.unknown`).
    let processSnapshot: ProcessSnapshot?
}

/// The outcome of resolving focus across candidate sessions: the confidently focused session
/// (if any) plus every per-session decision made on the way, in order, for diagnostics.
struct FocusResolution: Sendable, Equatable {
    let focused: AgentSession?
    let decisions: [FocusDecision]
}

protocol FocusResolver: Sendable {
    var id: String { get }
    func supports(_ session: AgentSession) -> Bool
    func resolve(session: AgentSession, context: FocusContext) async -> FocusDecision
}

protocol SessionFocusResolving: Sendable {
    func resolve(session: AgentSession) async -> FocusDecision

    /// Resolves `sessions` in order and stops at the first confidently focused one. Conformers
    /// that can share one context across sessions (`FocusResolutionService`) use
    /// `processSnapshot` for it; the default below simply calls `resolve(session:)` per session.
    func resolveFocus(among sessions: [AgentSession], processSnapshot: ProcessSnapshot?) async -> FocusResolution
}

extension SessionFocusResolving {
    func resolveFocus(among sessions: [AgentSession], processSnapshot: ProcessSnapshot?) async -> FocusResolution {
        var decisions: [FocusDecision] = []
        for session in sessions {
            let decision = await resolve(session: session)
            decisions.append(decision)
            if decision.isConfidentlyFocused {
                return FocusResolution(focused: session, decisions: decisions)
            }
        }
        return FocusResolution(focused: nil, decisions: decisions)
    }
}
```

(`FocusResolver` is re-emitted unchanged. `\(decision.confidence)` interpolates the case name, `low`/`medium`/`high`, because `FocusConfidence` is an `Int`-backed enum without `CustomStringConvertible`.)

In `Relay/Sessions/ProcessInspector.swift`, delete `protocol ProcessTreeReading` and its `extension ProcessInspector: ProcessTreeReading`, and add:

```swift
/// Source of process-table snapshots (`ProcessInspector`'s real `ps` in production).
protocol ProcessSnapshotProviding: Sendable {
    func snapshot() async throws -> ProcessSnapshot
}

extension ProcessInspector: ProcessSnapshotProviding {}
```

- [ ] **Step 4: Rewrite `FocusResolutionService`**

Replace the whole of `Relay/Sessions/FocusResolutionService.swift`:

```swift
import Foundation

/// Runs the ordered resolver chain (Herdr -> tmux -> generic terminal) for agent sessions.
///
/// `resolveFocus(among:processSnapshot:)` is the hot path: ONE frontmost-app lookup and the
/// caller's ONE process snapshot are put into a single `FocusContext` that every resolver and
/// every candidate session shares. `resolve(session:)` is the standalone form and takes its own
/// snapshot.
actor FocusResolutionService {
    private let registry: AgentSessionRegistry
    private let frontmostApps: FrontmostAppMonitoring
    private let processSnapshots: any ProcessSnapshotProviding
    private let resolvers: [any FocusResolver]

    init(
        registry: AgentSessionRegistry,
        frontmostApps: FrontmostAppMonitoring,
        processSnapshots: any ProcessSnapshotProviding = ProcessInspector(),
        resolvers: [any FocusResolver]
    ) {
        self.registry = registry
        self.frontmostApps = frontmostApps
        self.processSnapshots = processSnapshots
        self.resolvers = resolvers
    }

    func resolve(session: AgentSession) async -> FocusDecision {
        let snapshot = try? await processSnapshots.snapshot()
        let context = FocusContext(
            frontmostApplication: await frontmostApps.current(),
            sessions: await registry.sessions(),
            processSnapshot: snapshot
        )
        return await decide(session: session, context: context)
    }

    func resolveFocus(among sessions: [AgentSession], processSnapshot: ProcessSnapshot?) async -> FocusResolution {
        let context = FocusContext(
            frontmostApplication: await frontmostApps.current(),
            sessions: sessions,
            processSnapshot: processSnapshot
        )
        var decisions: [FocusDecision] = []
        for session in sessions {
            let decision = await decide(session: session, context: context)
            decisions.append(decision)
            if decision.isConfidentlyFocused {
                return FocusResolution(focused: session, decisions: decisions)
            }
        }
        return FocusResolution(focused: nil, decisions: decisions)
    }

    /// First high-confidence, non-unknown decision from a supporting resolver wins. Otherwise
    /// the last resolver's own `.unknown` (with its specific reason) is returned, so diagnostics
    /// can say WHY focus was unknown.
    private func decide(session: AgentSession, context: FocusContext) async -> FocusDecision {
        var lastUnknown: FocusDecision?
        for resolver in resolvers where resolver.supports(session) {
            let decision = await resolver.resolve(session: session, context: context)
            if decision.confidence == .high && decision.state != .unknown { return decision }
            lastUnknown = decision
        }
        return lastUnknown ?? .unknown(resolverID: "focus-resolution", reason: "no resolver supports this session")
    }
}

extension FocusResolutionService: SessionFocusResolving {}
```

- [ ] **Step 5: Move the resolvers and the Herdr checker onto the shared snapshot**

`Relay/Sessions/Resolvers/TmuxFocusResolver.swift`, full replacement:

```swift
import Foundation

struct TmuxFocusResolver: FocusResolver {
    let id = "tmux"
    let runner: any TmuxCommandRunning

    func supports(_ session: AgentSession) -> Bool {
        session.terminalContext.tmuxSocketPath != nil && session.terminalContext.tmuxPaneID != nil
    }

    func resolve(session: AgentSession, context: FocusContext) async -> FocusDecision {
        guard let frontmostPID = context.frontmostApplication?.pid,
              let socket = session.terminalContext.tmuxSocketPath,
              let producingPane = session.terminalContext.tmuxPaneID else {
            return .unknown(resolverID: id, reason: "missing frontmost app or tmux identifiers")
        }
        guard let snapshot = context.processSnapshot else {
            return .unknown(resolverID: id, reason: "process snapshot unavailable")
        }
        do {
            let clients = try await runner.listClients(socketPath: socket)
            let frontmostClients = clients.filter { client in
                snapshot.ancestry(from: client.pid).contains { $0.pid == frontmostPID }
            }
            guard frontmostClients.count == 1, let client = frontmostClients.first else {
                return frontmostClients.isEmpty
                    ? .notFocused(resolverID: id, reason: "no client for this tmux server belongs to frontmost application")
                    : .unknown(resolverID: id, reason: "multiple tmux clients belong to the same frontmost application")
            }
            let activePane = try await runner.activePane(socketPath: socket, clientName: client.name)
            return activePane == producingPane
                ? .focused(resolverID: id, reason: "frontmost tmux client active pane matches producing pane")
                : .notFocused(resolverID: id, reason: "frontmost tmux client is focused on a different pane")
        } catch {
            return .unknown(resolverID: id, reason: "tmux focus query failed")
        }
    }
}
```

`Relay/Sessions/Resolvers/HerdrFocusResolver.swift`: in `resolve(session:context:)`, replace the `guard await hostOwnership.frontmostAppOwnsClient(...)` line and what comes before it (after the identifiers `guard`) with:

```swift
        guard let processSnapshot = context.processSnapshot else {
            return .unknown(resolverID: id, reason: "process snapshot unavailable")
        }
        guard await hostOwnership.frontmostAppOwnsClient(
            frontmostPID: frontmostPID,
            socketPath: socket,
            processSnapshot: processSnapshot
        ) else {
            return .notFocused(resolverID: id, reason: "frontmost app does not own a client for this Herdr socket")
        }
```

`Relay/Sessions/Herdr/HerdrHostOwnership.swift`: change the protocol, drop `processInspector`, and take the snapshot:

```swift
protocol HerdrHostOwnershipChecking: Sendable {
    func frontmostAppOwnsClient(frontmostPID: Int32, socketPath: String, processSnapshot: ProcessSnapshot) async -> Bool
}
```

In `HerdrHostOwnershipChecker`: delete `let processInspector: ProcessInspector` and the `processInspector:` init parameter/assignment (the other init parameters stay the same), and replace `frontmostAppOwnsClient`:

```swift
    func frontmostAppOwnsClient(frontmostPID: Int32, socketPath: String, processSnapshot: ProcessSnapshot) async -> Bool {
        let candidates = processSnapshot.descendants(of: frontmostPID).filter {
            URL(fileURLWithPath: $0.command).lastPathComponent.lowercased() == "herdr"
        }
        for candidate in candidates {
            if await lsof(pid: candidate.pid, contains: socketPath) { return true }
        }
        return false
    }
```

- [ ] **Step 6: Rewrite the coordinator around one snapshot**

In `Relay/Sessions/AgentSessionRegistry.swift`, replace `pruneDeadSessions(in:using:)`:

```swift
/// Prunes `registry` against `snapshot` — the SAME snapshot the caller uses for the rest of its
/// focus decision. A `nil` snapshot (failed `ps`) skips pruning for this cycle rather than
/// risking a false "dead" verdict on a session that is still running.
func pruneDeadSessions(in registry: AgentSessionRegistry, snapshot: ProcessSnapshot?) async {
    guard let snapshot else { return }
    await registry.prune(isAlive: { pid in snapshot.record(pid: pid) != nil })
}
```

Replace everything in `Relay/Sessions/AgentAutoReadCoordinator.swift` above `actor AgentAutoReadCoordinator` (the `AgentProcessContext` struct, the `AgentProcessContextCapturing` protocol, and `AgentProcessContextCapture`) with:

```swift
import Foundation

/// Process ancestry and tty for the process that emitted an agent response, used by
/// `AgentSessionRegistry`/focus resolvers to identify which terminal/multiplexer pane a session
/// runs in.
struct AgentProcessContext: Sendable, Equatable {
    let ancestry: [Int32]
    let tty: String?

    /// Walks `parentPID`'s ancestry in `snapshot`. No snapshot (failed `ps`) degrades to an empty
    /// context: session tracking and gating treat "no ancestry" as "unknown", never a crash.
    static func capture(parentPID: Int32, in snapshot: ProcessSnapshot?) -> AgentProcessContext {
        guard let snapshot else { return AgentProcessContext(ancestry: [], tty: nil) }
        let records = snapshot.ancestry(from: parentPID)
        return AgentProcessContext(ancestry: records.map(\.pid), tty: records.compactMap(\.tty).first)
    }
}
```

Inside `actor AgentAutoReadCoordinator`:
1. Delete `private let processContext: any AgentProcessContextCapturing`, the `processContext:` init parameter, and its assignment.
2. Replace the `processInspector` doc comment with: `/// Takes the ONE process-table snapshot per \`handle(_:)\` that ancestry capture, pruning, and every focus resolver share.`
3. Replace the start of `handle(_:)`, down to and including the existing `diagnostics.append(… outcome: "focus-decision" …)` call, with:

```swift
    func handle(_ event: AgentResponseEvent) async {
        // One snapshot per event, shared by ancestry capture, pruning, and every focus resolver.
        let snapshot = try? await processInspector.snapshot()
        let captured = AgentProcessContext.capture(parentPID: event.parentPID, in: snapshot)
        let session = await registry.upsert(
            response: event,
            processAncestry: captured.ancestry,
            tty: captured.tty
        )
        diagnostics.append(stage: "coordinator", outcome: "session-upserted", detail: "provider=\(event.provider.rawValue)")

        guard await autoReadEnabled() else {
            diagnostics.append(stage: "coordinator", outcome: "silent", detail: "auto-read-disabled")
            return
        }

        // Prune before every focus decision so a dead agent's session (or one past the TTL)
        // never keeps generic-terminal focus ambiguous.
        await pruneDeadSessions(in: registry, snapshot: snapshot)

        let sessions = await registry.sessions()
        let resolution = await focus.resolveFocus(among: sessions, processSnapshot: snapshot)
        recordFocusDecisions(resolution.decisions)
        let focused = resolution.focused
        diagnostics.append(
            stage: "coordinator",
            outcome: "focus-decision",
            detail: "focused=\(focused.map { Self.label($0.id) } ?? "none") lastActive=\(lastActiveSessionID.map(Self.label) ?? "none")"
        )
```

Leave the rest of `handle(_:)` (the focused / last-active / handoff branches) unchanged. Add:

```swift
    /// The "why silent?" signal: one privacy-safe entry per session resolved — resolver ID,
    /// state, confidence, and the resolver's reason (always a fixed literal, never payload,
    /// paths, or IDs).
    private func recordFocusDecisions(_ decisions: [FocusDecision]) {
        for decision in decisions {
            diagnostics.append(
                stage: "focus",
                outcome: decision.state.rawValue,
                detail: "resolver=\(decision.resolverID) confidence=\(decision.confidence) reason=\(decision.reason)"
            )
        }
    }
```

Check that every `reason:` string passed to `FocusDecision.focused/notFocused/unknown` in `Relay/Sessions` is a literal:

```bash
grep -rn 'reason: "' Relay/Sessions | grep '\\(' || echo "all reasons are literals"
```

Expected: `all reasons are literals`.

- [ ] **Step 7: `AppModel.replayLast()` and production wiring**

In `Relay/App/AppModel.swift`, replace the start of `replayLast()`, from `await pruneDeadSessions(in: sessionRegistry, using: processInspector)` through the closing `}` of the `for session in sessions { … }` loop, with:

```swift
        // One snapshot for this decision, shared by pruning and every focus resolver — the same
        // shape as `AgentAutoReadCoordinator.handle(_:)`.
        let snapshot = try? await processInspector.snapshot()
        await pruneDeadSessions(in: sessionRegistry, snapshot: snapshot)
        let sessions = await sessionRegistry.sessions()

        if let focused = await focusResolution.resolveFocus(among: sessions, processSnapshot: snapshot).focused {
            guard !Task.isCancelled else { return }
            await speakFocusedSessionReply(focused)
            return
        }
```

Leave tier 2 and tier 3 unchanged, including plan 1's `guard !Task.isCancelled else { return }` before each of them. After the edit, `replayLast()` must still hold three `isCancelled` guards: before tier 1, tier 2 and tier 3. The guards in `readSelection` and the replay `Task` closure are untouched. Check:

```bash
grep -n "isCancelled" Relay/App/AppModel.swift
```

Expected: the same number of lines as before this step (today 6).

In `Relay/App/RelayRuntime.swift`:
1. Delete `let agentProcessContext = AgentProcessContextCapture(processInspector: processInspector)`.
2. Replace the resolver/service construction with:

```swift
        var resolvers: [any FocusResolver] = []
        resolvers.append(HerdrFocusResolver(
            herdr: herdrClient,
            hostOwnership: HerdrHostOwnershipChecker()
        ))
        if let tmuxRunner {
            resolvers.append(TmuxFocusResolver(runner: tmuxRunner))
        }
        resolvers.append(GenericTerminalFocusResolver())

        let focusResolution = FocusResolutionService(
            registry: sessionRegistry,
            frontmostApps: frontmostApps,
            processSnapshots: processInspector,
            resolvers: resolvers
        )
```

3. Delete the `processContext: agentProcessContext,` argument from `AgentAutoReadCoordinator(...)`.

Confirm the removed symbols are gone:

```bash
grep -rn "ProcessTreeReading\|AgentProcessContextCapturing\|AgentProcessContextCapture\b\|focusedSession(among\|processTrees:" Relay RelayTests
```

Expected: no output.

- [ ] **Step 8: Run to verify GREEN**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/TmuxFocusResolverTests -only-testing:RelayTests/HerdrFocusResolverTests -only-testing:RelayTests/GenericTerminalFocusResolverTests -only-testing:RelayTests/HerdrHostOwnershipCheckerTests -only-testing:RelayTests/FocusResolutionServiceTests -only-testing:RelayTests/AgentAutoReadCoordinatorTests -only-testing:RelayTests/AppModelTests -only-testing:RelayTests/AppModelIntegrationsTests -only-testing:RelayTests/ProjectSmokeTests`
Expected: `** TEST SUCCEEDED **`. That includes the existing `testDeadSessionIsPrunedBeforeFocusResolution`: ancestry now comes from the shared snapshot, and pid 111 is missing from the second snapshot.

- [ ] **Step 9: Full suite, then commit**

Run the full suite. Expected: `** TEST SUCCEEDED **`.

```bash
git add Relay/Sessions/Domain/FocusModels.swift Relay/Sessions/FocusResolutionService.swift Relay/Sessions/ProcessInspector.swift Relay/Sessions/Resolvers/TmuxFocusResolver.swift Relay/Sessions/Resolvers/HerdrFocusResolver.swift Relay/Sessions/Herdr/HerdrHostOwnership.swift Relay/Sessions/AgentAutoReadCoordinator.swift Relay/Sessions/AgentSessionRegistry.swift Relay/App/AppModel.swift Relay/App/RelayRuntime.swift RelayTests/Sessions/FocusResolutionServiceTests.swift RelayTests/Sessions/TmuxFocusResolverTests.swift RelayTests/Sessions/HerdrFocusResolverTests.swift RelayTests/Sessions/GenericTerminalFocusResolverTests.swift RelayTests/Sessions/HerdrHostOwnershipCheckerTests.swift RelayTests/Sessions/AgentAutoReadCoordinatorTests.swift RelayTests/App/AppModelIntegrationsTests.swift
git commit -m "perf(sessions): one process snapshot per focus decision and log decision reasons"
```

---

### Task 12: Codex `config.toml` precheck handles dotted keys and inline tables

**Files:**
- Modify: `Relay/Integrations/Codex/CodexInstaller.swift` (`tomlExplicitlyDisablesHooks`, new helpers)
- Test: `RelayTests/Integrations/CodexInstallerTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `CodexInstallerTests`:

```swift
    func testTomlDottedRootKeyDisablesHooks() {
        XCTAssertTrue(CodexInstaller.tomlExplicitlyDisablesHooks("features.hooks = false\n"))
        XCTAssertTrue(CodexInstaller.tomlExplicitlyDisablesHooks("model = \"o3\"\nfeatures . hooks=false # off\n"))
    }

    func testTomlInlineFeaturesTableDisablesHooks() {
        XCTAssertTrue(CodexInstaller.tomlExplicitlyDisablesHooks("features = { hooks = false }\n"))
        XCTAssertTrue(CodexInstaller.tomlExplicitlyDisablesHooks("features = { web_search = true, hooks = false }\n"))
    }

    func testTomlNonDisablingVariantsAreIgnored() {
        XCTAssertFalse(CodexInstaller.tomlExplicitlyDisablesHooks("features.hooks = true\n"))
        XCTAssertFalse(CodexInstaller.tomlExplicitlyDisablesHooks("features = { hooks = true }\n"))
        XCTAssertFalse(CodexInstaller.tomlExplicitlyDisablesHooks("# features.hooks = false\n"))
        XCTAssertFalse(CodexInstaller.tomlExplicitlyDisablesHooks("[other]\nfeatures.hooks = false\n"))
        XCTAssertFalse(CodexInstaller.tomlExplicitlyDisablesHooks("[[features]]\nhooks = false\n"))
    }

    func testInstallRefusesWhenDottedKeyDisablesHooks() throws {
        try writeConfigToml("features.hooks = false\n")
        XCTAssertThrowsError(try makeInstaller().install()) { error in
            XCTAssertEqual(error as? IntegrationInstallerError, .hooksDisabledInConfig)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: hooksURL.path))
    }
```

- [ ] **Step 2: Run to verify RED**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/CodexInstallerTests`
Expected: `** TEST FAILED **`. `testTomlDottedRootKeyDisablesHooks`, `testTomlInlineFeaturesTableDisablesHooks` and `testInstallRefusesWhenDottedKeyDisablesHooks` fail.

- [ ] **Step 3: Extend the scan**

In `CodexInstaller`, replace `tomlExplicitlyDisablesHooks(_:)` (and its doc comment) with the following. Keep `stripTomlComment(_:)` as it is:

```swift
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
```

Update the `configExplicitlyDisablesHooks()` doc comment to say "any of the forms `tomlExplicitlyDisablesHooks(_:)` recognises".

- [ ] **Step 4: Run to verify GREEN**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/CodexInstallerTests -only-testing:RelayTests/AppModelIntegrationsTests`
Expected: `** TEST SUCCEEDED **`. The existing CRLF, commented-header, nested-table and inline-comment tests still pass.

- [ ] **Step 5: Full suite, then commit**

Run the full suite. Expected: `** TEST SUCCEEDED **`.

```bash
git add Relay/Integrations/Codex/CodexInstaller.swift RelayTests/Integrations/CodexInstallerTests.swift
git commit -m "fix(codex): detect dotted and inline-table hooks opt-out in config.toml"
```

---

### Task 13: `RelayHook` captures its own ancestry (session identity robustness)

**Files:**
- Create: `Shared/ProcessAncestry.swift`
- Create: `RelayTests/Shared/ProcessAncestryTests.swift`
- Modify: `HookEnvelope` (`Relay/Integrations/Domain/HookEnvelope.swift`, or wherever plan 1 moved it): add `var processAncestry: [Int32]? = nil`
- Modify: `Relay/Integrations/Domain/AgentResponseEvent.swift`: add `var processAncestry: [Int32]? = nil`
- Modify: `Relay/Integrations/StopHookIntegration.swift` (copy the field through)
- Modify: `Relay/Sessions/AgentAutoReadCoordinator.swift` (`AgentProcessContext.resolve(for:in:)`, use it)
- Modify: `RelayHook/main.swift` (populate the field)
- Test: `RelayTests/Integrations/HookEnvelopeTests.swift`, `StopHookIntegrationTests.swift`, `RelayTests/Sessions/AgentAutoReadCoordinatorTests.swift`

**Why:** today the app runs `ps` after `RelayHook` has exited and treats `processAncestry.first` (the hook's parent) as the agent. If the agent spawns hooks through `sh -c`, that parent is the short-lived shell. By the time the app looks it may be gone (empty ancestry), or pruning may later mark the session dead. `RelayHook` now walks its own ancestry synchronously with `sysctl(KERN_PROC_PID)` (max 16 hops, no child process), drops leading wrapper shells, and sends the result. The app prefers it and falls back to the snapshot walk for old helpers.

- [ ] **Step 1: Write the failing tests**

Create `RelayTests/Shared/ProcessAncestryTests.swift`:

```swift
import XCTest
@testable import Relay

final class ProcessAncestryTests: XCTestCase {
    private func table(_ rows: [(Int32, Int32, String)]) -> (Int32) -> ProcessAncestry.Entry? {
        let entries = Dictionary(uniqueKeysWithValues: rows.map {
            ($0.0, ProcessAncestry.Entry(pid: $0.0, parentPID: $0.1, command: $0.2))
        })
        return { entries[$0] }
    }

    func testRealChainStartsAtThisProcessThenItsParent() {
        let chain = ProcessAncestry.chain(from: getpid())
        XCTAssertEqual(chain.first?.pid, getpid())
        XCTAssertEqual(chain.dropFirst().first?.pid, getppid())
        XCTAssertLessThanOrEqual(chain.count, ProcessAncestry.maxDepth)
    }

    func testMissingProcessYieldsAnEmptyChain() {
        XCTAssertTrue(ProcessAncestry.chain(from: 900, lookup: table([])).isEmpty)
    }

    func testCyclesAndDepthAreBounded() {
        let cyclic = table([(10, 11, "a"), (11, 10, "b")])
        XCTAssertEqual(ProcessAncestry.chain(from: 10, lookup: cyclic).map(\.pid), [10, 11])

        let deep = table((1...40).map { (Int32($0), Int32($0 + 1), "p") })
        XCTAssertEqual(ProcessAncestry.chain(from: 1, lookup: deep).count, ProcessAncestry.maxDepth)
    }

    func testLeadingWrapperShellIsTrimmedSoTheAgentComesFirst() {
        let lookup = table([(900, 800, "sh"), (800, 700, "claude"), (700, 20, "zsh"), (20, 1, "Ghostty"), (1, 0, "launchd")])
        XCTAssertEqual(ProcessAncestry.agentAncestry(from: 900, lookup: lookup), [800, 700, 20, 1])
    }

    func testDirectExecChainIsUnchangedAndTheLoginShellAboveTheAgentIsKept() {
        let lookup = table([(800, 700, "claude"), (700, 20, "zsh"), (20, 1, "Ghostty"), (1, 0, "launchd")])
        XCTAssertEqual(ProcessAncestry.agentAncestry(from: 800, lookup: lookup), [800, 700, 20, 1])
    }

    func testAllShellChainIsKeptUntrimmed() {
        let lookup = table([(900, 800, "sh"), (800, 0, "zsh")])
        XCTAssertEqual(ProcessAncestry.agentAncestry(from: 900, lookup: lookup), [900, 800])
    }
}
```

Append to `HookEnvelopeTests`:

```swift
    func testEnvelopeRoundTripsProcessAncestry() throws {
        let envelope = HookEnvelope(
            schemaVersion: 1, provider: .codex, rawPayload: "{}", parentPID: 900,
            environment: [:], capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            processAncestry: [800, 700, 1]
        )
        XCTAssertEqual(try JSONDecoder().decode(HookEnvelope.self, from: JSONEncoder().encode(envelope)), envelope)
    }

    func testEnvelopeFromAnOlderHelperDecodesWithoutAncestry() throws {
        let json = #"{"schemaVersion":1,"provider":"codex","rawPayload":"{}","parentPID":1,"environment":{},"capturedAt":1700000000}"#
        XCTAssertNil(try JSONDecoder().decode(HookEnvelope.self, from: Data(json.utf8)).processAncestry)
    }
```

Append to `StopHookIntegrationTests`:

```swift
    func testEnvelopeAncestryIsCarriedOntoTheEvent() throws {
        var hookEnvelope = envelope(provider: .claudeCode, rawPayload: payload())
        hookEnvelope.processAncestry = [800, 700]
        XCTAssertEqual(try StopHookIntegration.claudeCode.decode(hookEnvelope).processAncestry, [800, 700])
    }
```

In `AgentAutoReadCoordinatorTests`, change `makeAutoReadEvent` to accept ancestry:

```swift
private func makeAutoReadEvent(
    providerSessionID: String = "a",
    text: String,
    parentPID: Int32 = 900,
    processAncestry: [Int32]? = nil
) -> AgentResponseEvent {
    .init(
        id: UUID(), provider: .claudeCode, providerSessionID: providerSessionID,
        text: text, cwd: "/tmp/repo",
        parentPID: parentPID, environment: [:], capturedAt: Date(),
        processAncestry: processAncestry
    )
}
```

and add:

```swift
    // MARK: - Envelope ancestry

    func testEnvelopeAncestryIsPreferredOverSnapshotCapture() async {
        let harness = makeCoordinatorHarness(
            focus: MutableStubFocusResolver(), speech: RecordingSpeechSink(), autoRead: true,
            processInspector: ProcessInspector(runner: MutableAliveProcessRunner(alivePIDs: [4242, 20]))
        )

        // parentPID 900 is not in the snapshot: a snapshot walk would yield [].
        await harness.coordinator.handle(makeAutoReadEvent(text: "done", parentPID: 900, processAncestry: [4242, 20, 1]))

        let session = await harness.registry.sessions().first
        XCTAssertEqual(session?.processAncestry, [4242, 20, 1])
        XCTAssertEqual(session?.tty, "ttys001")
    }

    func testWithoutEnvelopeAncestryFallsBackToSnapshotCapture() async {
        let harness = makeCoordinatorHarness(
            focus: MutableStubFocusResolver(), speech: RecordingSpeechSink(), autoRead: true,
            processInspector: ProcessInspector(runner: MutableAliveProcessRunner(alivePIDs: [222]))
        )

        await harness.coordinator.handle(makeAutoReadEvent(text: "done", parentPID: 222))

        let session = await harness.registry.sessions().first
        XCTAssertEqual(session?.processAncestry, [222])
    }
```

- [ ] **Step 2: Run to verify RED**

Run: `xcodegen generate && xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/ProcessAncestryTests -only-testing:RelayTests/HookEnvelopeTests -only-testing:RelayTests/StopHookIntegrationTests -only-testing:RelayTests/AgentAutoReadCoordinatorTests`
Expected: build fails with `cannot find 'ProcessAncestry' in scope`, and `extra argument 'processAncestry' in call`.

- [ ] **Step 3: Create `Shared/ProcessAncestry.swift`**

```swift
import Darwin
import Foundation

/// Reads a process's parent chain straight from the kernel (`sysctl(KERN_PROC_PID)`), with no
/// child process. `RelayHook` calls this synchronously before it exits, so the chain is captured
/// while every ancestor — including a transient `sh -c` wrapper — is still alive.
///
/// Compiled into BOTH the `Relay` app target (for tests) and the `RelayHook` helper target.
enum ProcessAncestry {
    struct Entry: Equatable, Sendable {
        let pid: Int32
        let parentPID: Int32
        let command: String
    }

    /// Hard bound on hops, so a corrupt or cyclic table can never spin.
    static let maxDepth = 16

    /// Shell basenames treated as transient hook wrappers when they sit at the FRONT of the
    /// chain (below the agent). A login shell above the agent is never trimmed, because trimming
    /// stops at the first non-shell entry.
    static let wrapperShellNames: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh"]

    /// One kernel lookup. `nil` when `pid` does not exist.
    static func entry(pid: Int32) -> Entry? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }
        let command = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return Entry(pid: pid, parentPID: info.kp_eproc.e_ppid, command: command)
    }

    /// `pid` first, then each parent, stopping at pid 0, a missing process, a repeated pid, or
    /// `maxDepth` entries.
    static func chain(
        from pid: Int32,
        maxDepth: Int = ProcessAncestry.maxDepth,
        lookup: (Int32) -> Entry? = ProcessAncestry.entry(pid:)
    ) -> [Entry] {
        var result: [Entry] = []
        var visited = Set<Int32>()
        var current = pid
        while current > 0, result.count < maxDepth, visited.insert(current).inserted, let entry = lookup(current) {
            result.append(entry)
            current = entry.parentPID
        }
        return result
    }

    /// The pids Relay records for a session: `chain(from:)` with leading wrapper shells dropped,
    /// so `first` is the agent process even when it spawned the hook via `sh -c`. If every entry
    /// is a shell, the untrimmed chain is returned.
    static func agentAncestry(
        from pid: Int32,
        maxDepth: Int = ProcessAncestry.maxDepth,
        lookup: (Int32) -> Entry? = ProcessAncestry.entry(pid:)
    ) -> [Int32] {
        let full = chain(from: pid, maxDepth: maxDepth, lookup: lookup)
        let trimmed = full.drop { wrapperShellNames.contains($0.command) }
        return (trimmed.isEmpty ? full[...] : trimmed).map(\.pid)
    }
}
```

- [ ] **Step 4: Carry the field end to end**

In `HookEnvelope`, add as the last stored property:

```swift
    /// Ancestry `RelayHook` captured itself before exiting (agent first, wrapper shells trimmed;
    /// see `ProcessAncestry.agentAncestry`). Optional so envelopes from older helpers still
    /// decode; `schemaVersion` stays 1.
    var processAncestry: [Int32]? = nil
```

In `AgentResponseEvent`, add as the last stored property:

```swift
    /// Copied from `HookEnvelope.processAncestry`; `nil` when the helper did not send it.
    var processAncestry: [Int32]? = nil
```

In `StopHookIntegration.decode`, add `processAncestry: envelope.processAncestry` as the last argument of the `AgentResponseEvent(...)` initializer.

In `Relay/Sessions/AgentAutoReadCoordinator.swift`, add this to `AgentProcessContext`:

```swift
    /// Prefers the ancestry `RelayHook` captured itself (exact, and still correct after a
    /// wrapper shell has exited); falls back to walking `event.parentPID` in `snapshot` for
    /// envelopes from older helpers. The tty comes from the snapshot either way.
    static func resolve(for event: AgentResponseEvent, in snapshot: ProcessSnapshot?) -> AgentProcessContext {
        if let ancestry = event.processAncestry, let agentPID = ancestry.first {
            return AgentProcessContext(ancestry: ancestry, tty: snapshot?.record(pid: agentPID)?.tty)
        }
        return capture(parentPID: event.parentPID, in: snapshot)
    }
```

In `handle(_:)`, replace `let captured = AgentProcessContext.capture(parentPID: event.parentPID, in: snapshot)` with:

```swift
        let captured = AgentProcessContext.resolve(for: event, in: snapshot)
```

and change the `session-upserted` diagnostics detail to:

```swift
        diagnostics.append(
            stage: "coordinator",
            outcome: "session-upserted",
            detail: "provider=\(event.provider.rawValue) ancestry=\(event.processAncestry?.isEmpty == false ? "envelope" : "snapshot")"
        )
```

In `RelayHook/main.swift`, where the envelope is built, capture the parent once and send the ancestry:

```swift
    let parentPID = getppid()
    let envelope = HookEnvelope(
        schemaVersion: 1,
        provider: provider,
        rawPayload: rawPayload,
        parentPID: parentPID,
        environment: environment,
        capturedAt: Date(),
        // Captured synchronously now, while every ancestor (including a transient `sh -c`
        // wrapper) is still alive. Bounded: at most 16 sysctl calls, no child process.
        processAncestry: ProcessAncestry.agentAncestry(from: parentPID)
    )
```

Keep plan 1's size check and encoder options exactly as they are.

- [ ] **Step 5: Run to verify GREEN**

Run: `xcodegen generate && xcodebuild test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:RelayTests/ProcessAncestryTests -only-testing:RelayTests/HookEnvelopeTests -only-testing:RelayTests/HookEnvelopeReceiverTests -only-testing:RelayTests/StopHookIntegrationTests -only-testing:RelayTests/AgentAutoReadCoordinatorTests -only-testing:RelayTests/IntegrationManagerTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Smoke-test the helper binary**

Build, then run the helper through an `sh -c` wrapper (the case the ancestry trim exists for). With no app listening, the send fails silently. This step proves the new sysctl walk neither crashes nor changes the hook's stdout contract:

```bash
xcodebuild build -scheme Relay -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -quiet
dir=$(xcodebuild -scheme Relay -configuration Debug -showBuildSettings 2>/dev/null | awk -F' = ' '/^ *BUILT_PRODUCTS_DIR /{print $2; exit}')
echo '{"session_id":"s","cwd":"/tmp","hook_event_name":"Stop","last_assistant_message":"hi"}' | sh -c "\"$dir/RelayHook\" --provider claude-code"
```

Expected: prints `{}` and exits 0 (hook contract unchanged).

- [ ] **Step 7: Full suite, then commit**

Run the full suite. Expected: `** TEST SUCCEEDED **`.

```bash
git add Shared/ProcessAncestry.swift Relay/Integrations/Domain/HookEnvelope.swift Relay/Integrations/Domain/AgentResponseEvent.swift Relay/Integrations/StopHookIntegration.swift Relay/Sessions/AgentAutoReadCoordinator.swift RelayHook/main.swift RelayTests/Shared/ProcessAncestryTests.swift RelayTests/Integrations/HookEnvelopeTests.swift RelayTests/Integrations/StopHookIntegrationTests.swift RelayTests/Sessions/AgentAutoReadCoordinatorTests.swift Relay.xcodeproj/project.pbxproj
git commit -m "feat(hook): send hook-captured process ancestry so sessions survive wrapper shells"
```

(If plan 1 moved `HookEnvelope.swift`, stage it at its actual path.)

---

### Task 14: Final verification (no commit)

- [ ] **Step 1: Clean full suite**

```bash
xcodegen generate
xcodebuild clean test -scheme Relay -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 2: Confirm every removed symbol is gone**

```bash
grep -rnE "ClaudeCodeInstallerError|CodexInstallerError|ClaudeCodeIntegration|CodexIntegration|ClaudeCodeHookPayload|CodexHookPayload|isRelayOwnedCommand|ProcessTreeReading|AgentProcessContextCapturing|focusedSession\(among|LockedBox" Relay RelayHook Shared RelayTests
grep -rn "Application Support/Relay" Relay RelayHook | grep -v "///\|//"
```

Expected: no output from either command. The second command skips comments. App and helper code must build these paths through `RelayPaths`. Tests are allowed to spell out literal expected paths.

- [ ] **Step 3: Side-by-side manual check**

1. Install the Release build to `/Applications`. Run a Debug build from Xcode or DerivedData at the same time. Both menu bar items appear, and only Debug shows "DEV".
2. In each app, go to Settings → Integrations → Install for Claude Code and Codex. Then:

   ```bash
   grep -n "RelayHook" ~/.claude/settings.json ~/.codex/hooks.json
   ls ~/Library/Application\ Support/Relay/ ~/Library/Application\ Support/Relay\ Debug/
   ```

   Expected: two Relay entries per file, one pointing at `Relay/bin/RelayHook` and one at `Relay Debug/bin/RelayHook`. Each directory has its own `relay.sock`, `relay.lock` and `bin/RelayHook`. Only `Relay/` has `Models/`.
3. Finish a Claude Code turn. Both apps receive the event, because each hook entry reaches its own app. Open Diagnostics in either app: `stage=focus` entries show `resolver=… confidence=… reason=…`.
4. Uninstall in Debug only. Only the `Relay Debug` entries disappear.

- [ ] **Step 4: Hand off**

Use @superpowers:finishing-a-development-branch. The PR description must not contain any "Generated with Claude Code" line.
