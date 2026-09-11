# Relay Phase 2: Agent Integrations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add reliable, local ingestion of completed Claude Code and Codex responses through native lifecycle hooks, normalize them into one Relay event model, and make the latest response available for explicit speech without coupling the core to either agent.

**Architecture:** Claude Code and Codex command hooks forward their raw JSON to a tiny bundled `RelayHook` helper. The helper sends a newline-delimited `HookEnvelope` over a local Unix-domain socket to the running Relay app and always returns a harmless JSON object to the agent. Provider adapters decode the raw payload and emit a common `AgentResponseEvent`. Phase 2 intentionally does **not** auto-speak agent responses; Phase 3 adds focused-session routing. This preserves the approved conservative automation rule.

**Tech Stack:** Existing Phase 1 Swift 6.2 macOS app, Darwin Unix-domain sockets, Foundation Codable, SwiftUI/AppKit, XcodeGen, XCTest. No web server and no cloud service.

**Spec:** `docs/superpowers/specs/2026-09-11-relay-design.md`

## Global Constraints

- Phase 1 must be complete and green before starting this plan.
- The Relay core must not import or reference Claude/Codex payload types.
- Integrations are compiled-in adapters; no runtime third-party plugin loader.
- Agent hook execution must never block or steer the agent because Relay is down.
- `RelayHook` exits `0` whether or not Relay.app is running.
- `RelayHook` writes exactly `{}` plus a newline to stdout on success/failure so Codex `Stop` hook output remains valid JSON and Claude Code receives no control decision.
- Agent response text remains ephemeral and is never written to Relay history in v1.
- Unix socket path: `~/Library/Application Support/Relay/relay.sock`.
- Socket protocol: UTF-8 JSON, one `HookEnvelope` per line, maximum envelope size 2 MiB.
- Integration installers merge only Relay-owned hook entries and preserve all unrelated existing hooks.
- Claude Code user-level config: `~/.claude/settings.json` or `$CLAUDE_CONFIG_DIR/settings.json` when `CLAUDE_CONFIG_DIR` is set.
- Codex user-level hook config: `~/.codex/hooks.json` or `$CODEX_HOME/hooks.json` when `CODEX_HOME` is set.
- Codex non-managed hooks require explicit trust review in `/hooks`; Relay must surface this instead of bypassing trust.
- Do not use `--dangerously-bypass-hook-trust`.
- No screen scraping or transcript-file parsing is necessary for final assistant text because both current `Stop` hook payloads expose `last_assistant_message`.

---

## File Structure

```text
project.yml                         # modified to build/embed RelayHook
RelayHook/
  main.swift
  HookTransportClient.swift
Relay/
  Integrations/
    Domain/
      AgentProvider.swift
      AgentResponseEvent.swift
      HookEnvelope.swift
      RelayIntegration.swift
      IntegrationStatus.swift
    Transport/
      UnixSocketServer.swift
      HookEnvelopeReceiver.swift
    ClaudeCode/
      ClaudeCodeHookPayload.swift
      ClaudeCodeIntegration.swift
      ClaudeCodeInstaller.swift
    Codex/
      CodexHookPayload.swift
      CodexIntegration.swift
      CodexInstaller.swift
    IntegrationManager.swift
    LatestAgentResponseStore.swift
  App/
    AppModel.swift                  # modified
    MenuBarContentView.swift        # modified
    SettingsView.swift              # modified
RelayTests/
  Integrations/
    HookEnvelopeTests.swift
    UnixSocketServerTests.swift
    ClaudeCodeIntegrationTests.swift
    ClaudeCodeInstallerTests.swift
    CodexIntegrationTests.swift
    CodexInstallerTests.swift
    IntegrationManagerTests.swift
```

## Task 1: Define normalized agent-integration contracts

**Files:**
- Create: `Relay/Integrations/Domain/AgentProvider.swift`
- Create: `Relay/Integrations/Domain/AgentResponseEvent.swift`
- Create: `Relay/Integrations/Domain/HookEnvelope.swift`
- Create: `Relay/Integrations/Domain/RelayIntegration.swift`
- Create: `Relay/Integrations/Domain/IntegrationStatus.swift`
- Modify: `Relay/Domain/SpeechModels.swift`
- Test: `RelayTests/Integrations/HookEnvelopeTests.swift`

**Interfaces:**
- Produces: `AgentProvider`, `AgentResponseEvent`, `HookEnvelope`, `RelayIntegration`, `IntegrationStatus`.
- Consumes from Phase 1: `SpeechSource`.

- [ ] **Step 1: Write Codable round-trip tests**

```swift
import XCTest
@testable import Relay

final class HookEnvelopeTests: XCTestCase {
    func testEnvelopeRoundTripsWithoutLosingRawPayload() throws {
        let envelope = HookEnvelope(
            schemaVersion: 1,
            provider: .claudeCode,
            rawPayload: #"{"session_id":"abc","last_assistant_message":"done"}"#,
            parentPID: 123,
            environment: ["TERM_PROGRAM": "ghostty", "TMUX_PANE": "%3"],
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(envelope)
        XCTAssertEqual(try JSONDecoder().decode(HookEnvelope.self, from: data), envelope)
    }
}
```

- [ ] **Step 2: Implement the normalized types**

```swift
// Relay/Integrations/Domain/AgentProvider.swift
import Foundation

enum AgentProvider: String, Codable, Sendable, CaseIterable {
    case claudeCode = "claude-code"
    case codex = "codex"
}
```

```swift
// Relay/Integrations/Domain/AgentResponseEvent.swift
import Foundation

struct AgentResponseEvent: Equatable, Sendable {
    let id: UUID
    let provider: AgentProvider
    let providerSessionID: String
    let turnID: String?
    let text: String
    let cwd: String
    let transcriptPath: String?
    let parentPID: Int32
    let environment: [String: String]
    let capturedAt: Date
}
```

```swift
// Relay/Integrations/Domain/HookEnvelope.swift
import Foundation

struct HookEnvelope: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let provider: AgentProvider
    let rawPayload: String
    let parentPID: Int32
    let environment: [String: String]
    let capturedAt: Date
}
```

```swift
// Relay/Integrations/Domain/IntegrationStatus.swift
import Foundation

enum IntegrationStatus: Equatable, Sendable {
    case notInstalled
    case installedAwaitingFirstEvent
    case installedTrustRequired
    case active(lastEventAt: Date)
    case configurationError(String)
}
```

```swift
// Relay/Integrations/Domain/RelayIntegration.swift
protocol RelayIntegration: Sendable {
    var provider: AgentProvider { get }
    func decode(_ envelope: HookEnvelope) throws -> AgentResponseEvent
}
```

Extend Phase 1 `SpeechSource` exactly:

```swift
enum SpeechSource: String, Sendable, Codable {
    case selection
    case claudeCode
    case codex
    case manualReplay
    case futureIntegration
}
```

- [ ] **Step 3: Run tests and commit**

```bash
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -only-testing:RelayTests/HookEnvelopeTests test
git add Relay/Integrations Relay/Domain/SpeechModels.swift RelayTests/Integrations
git commit -m "feat: define Relay integration events"
```

## Task 2: Build the bundled `RelayHook` helper

**Files:**
- Modify: `project.yml`
- Create: `RelayHook/main.swift`
- Create: `RelayHook/HookTransportClient.swift`

**Interfaces:**
- Produces executable `RelayHook --provider claude-code|codex` reading hook JSON from stdin and forwarding one `HookEnvelope` to Relay.

- [ ] **Step 1: Add the helper target to `project.yml`**

Add this target:

```yaml
  RelayHook:
    type: tool
    platform: macOS
    sources:
      - path: RelayHook
    settings:
      base:
        PRODUCT_NAME: RelayHook
        SWIFT_VERSION: 6.0
        ARCHS: arm64
        ONLY_ACTIVE_ARCH: YES
        CODE_SIGN_IDENTITY: "-"
```

Add to the `Relay` target:

```yaml
    dependencies:
      - target: RelayHook
      - package: FluidAudio
        product: FluidAudio
      - package: ArgmaxOSS
        product: WhisperKit
    postbuildScripts:
      - name: Embed RelayHook
        script: |
          set -euo pipefail
          helper_dir="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers"
          mkdir -p "${helper_dir}"
          cp "${BUILT_PRODUCTS_DIR}/RelayHook" "${helper_dir}/RelayHook"
          chmod 755 "${helper_dir}/RelayHook"
```

Do not duplicate package dependency entries when editing the existing file.

- [ ] **Step 2: Implement the helper envelope**

The helper cannot import the app target, so duplicate the wire-only `HookEnvelope`/`AgentProvider` structs privately inside `RelayHook/main.swift`. Wire schema version remains `1`.

Capture only this environment allowlist:

```swift
let environmentKeys = [
    "TERM_PROGRAM", "TERM", "TMUX", "TMUX_PANE",
    "HERDR_SOCKET_PATH", "HERDR_ACTIVE_WORKSPACE_ID",
    "HERDR_ACTIVE_TAB_ID", "HERDR_ACTIVE_PANE_ID",
    "HERDR_PANE_ID", "GHOSTTY_RESOURCES_DIR"
]
```

Use `getppid()` for `parentPID`. Read stdin to EOF as UTF-8. Reject input larger than 1.5 MiB before envelope expansion.

- [ ] **Step 3: Implement local Unix-socket send semantics**

`HookTransportClient.send(line:)` uses `AF_UNIX`, `SOCK_STREAM`, connects to `~/Library/Application Support/Relay/relay.sock`, sends the encoded JSON plus `\n`, then closes. A connection failure is intentionally swallowed by `main.swift`.

The final helper behavior must be:

```swift
let exitJSON = "{}\n"
FileHandle.standardOutput.write(Data(exitJSON.utf8))
exit(EXIT_SUCCESS)
```

No diagnostics go to stdout. Debug diagnostics may go to stderr only when `RELAY_HOOK_DEBUG=1`.

- [ ] **Step 4: Build and inspect the app bundle**

```bash
xcodegen generate
xcodebuild -project Relay.xcodeproj -scheme Relay -configuration Debug -destination 'platform=macOS' build
find ~/Library/Developer/Xcode/DerivedData -path '*/Relay.app/Contents/Helpers/RelayHook' -type f -print -quit
```

Expected: an executable helper exists inside the built app bundle.

- [ ] **Step 5: Commit**

```bash
git add project.yml RelayHook
git commit -m "feat: add Relay agent hook helper"
```

## Task 3: Receive hook envelopes inside Relay.app

**Files:**
- Create: `Relay/Integrations/Transport/UnixSocketServer.swift`
- Create: `Relay/Integrations/Transport/HookEnvelopeReceiver.swift`
- Test: `RelayTests/Integrations/UnixSocketServerTests.swift`

**Interfaces:**
- Produces: `UnixSocketServer.start(path:onLine:)`, `stop()`, `HookEnvelopeReceiver.events`.

- [ ] **Step 1: Write a real loopback Unix-socket test using a temporary directory**

```swift
func testServerReceivesOneJSONLine() async throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).path
    let received = expectation(description: "received")
    let server = UnixSocketServer()
    try server.start(path: path) { line in
        XCTAssertTrue(line.contains("schemaVersion"))
        received.fulfill()
    }
    defer { server.stop() }

    try UnixSocketTestClient.send(#"{"schemaVersion":1}"# + "\n", to: path)
    await fulfillment(of: [received], timeout: 1)
}
```

- [ ] **Step 2: Implement server safety rules**

Use a dedicated serial queue and BSD sockets. On `start`:

```text
- create parent directory with mode 0700 when missing
- remove a stale socket file only if it is a Unix socket owned by the current uid
- bind AF_UNIX
- chmod socket path 0600
- listen backlog 8
- accept clients on the server queue
- buffer until newline
- reject a line larger than 2 MiB
- close each client after EOF/error
```

On stop, close the listening descriptor and unlink only Relay's socket path.

- [ ] **Step 3: Implement envelope decode and event stream**

`HookEnvelopeReceiver` validates `schemaVersion == 1`, decodes `HookEnvelope`, and exposes an `AsyncStream<HookEnvelope>`. Malformed lines are ignored and reported to the app status/log without crashing the listener.

- [ ] **Step 4: Run tests and commit**

```bash
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -only-testing:RelayTests/UnixSocketServerTests test
git add Relay/Integrations/Transport RelayTests/Integrations/UnixSocketServerTests.swift
git commit -m "feat: receive local agent hook events"
```

## Task 4: Implement Claude Code adapter and safe installer

**Files:**
- Create: `Relay/Integrations/ClaudeCode/ClaudeCodeHookPayload.swift`
- Create: `Relay/Integrations/ClaudeCode/ClaudeCodeIntegration.swift`
- Create: `Relay/Integrations/ClaudeCode/ClaudeCodeInstaller.swift`
- Test: `RelayTests/Integrations/ClaudeCodeIntegrationTests.swift`
- Test: `RelayTests/Integrations/ClaudeCodeInstallerTests.swift`

**Interfaces:**
- Produces provider `.claudeCode`, normalized `AgentResponseEvent`, install/uninstall operations that preserve other Claude hooks.

- [ ] **Step 1: Test current Claude `Stop` payload decoding**

Use this fixture:

```json
{
  "session_id": "abc123",
  "transcript_path": "/Users/me/.claude/projects/p/abc123.jsonl",
  "cwd": "/Users/me/project",
  "hook_event_name": "Stop",
  "stop_hook_active": false,
  "last_assistant_message": "I've completed the refactoring."
}
```

Assert provider session ID, cwd, transcript path, and final text are preserved; an empty/missing `last_assistant_message` is rejected as an invalid integration event.

- [ ] **Step 2: Implement payload and adapter**

```swift
struct ClaudeCodeHookPayload: Decodable {
    let sessionID: String
    let transcriptPath: String?
    let cwd: String
    let hookEventName: String
    let stopHookActive: Bool
    let lastAssistantMessage: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case stopHookActive = "stop_hook_active"
        case lastAssistantMessage = "last_assistant_message"
    }
}
```

Adapter requires `hookEventName == "Stop"` and nonblank final message.

- [ ] **Step 3: Test installer merge behavior**

Fixtures must cover:

```text
- no settings file -> create one with Relay hook
- existing unrelated Stop hook -> append Relay matcher group without deleting it
- Relay hook already present -> no duplicate
- uninstall -> remove only the Relay command hook
- CLAUDE_CONFIG_DIR set -> use that directory instead of ~/.claude
```

- [ ] **Step 4: Implement exact command entry**

Resolve current helper path from:

```swift
Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/RelayHook")
```

The Relay-owned Claude command is:

```text
"<absolute-helper-path>" --provider claude-code
```

Identify Relay-owned entries by the exact suffix `--provider claude-code` and helper executable basename `RelayHook`; never replace the entire `hooks.Stop` array.

- [ ] **Step 5: Run tests and commit**

```bash
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -only-testing:RelayTests/ClaudeCodeIntegrationTests -only-testing:RelayTests/ClaudeCodeInstallerTests test
git add Relay/Integrations/ClaudeCode RelayTests/Integrations/ClaudeCode*
git commit -m "feat: integrate Claude Code completion hooks"
```

## Task 5: Implement Codex adapter and safe installer

**Files:**
- Create: `Relay/Integrations/Codex/CodexHookPayload.swift`
- Create: `Relay/Integrations/Codex/CodexIntegration.swift`
- Create: `Relay/Integrations/Codex/CodexInstaller.swift`
- Test: `RelayTests/Integrations/CodexIntegrationTests.swift`
- Test: `RelayTests/Integrations/CodexInstallerTests.swift`

**Interfaces:**
- Produces provider `.codex`, normalized event with Codex `turn_id`, install/uninstall operations that preserve other hooks.

- [ ] **Step 1: Test current Codex `Stop` payload decoding**

Fixture:

```json
{
  "session_id": "thr_123",
  "transcript_path": "/Users/me/.codex/sessions/rollout.jsonl",
  "cwd": "/Users/me/project",
  "hook_event_name": "Stop",
  "turn_id": "turn_456",
  "stop_hook_active": false,
  "last_assistant_message": "The tests now pass."
}
```

- [ ] **Step 2: Implement payload and adapter**

```swift
struct CodexHookPayload: Decodable {
    let sessionID: String
    let transcriptPath: String?
    let cwd: String
    let hookEventName: String
    let turnID: String
    let stopHookActive: Bool
    let lastAssistantMessage: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case turnID = "turn_id"
        case stopHookActive = "stop_hook_active"
        case lastAssistantMessage = "last_assistant_message"
    }
}
```

- [ ] **Step 3: Test hooks.json merge behavior**

Cover new file, unrelated hooks preserved, idempotent install, Relay-only uninstall, and `$CODEX_HOME` override.

The Relay entry is exactly:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "<absolute-helper-path> --provider codex",
            "timeout": 3
          }
        ]
      }
    ]
  }
}
```

The installer must merge this group into an existing `hooks.json`, not overwrite it.

- [ ] **Step 4: Respect Codex trust semantics**

After install, return `.installedTrustRequired` until Relay receives the first valid Codex event. Settings copy must say: `Installed. Open /hooks in Codex and trust the Relay hook.` Do not edit trust state or use trust-bypass flags.

If `~/.codex/config.toml` explicitly contains `[features] hooks = false`, do not modify it; show `Codex hooks are disabled in config.toml.`

- [ ] **Step 5: Run tests and commit**

```bash
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -only-testing:RelayTests/CodexIntegrationTests -only-testing:RelayTests/CodexInstallerTests test
git add Relay/Integrations/Codex RelayTests/Integrations/Codex*
git commit -m "feat: integrate Codex completion hooks"
```

## Task 6: Build the integration manager and ephemeral latest-response store

**Files:**
- Create: `Relay/Integrations/LatestAgentResponseStore.swift`
- Create: `Relay/Integrations/IntegrationManager.swift`
- Test: `RelayTests/Integrations/IntegrationManagerTests.swift`

**Interfaces:**
- Consumes: `HookEnvelopeReceiver`, both `RelayIntegration` adapters, Phase 1 speech preprocessor/coordinator.
- Produces: per-provider status, `latestResponse`, `speakLatest()`.

- [ ] **Step 1: Test provider dispatch and ephemeral storage**

Tests must verify:

```text
Claude envelope -> only Claude adapter decodes -> latest event becomes Claude event
Codex envelope -> only Codex adapter decodes -> latest event becomes Codex event
malformed event -> latest unchanged
second event from same/different provider -> latest replaced in memory only
speakLatest -> agent text gets automatic-style Markdown/code preprocessing, then a user-requested SpeechRequest
```

- [ ] **Step 2: Implement `LatestAgentResponseStore` as an actor**

```swift
actor LatestAgentResponseStore {
    private var latest: AgentResponseEvent?
    func set(_ event: AgentResponseEvent) { latest = event }
    func get() -> AgentResponseEvent? { latest }
    func clear() { latest = nil }
}
```

No `UserDefaults`, file, database, or transcript-path read is allowed.

- [ ] **Step 3: Implement manager event loop**

`IntegrationManager.start()` consumes `HookEnvelopeReceiver.events`, selects adapter by `envelope.provider`, decodes, stores event, and updates provider status on the main actor. It must **not** auto-submit speech in Phase 2.

`speakLatest()` computes `RulesSpeechPreprocessor().prepare(text: event.text, mode: .automatic)` and submits that string to `SpeechCoordinator` with `mode: .userRequested`, `sessionID: "\(event.provider.rawValue):\(event.providerSessionID)"`, and `.claudeCode` or `.codex` as the provider-specific `SpeechSource`.

- [ ] **Step 4: Run tests and commit**

```bash
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -only-testing:RelayTests/IntegrationManagerTests test
git add Relay/Integrations RelayTests/Integrations/IntegrationManagerTests.swift
git commit -m "feat: manage agent response integrations"
```

## Task 7: Expose integration installation and manual speech in the UI

**Files:**
- Modify: `Relay/App/AppModel.swift`
- Modify: `Relay/App/MenuBarContentView.swift`
- Modify: `Relay/App/SettingsView.swift`

**Interfaces:**
- Produces user-facing install/uninstall/status actions and `Speak Latest Agent Response`.

- [ ] **Step 1: Start/stop socket lifecycle with the app model**

At app initialization, start `HookEnvelopeReceiver` at the fixed Relay socket path, then start `IntegrationManager`. Stop/unlink the socket on app termination.

- [ ] **Step 2: Add menu-bar controls**

Menu-bar content must show:

```text
Speak Latest Agent Response     enabled only when latest exists
---
Claude Code: Active / Installed / Not Installed
Codex: Active / Trust Required / Not Installed
```

Do not auto-speak on receipt yet.

- [ ] **Step 3: Add settings integration rows**

Each integration gets Install/Uninstall and status. For Codex trust-required state, include the exact instruction `Run /hooks in Codex and trust the Relay hook.`

- [ ] **Step 4: Run full tests and manual acceptance**

```bash
xcodegen generate
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' test
```

Manual matrix:

```text
[ ] Existing Claude hooks survive Relay install.
[ ] Claude Stop event reaches Relay and latest response updates.
[ ] RelayHook does not delay/break Claude when Relay.app is quit.
[ ] Existing Codex hooks survive Relay install.
[ ] Codex shows the new hook in /hooks and requires trust.
[ ] After trust, Codex Stop event reaches Relay and latest response updates.
[ ] RelayHook does not delay/break Codex when Relay.app is quit.
[ ] Speak Latest reads Claude response with code-block cleanup.
[ ] Speak Latest reads Codex response with code-block cleanup.
[ ] Relaunch clears latest response content.
[ ] Uninstall removes only Relay-owned hook entries.
```

- [ ] **Step 5: Commit Phase 2 completion**

```bash
git add Relay RelayTests project.yml RelayHook
git commit -m "feat: complete Relay agent integrations"
```

## Phase 2 Exit Criteria

Phase 2 is complete when Claude Code and Codex can independently send final assistant messages to Relay through supported `Stop` hooks, existing hook configuration is preserved, Codex trust is respected, the app stores only an in-memory latest response, and the user can explicitly speak that latest response through the Phase 1 TTS pipeline.

**Important:** automatic agent speech is intentionally still disabled. Phase 3 is responsible for session identity, focus confidence, multiple simultaneous agents, and auto-read eligibility.

## Verified implementation references (2026-09-11)

- Claude Code hooks reference: `https://code.claude.com/docs/en/hooks`
  - `Stop` fires when the main agent finishes responding.
  - `Stop` input exposes `session_id`, `cwd`, `transcript_path`, `stop_hook_active`, and `last_assistant_message`.
- Codex hooks reference: `https://learn.chatgpt.com/docs/hooks`
  - User hook locations include `~/.codex/hooks.json` and `~/.codex/config.toml`.
  - Non-managed hooks require review/trust.
  - `Stop` exposes `turn_id`, `stop_hook_active`, and `last_assistant_message` in addition to common fields.
  - `Stop` command hooks expect JSON stdout on exit 0; `{}` is used by RelayHook.
