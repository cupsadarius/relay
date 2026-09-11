# Relay Phase 3: Session Intelligence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Relay automatically speak Claude Code and Codex responses only when the producing agent session is confidently focused, including concurrent sessions running directly in a terminal, inside tmux, or inside Herdr.

**Architecture:** Phase 3 adds an ephemeral `AgentSessionRegistry`, a process/context capture layer, pluggable `FocusResolver` implementations, and an `AgentAutoReadCoordinator`. Each completed agent response is normalized by Phase 2, captured into session state, evaluated against the **current** macOS focus at completion time, and spoken only when focus resolves to `focused(high)`. Herdr and tmux provide exact pane evidence when available; direct terminals use conservative process ancestry. Unknown or ambiguous focus always stays silent.

**Tech Stack:** Existing Phase 1/2 Swift 6.2 macOS app, AppKit `NSWorkspace`, Foundation `Process`, Darwin process/socket APIs, local Unix-domain sockets, tmux CLI, Herdr newline-delimited JSON socket API, XcodeGen, XCTest. No screen scraping, OCR, terminal-buffer parsing, cloud service, or Herdr/tmux hard dependency.

**Spec:** `docs/superpowers/specs/2026-09-11-relay-design.md`

## Global Constraints

- Phase 1 and Phase 2 must be complete and green before starting this plan.
- Current focus **at response-completion time** determines auto-read eligibility.
- Relay auto-speaks only a `focused` result with `high` confidence.
- `notFocused(high)` and `unknown` are always silent.
- A background response remains available in ephemeral session state for manual `Speak Latest Agent Response` / replay.
- Claude/Codex adapters must not contain Ghostty, tmux, Herdr, or terminal-focus logic.
- The speech core must not import session resolver implementations.
- Herdr is an optional resolver. Relay must work without Herdr installed or running.
- tmux is an optional resolver. Relay must work without tmux installed or running.
- Plain-terminal support must not be hardcoded to Ghostty. Ghostty is a test host, not a dependency.
- Direct-terminal focus may use process ancestry only when unambiguous. Multiple live direct sessions sharing one terminal app process must resolve `unknown` unless stronger evidence exists.
- Do not inspect terminal screen contents, scrape Accessibility text, or parse scrollback to infer which agent is focused.
- Herdr focus is queried through its documented local socket API. Do not modify Herdr configuration or require a Relay-specific Herdr plugin.
- tmux focus is queried through the existing tmux server/socket and client metadata. Do not modify `.tmux.conf`.
- Focus/session state, process snapshots, and agent response contents remain memory-only.
- `autoReadEnabled == false` bypasses all focus resolution and never submits automatic speech.
- Starting dictation still immediately stops speech, preserving Phase 1 priority rules.
- Explicit selected-text speech still has priority over automatic agent speech.
- A focus resolver failure is non-fatal; the result becomes `unknown` and Relay stays silent.

---

## File Structure

```text
Relay/
  Sessions/
    Domain/
      AgentSession.swift
      TerminalContext.swift
      FocusModels.swift
    AgentSessionRegistry.swift
    ProcessInspector.swift
    FrontmostAppMonitor.swift
    FocusResolutionService.swift
    RecentInteractionTracker.swift
    AgentAutoReadCoordinator.swift
    Resolvers/
      GenericTerminalFocusResolver.swift
      TmuxFocusResolver.swift
      HerdrFocusResolver.swift
    Tmux/
      TmuxClient.swift
      TmuxExecutableLocator.swift
    Herdr/
      HerdrSocketClient.swift
      HerdrModels.swift
  Integrations/
    IntegrationManager.swift              # modified to publish decoded events
    LatestAgentResponseStore.swift        # retained for compatibility/manual latest
  SpeechIn/
    DictationCoordinator.swift            # modified to record recent voice interaction
  App/
    AppModel.swift                        # modified
    MenuBarContentView.swift              # modified
    SettingsView.swift                    # modified
RelayTests/
  Sessions/
    AgentSessionRegistryTests.swift
    ProcessInspectorTests.swift
    FocusResolutionServiceTests.swift
    GenericTerminalFocusResolverTests.swift
    TmuxFocusResolverTests.swift
    HerdrFocusResolverTests.swift
    RecentInteractionTrackerTests.swift
    AgentAutoReadCoordinatorTests.swift
```

---

## Task 1: Define session identity, terminal context, and ephemeral registry

**Files:**
- Create: `Relay/Sessions/Domain/AgentSession.swift`
- Create: `Relay/Sessions/Domain/TerminalContext.swift`
- Create: `Relay/Sessions/AgentSessionRegistry.swift`
- Test: `RelayTests/Sessions/AgentSessionRegistryTests.swift`

**Interfaces:**
- Consumes from Phase 2: `AgentProvider`, `AgentResponseEvent`.
- Produces: `AgentSessionID`, `AgentSession`, `TerminalContext`, `AgentSessionRegistry.upsert(response:processAncestry:tty:)`, `session(id:)`, `sessions()`.
- No persistence is allowed.

- [ ] **Step 1: Write failing identity/context tests**

```swift
import XCTest
@testable import Relay

final class AgentSessionRegistryTests: XCTestCase {
    func testTerminalContextExtractsMultiplexerMetadata() {
        let event = AgentResponseEvent(
            id: UUID(),
            provider: .claudeCode,
            providerSessionID: "claude-a",
            turnID: nil,
            text: "done",
            cwd: "/tmp/repo",
            transcriptPath: nil,
            parentPID: 101,
            environment: [
                "TERM_PROGRAM": "ghostty",
                "TMUX": "/private/tmp/tmux-501/default,123,0",
                "TMUX_PANE": "%7",
                "HERDR_SOCKET_PATH": "/tmp/herdr.sock",
                "HERDR_PANE_ID": "w1:p2"
            ],
            capturedAt: Date(timeIntervalSince1970: 100)
        )

        let context = TerminalContext(event: event)
        XCTAssertEqual(context.termProgram, "ghostty")
        XCTAssertEqual(context.tmuxSocketPath, "/private/tmp/tmux-501/default")
        XCTAssertEqual(context.tmuxPaneID, "%7")
        XCTAssertEqual(context.herdrSocketPath, "/tmp/herdr.sock")
        XCTAssertEqual(context.herdrPaneID, "w1:p2")
    }

    func testUpsertKeepsSeparateConcurrentProviderSessions() async {
        let registry = AgentSessionRegistry()
        let a = makeEvent(provider: .claudeCode, session: "a", at: 10)
        let b = makeEvent(provider: .codex, session: "b", at: 11)

        await registry.upsert(response: a, processAncestry: [101, 20, 1], tty: "/dev/ttys001")
        await registry.upsert(response: b, processAncestry: [202, 20, 1], tty: "/dev/ttys002")

        let sessions = await registry.sessions()
        XCTAssertEqual(Set(sessions.map(\.id)), [
            AgentSessionID(provider: .claudeCode, providerSessionID: "a"),
            AgentSessionID(provider: .codex, providerSessionID: "b")
        ])
    }

    private func makeEvent(provider: AgentProvider, session: String, at: TimeInterval) -> AgentResponseEvent {
        AgentResponseEvent(
            id: UUID(), provider: provider, providerSessionID: session, turnID: nil,
            text: "response", cwd: "/tmp/repo", transcriptPath: nil,
            parentPID: 42, environment: [:], capturedAt: Date(timeIntervalSince1970: at)
        )
    }
}
```

Run:

```bash
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -only-testing:RelayTests/AgentSessionRegistryTests test
```

Expected: FAIL because the session types do not exist.

- [ ] **Step 2: Implement stable session and terminal-context types**

```swift
// Relay/Sessions/Domain/AgentSession.swift
import Foundation

struct AgentSessionID: Hashable, Codable, Sendable {
    let provider: AgentProvider
    let providerSessionID: String
}

struct AgentSession: Equatable, Sendable {
    let id: AgentSessionID
    var cwd: String
    var terminalContext: TerminalContext
    var processAncestry: [Int32]
    var tty: String?
    var latestResponse: AgentResponseEvent
    var lastActivityAt: Date
}
```

```swift
// Relay/Sessions/Domain/TerminalContext.swift
import Foundation

struct TerminalContext: Equatable, Sendable {
    let termProgram: String?
    let tmuxSocketPath: String?
    let tmuxPaneID: String?
    let herdrSocketPath: String?
    let herdrPaneID: String?

    init(event: AgentResponseEvent) {
        termProgram = event.environment["TERM_PROGRAM"]
        tmuxSocketPath = event.environment["TMUX"]?.split(separator: ",", maxSplits: 1).first.map(String.init)
        tmuxPaneID = event.environment["TMUX_PANE"]
        herdrSocketPath = event.environment["HERDR_SOCKET_PATH"]
        herdrPaneID = event.environment["HERDR_PANE_ID"] ?? event.environment["HERDR_ACTIVE_PANE_ID"]
    }
}
```

- [ ] **Step 3: Implement the memory-only session registry**

```swift
// Relay/Sessions/AgentSessionRegistry.swift
import Foundation

actor AgentSessionRegistry {
    private var values: [AgentSessionID: AgentSession] = [:]

    @discardableResult
    func upsert(
        response: AgentResponseEvent,
        processAncestry: [Int32],
        tty: String?
    ) -> AgentSession {
        let id = AgentSessionID(provider: response.provider, providerSessionID: response.providerSessionID)
        let value = AgentSession(
            id: id,
            cwd: response.cwd,
            terminalContext: TerminalContext(event: response),
            processAncestry: processAncestry,
            tty: tty,
            latestResponse: response,
            lastActivityAt: response.capturedAt
        )
        values[id] = value
        return value
    }

    func session(id: AgentSessionID) -> AgentSession? { values[id] }

    func sessions() -> [AgentSession] {
        values.values.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    func removeAll() { values.removeAll() }
}
```

Do not add `Codable` to `AgentSession`; the registry is intentionally ephemeral.

- [ ] **Step 4: Run tests and commit**

```bash
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -only-testing:RelayTests/AgentSessionRegistryTests test
git add Relay/Sessions RelayTests/Sessions/AgentSessionRegistryTests.swift
git commit -m "feat: track ephemeral agent sessions"
```

Expected: PASS.

---

## Task 2: Capture frontmost-app and process ancestry without terminal-specific assumptions

**Files:**
- Create: `Relay/Sessions/ProcessInspector.swift`
- Create: `Relay/Sessions/FrontmostAppMonitor.swift`
- Test: `RelayTests/Sessions/ProcessInspectorTests.swift`

**Interfaces:**
- Produces: `ProcessRecord`, `ProcessSnapshot`, `ProcessInspector.snapshot()`, `ancestry(from:in:)`, `descendants(of:in:)`, `FrontmostApplication`, `FrontmostAppMonitoring`.
- Later resolvers use these interfaces; no resolver directly shells out to `ps`.

- [ ] **Step 1: Write parser/ancestry tests against deterministic `ps` output**

```swift
import XCTest
@testable import Relay

final class ProcessInspectorTests: XCTestCase {
    func testParsesSnapshotAndWalksAncestry() throws {
        let fixture = """
          1     0 ??       launchd
         20     1 ??       Ghostty
        101    20 ttys001  zsh
        202   101 ttys001  claude
        303   202 ttys001  RelayHook
        """
        let snapshot = try ProcessSnapshot.parse(fixture)
        XCTAssertEqual(snapshot.ancestry(from: 303).map(\.pid), [303, 202, 101, 20, 1])
        XCTAssertEqual(snapshot.record(pid: 303)?.tty, "ttys001")
    }

    func testDescendantsAreComputedFromParentEdges() throws {
        let snapshot = try ProcessSnapshot.parse("""
          20 1 ?? Ghostty
         100 20 ttys001 zsh
         101 20 ttys002 zsh
         200 100 ttys001 herdr
        """)
        XCTAssertEqual(Set(snapshot.descendants(of: 20).map(\.pid)), [100, 101, 200])
    }
}
```

- [ ] **Step 2: Implement process snapshot parsing and traversal**

```swift
// Relay/Sessions/ProcessInspector.swift
import Foundation

struct ProcessRecord: Equatable, Sendable {
    let pid: Int32
    let parentPID: Int32
    let tty: String?
    let command: String
}

struct ProcessSnapshot: Sendable {
    private let records: [Int32: ProcessRecord]

    static func parse(_ output: String) throws -> ProcessSnapshot {
        var records: [Int32: ProcessRecord] = [:]
        for raw in output.split(whereSeparator: \.isNewline) {
            let fields = raw.split(maxSplits: 3, whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count == 4,
                  let pid = Int32(fields[0]),
                  let ppid = Int32(fields[1]) else { continue }
            let tty = fields[2] == "??" || fields[2] == "?" ? nil : fields[2]
            records[pid] = ProcessRecord(pid: pid, parentPID: ppid, tty: tty, command: fields[3])
        }
        return ProcessSnapshot(records: records)
    }

    func record(pid: Int32) -> ProcessRecord? { records[pid] }

    func ancestry(from pid: Int32) -> [ProcessRecord] {
        var result: [ProcessRecord] = []
        var current = pid
        var visited = Set<Int32>()
        while current > 0, visited.insert(current).inserted, let record = records[current] {
            result.append(record)
            current = record.parentPID
        }
        return result
    }

    func descendants(of rootPID: Int32) -> [ProcessRecord] {
        records.values.filter { candidate in
            ancestry(from: candidate.pid).dropFirst().contains { $0.pid == rootPID }
        }
    }
}

struct ProcessInspector: Sendable {
    func snapshot() throws -> ProcessSnapshot {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,tty=,comm="]
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ProcessInspectionError.psFailed }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return try ProcessSnapshot.parse(String(decoding: data, as: UTF8.self))
    }
}

enum ProcessInspectionError: Error { case psFailed }
```

- [ ] **Step 3: Implement frontmost-app monitoring as an injectable protocol**

```swift
// Relay/Sessions/FrontmostAppMonitor.swift
import AppKit

struct FrontmostApplication: Equatable, Sendable {
    let pid: Int32
    let bundleIdentifier: String?
    let localizedName: String?
}

protocol FrontmostAppMonitoring: Sendable {
    func current() async -> FrontmostApplication?
}

struct FrontmostAppMonitor: FrontmostAppMonitoring {
    @MainActor
    func current() async -> FrontmostApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return FrontmostApplication(
            pid: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier,
            localizedName: app.localizedName
        )
    }
}
```

No terminal bundle identifier is hardcoded here.

- [ ] **Step 4: Run tests and commit**

```bash
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -only-testing:RelayTests/ProcessInspectorTests test
git add Relay/Sessions/ProcessInspector.swift Relay/Sessions/FrontmostAppMonitor.swift RelayTests/Sessions/ProcessInspectorTests.swift
git commit -m "feat: inspect frontmost app and process ancestry"
```

Expected: PASS.

---

## Task 3: Define focus evidence and the conservative resolution service

**Files:**
- Create: `Relay/Sessions/Domain/FocusModels.swift`
- Create: `Relay/Sessions/FocusResolutionService.swift`
- Test: `RelayTests/Sessions/FocusResolutionServiceTests.swift`

**Interfaces:**
- Produces: `FocusState`, `FocusConfidence`, `FocusDecision`, `FocusContext`, `FocusResolver`, `FocusResolutionService.resolve(session:)`.
- Consumes: `AgentSessionRegistry`, `FrontmostAppMonitoring`.

- [ ] **Step 1: Write precedence and silence-policy tests**

```swift
import XCTest
@testable import Relay

final class FocusResolutionServiceTests: XCTestCase {
    func testHighFocusedStopsResolution() async {
        let resolver = StubFocusResolver(
            id: "exact",
            decision: .focused(resolverID: "exact", reason: "exact pane")
        )
        let service = FocusResolutionService(
            registry: AgentSessionRegistry(),
            frontmostApps: StubFrontmostApp(pid: 20),
            resolvers: [resolver]
        )
        let decision = await service.resolve(session: makeSession())
        XCTAssertEqual(decision.state, .focused)
        XCTAssertEqual(decision.confidence, .high)
    }

    func testUnknownNeverBecomesFocusedByDefault() async {
        let service = FocusResolutionService(
            registry: AgentSessionRegistry(),
            frontmostApps: StubFrontmostApp(pid: 20),
            resolvers: [StubFocusResolver(id: "x", decision: .unknown(resolverID: "x", reason: "ambiguous"))]
        )
        XCTAssertEqual((await service.resolve(session: makeSession())).state, .unknown)
    }
}

private struct StubFrontmostApp: FrontmostAppMonitoring {
    let pid: Int32
    func current() async -> FrontmostApplication? {
        .init(pid: pid, bundleIdentifier: nil, localizedName: "Test Terminal")
    }
}

private struct StubFocusResolver: FocusResolver {
    let id: String
    let decision: FocusDecision
    func supports(_ session: AgentSession) -> Bool { true }
    func resolve(session: AgentSession, context: FocusContext) async -> FocusDecision { decision }
}

private func makeSession() -> AgentSession {
    let event = AgentResponseEvent(
        id: UUID(), provider: .claudeCode, providerSessionID: "a", turnID: nil,
        text: "done", cwd: "/tmp/repo", transcriptPath: nil,
        parentPID: 900, environment: [:], capturedAt: Date()
    )
    return AgentSession(
        id: .init(provider: .claudeCode, providerSessionID: "a"),
        cwd: event.cwd,
        terminalContext: TerminalContext(event: event),
        processAncestry: [900, 20, 1],
        tty: "/dev/ttys001",
        latestResponse: event,
        lastActivityAt: event.capturedAt
    )
}
```

- [ ] **Step 2: Implement focus domain types**

```swift
// Relay/Sessions/Domain/FocusModels.swift
import Foundation

enum FocusState: String, Sendable, Equatable {
    case focused
    case notFocused
    case unknown
}

enum FocusConfidence: Int, Sendable, Comparable {
    case low = 0
    case medium = 1
    case high = 2
    static func < (lhs: FocusConfidence, rhs: FocusConfidence) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct FocusDecision: Sendable, Equatable {
    let state: FocusState
    let confidence: FocusConfidence
    let resolverID: String
    let reason: String

    static func focused(resolverID: String, reason: String) -> Self {
        .init(state: .focused, confidence: .high, resolverID: resolverID, reason: reason)
    }

    static func notFocused(resolverID: String, reason: String) -> Self {
        .init(state: .notFocused, confidence: .high, resolverID: resolverID, reason: reason)
    }

    static func unknown(resolverID: String, reason: String) -> Self {
        .init(state: .unknown, confidence: .low, resolverID: resolverID, reason: reason)
    }
}

struct FocusContext: Sendable {
    let frontmostApplication: FrontmostApplication?
    let sessions: [AgentSession]
    let now: Date
}

protocol FocusResolver: Sendable {
    var id: String { get }
    func supports(_ session: AgentSession) -> Bool
    func resolve(session: AgentSession, context: FocusContext) async -> FocusDecision
}

protocol SessionFocusResolving: Sendable {
    func resolve(session: AgentSession) async -> FocusDecision
}
```

- [ ] **Step 3: Implement ordered resolution**

```swift
// Relay/Sessions/FocusResolutionService.swift
import Foundation

actor FocusResolutionService {
    private let registry: AgentSessionRegistry
    private let frontmostApps: FrontmostAppMonitoring
    private let resolvers: [any FocusResolver]
    private let now: @Sendable () -> Date

    init(
        registry: AgentSessionRegistry,
        frontmostApps: FrontmostAppMonitoring,
        resolvers: [any FocusResolver],
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.registry = registry
        self.frontmostApps = frontmostApps
        self.resolvers = resolvers
        self.now = now
    }

    func resolve(session: AgentSession) async -> FocusDecision {
        let context = FocusContext(
            frontmostApplication: await frontmostApps.current(),
            sessions: await registry.sessions(),
            now: now()
        )
        for resolver in resolvers where resolver.supports(session) {
            let decision = await resolver.resolve(session: session, context: context)
            if decision.confidence == .high && decision.state != .unknown { return decision }
        }
        return .unknown(resolverID: "focus-resolution", reason: "no resolver produced high-confidence focus evidence")
    }
}

extension FocusResolutionService: SessionFocusResolving {}
```

Resolver order at app wiring time is **Herdr → tmux → generic terminal**. Exact environment-specific evidence wins before weaker generic evidence.

- [ ] **Step 4: Run tests and commit**

```bash
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -only-testing:RelayTests/FocusResolutionServiceTests test
git add Relay/Sessions/Domain/FocusModels.swift Relay/Sessions/FocusResolutionService.swift RelayTests/Sessions/FocusResolutionServiceTests.swift
git commit -m "feat: add conservative focus resolution"
```

Expected: PASS.

---

## Task 4: Implement the generic direct-terminal resolver

**Files:**
- Create: `Relay/Sessions/Resolvers/GenericTerminalFocusResolver.swift`
- Test: `RelayTests/Sessions/GenericTerminalFocusResolverTests.swift`

**Interfaces:**
- Consumes: `AgentSession.processAncestry`, `FocusContext.frontmostApplication`, all registered sessions.
- Produces high-confidence focus only when a direct session is unambiguous.

- [ ] **Step 1: Write direct-terminal ambiguity tests**

```swift
import XCTest
@testable import Relay

final class GenericTerminalFocusResolverTests: XCTestCase {
    func testSingleDirectSessionWhoseAncestryContainsFrontmostAppIsFocused() async {
        let session = makeDirectSession(id: "a", ancestry: [900, 100, 20, 1])
        let context = FocusContext(
            frontmostApplication: .init(pid: 20, bundleIdentifier: "com.example.Terminal", localizedName: "Terminal Host"),
            sessions: [session],
            now: Date()
        )
        let decision = await GenericTerminalFocusResolver().resolve(session: session, context: context)
        XCTAssertEqual(decision.state, .focused)
        XCTAssertEqual(decision.confidence, .high)
    }

    func testTwoDirectSessionsUnderSameFrontmostAppAreUnknown() async {
        let a = makeDirectSession(id: "a", ancestry: [900, 100, 20, 1])
        let b = makeDirectSession(id: "b", ancestry: [901, 101, 20, 1])
        let context = FocusContext(
            frontmostApplication: .init(pid: 20, bundleIdentifier: nil, localizedName: "Any Terminal"),
            sessions: [a, b],
            now: Date()
        )
        XCTAssertEqual((await GenericTerminalFocusResolver().resolve(session: a, context: context)).state, .unknown)
    }

    func testDifferentFrontmostAppIsNotFocused() async {
        let session = makeDirectSession(id: "a", ancestry: [900, 100, 20, 1])
        let context = FocusContext(
            frontmostApplication: .init(pid: 88, bundleIdentifier: "com.apple.Safari", localizedName: "Safari"),
            sessions: [session],
            now: Date()
        )
        XCTAssertEqual((await GenericTerminalFocusResolver().resolve(session: session, context: context)).state, .notFocused)
    }
}

private func makeDirectSession(id: String, ancestry: [Int32]) -> AgentSession {
    let event = AgentResponseEvent(
        id: UUID(), provider: .claudeCode, providerSessionID: id, turnID: nil,
        text: "done", cwd: "/tmp/\(id)", transcriptPath: nil,
        parentPID: ancestry.first ?? 0, environment: [:], capturedAt: Date()
    )
    return AgentSession(
        id: .init(provider: .claudeCode, providerSessionID: id),
        cwd: event.cwd,
        terminalContext: TerminalContext(event: event),
        processAncestry: ancestry,
        tty: nil,
        latestResponse: event,
        lastActivityAt: event.capturedAt
    )
}
```

- [ ] **Step 2: Implement the generic resolver**

```swift
// Relay/Sessions/Resolvers/GenericTerminalFocusResolver.swift
import Foundation

struct GenericTerminalFocusResolver: FocusResolver {
    let id = "generic-terminal"

    func supports(_ session: AgentSession) -> Bool {
        session.terminalContext.tmuxPaneID == nil && session.terminalContext.herdrPaneID == nil
    }

    func resolve(session: AgentSession, context: FocusContext) async -> FocusDecision {
        guard let frontmostPID = context.frontmostApplication?.pid else {
            return .unknown(resolverID: id, reason: "no frontmost application")
        }
        guard session.processAncestry.contains(frontmostPID) else {
            return .notFocused(resolverID: id, reason: "frontmost application is outside producing process ancestry")
        }

        let directCandidates = context.sessions.filter {
            $0.terminalContext.tmuxPaneID == nil &&
            $0.terminalContext.herdrPaneID == nil &&
            $0.processAncestry.contains(frontmostPID)
        }
        guard directCandidates.count == 1, directCandidates[0].id == session.id else {
            return .unknown(resolverID: id, reason: "multiple direct agent sessions share the frontmost terminal process")
        }
        return .focused(resolverID: id, reason: "single direct session belongs to frontmost process ancestry")
    }
}
```

This deliberately does **not** special-case Ghostty, Terminal.app, iTerm2, WezTerm, Kitty, or any other terminal emulator.

- [ ] **Step 3: Run tests and commit**

```bash
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -only-testing:RelayTests/GenericTerminalFocusResolverTests test
git add Relay/Sessions/Resolvers/GenericTerminalFocusResolver.swift RelayTests/Sessions/GenericTerminalFocusResolverTests.swift
git commit -m "feat: resolve unambiguous direct terminal focus"
```

Expected: PASS.

---

## Task 5: Implement exact tmux client/pane focus resolution

**Files:**
- Create: `Relay/Sessions/Tmux/TmuxExecutableLocator.swift`
- Create: `Relay/Sessions/Tmux/TmuxClient.swift`
- Create: `Relay/Sessions/Resolvers/TmuxFocusResolver.swift`
- Test: `RelayTests/Sessions/TmuxFocusResolverTests.swift`

**Interfaces:**
- Consumes: `TerminalContext.tmuxSocketPath`, `tmuxPaneID`, `FrontmostApplication.pid`, `ProcessInspector`.
- Produces: `TmuxClientListing`, `TmuxCommandRunning`, `TmuxFocusResolver`.
- Uses documented tmux commands only; does not alter tmux state.

- [ ] **Step 1: Write resolver tests with a fake tmux command runner**

```swift
import XCTest
@testable import Relay

final class TmuxFocusResolverTests: XCTestCase {
    func testMatchingFrontmostClientAndPaneIsFocused() async {
        let runner = StubTmuxRunner(
            clients: [.init(name: "/dev/ttys001", pid: 300)],
            activePaneByClient: ["/dev/ttys001": "%7"]
        )
        let inspector = StubProcessTree(ancestries: [300: [300, 100, 20, 1]])
        let resolver = TmuxFocusResolver(runner: runner, processTrees: inspector)
        let session = makeTmuxSession(pane: "%7")
        let context = FocusContext(
            frontmostApplication: .init(pid: 20, bundleIdentifier: nil, localizedName: "Terminal"),
            sessions: [session], now: Date()
        )
        XCTAssertEqual((await resolver.resolve(session: session, context: context)).state, .focused)
    }

    func testSameClientDifferentPaneIsNotFocused() async {
        let runner = StubTmuxRunner(
            clients: [.init(name: "/dev/ttys001", pid: 300)],
            activePaneByClient: ["/dev/ttys001": "%9"]
        )
        let inspector = StubProcessTree(ancestries: [300: [300, 100, 20, 1]])
        let resolver = TmuxFocusResolver(runner: runner, processTrees: inspector)
        let decision = await resolver.resolve(
            session: makeTmuxSession(pane: "%7"),
            context: .init(frontmostApplication: .init(pid: 20, bundleIdentifier: nil, localizedName: "Terminal"), sessions: [], now: Date())
        )
        XCTAssertEqual(decision.state, .notFocused)
    }

    func testTwoTmuxClientsUnderSameFrontmostAppAreUnknown() async {
        let runner = StubTmuxRunner(
            clients: [.init(name: "c1", pid: 300), .init(name: "c2", pid: 301)],
            activePaneByClient: ["c1": "%7", "c2": "%8"]
        )
        let inspector = StubProcessTree(ancestries: [300: [300, 20, 1], 301: [301, 20, 1]])
        let resolver = TmuxFocusResolver(runner: runner, processTrees: inspector)
        let decision = await resolver.resolve(
            session: makeTmuxSession(pane: "%7"),
            context: .init(frontmostApplication: .init(pid: 20, bundleIdentifier: nil, localizedName: "Terminal"), sessions: [], now: Date())
        )
        XCTAssertEqual(decision.state, .unknown)
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

private struct StubProcessTree: ProcessTreeReading {
    let ancestries: [Int32: [Int32]]
    func ancestry(from pid: Int32) async throws -> [Int32] { ancestries[pid] ?? [] }
}

private func makeTmuxSession(pane: String) -> AgentSession {
    let event = AgentResponseEvent(
        id: UUID(), provider: .claudeCode, providerSessionID: "a", turnID: nil,
        text: "done", cwd: "/tmp/repo", transcriptPath: nil, parentPID: 900,
        environment: ["TMUX": "/tmp/tmux.sock,10,0", "TMUX_PANE": pane], capturedAt: Date()
    )
    return AgentSession(
        id: .init(provider: .claudeCode, providerSessionID: "a"), cwd: event.cwd,
        terminalContext: TerminalContext(event: event), processAncestry: [], tty: nil,
        latestResponse: event, lastActivityAt: event.capturedAt
    )
}
```

- [ ] **Step 2: Implement executable location and command runner**

```swift
// Relay/Sessions/Tmux/TmuxExecutableLocator.swift
import Foundation

struct TmuxExecutableLocator: Sendable {
    let candidates = [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/opt/local/bin/tmux",
        "/usr/bin/tmux"
    ]

    func locate(fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> String? {
        candidates.first(where: fileExists)
    }
}
```

```swift
// Relay/Sessions/Tmux/TmuxClient.swift
import Foundation

struct TmuxClientListing: Equatable, Sendable {
    let name: String
    let pid: Int32
}

protocol TmuxCommandRunning: Sendable {
    func listClients(socketPath: String) async throws -> [TmuxClientListing]
    func activePane(socketPath: String, clientName: String) async throws -> String
}

struct TmuxClient: TmuxCommandRunning {
    let executable: String

    func listClients(socketPath: String) async throws -> [TmuxClientListing] {
        let output = try run(["-S", socketPath, "list-clients", "-F", "#{client_name}\\t#{client_pid}"])
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, let pid = Int32(parts[1]) else { return nil }
            return .init(name: parts[0], pid: pid)
        }
    }

    func activePane(socketPath: String, clientName: String) async throws -> String {
        try run(["-S", socketPath, "display-message", "-p", "-c", clientName, "#{pane_id}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func run(_ arguments: [String]) throws -> String {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw TmuxError.commandFailed }
        return String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}

enum TmuxError: Error { case commandFailed }
```

The tmux man page guarantees `TMUX_PANE` pane IDs, `list-clients -F`, and `display-message -p -c target-client` formatting; this plan uses only those read-only operations.

- [ ] **Step 3: Add a small process-tree abstraction and implement the resolver**

Add to `ProcessInspector.swift`:

```swift
protocol ProcessTreeReading: Sendable {
    func ancestry(from pid: Int32) async throws -> [Int32]
}

extension ProcessInspector: ProcessTreeReading {
    func ancestry(from pid: Int32) async throws -> [Int32] {
        try snapshot().ancestry(from: pid).map(\.pid)
    }
}
```

Implement:

```swift
// Relay/Sessions/Resolvers/TmuxFocusResolver.swift
import Foundation

struct TmuxFocusResolver: FocusResolver {
    let id = "tmux"
    let runner: any TmuxCommandRunning
    let processTrees: any ProcessTreeReading

    func supports(_ session: AgentSession) -> Bool {
        session.terminalContext.tmuxSocketPath != nil && session.terminalContext.tmuxPaneID != nil
    }

    func resolve(session: AgentSession, context: FocusContext) async -> FocusDecision {
        guard let frontmostPID = context.frontmostApplication?.pid,
              let socket = session.terminalContext.tmuxSocketPath,
              let producingPane = session.terminalContext.tmuxPaneID else {
            return .unknown(resolverID: id, reason: "missing frontmost app or tmux identifiers")
        }
        do {
            let clients = try await runner.listClients(socketPath: socket)
            var frontmostClients: [TmuxClientListing] = []
            for client in clients {
                if try await processTrees.ancestry(from: client.pid).contains(frontmostPID) {
                    frontmostClients.append(client)
                }
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

- [ ] **Step 4: Run tests and commit**

```bash
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -only-testing:RelayTests/TmuxFocusResolverTests test
git add Relay/Sessions/Tmux Relay/Sessions/Resolvers/TmuxFocusResolver.swift Relay/Sessions/ProcessInspector.swift RelayTests/Sessions/TmuxFocusResolverTests.swift
git commit -m "feat: resolve focused tmux pane"
```

Expected: PASS.

---

## Task 6: Implement exact Herdr pane/session focus resolution as an optional enhancement

**Files:**
- Create: `Relay/Sessions/Herdr/HerdrModels.swift`
- Create: `Relay/Sessions/Herdr/HerdrSocketClient.swift`
- Create: `Relay/Sessions/Resolvers/HerdrFocusResolver.swift`
- Test: `RelayTests/Sessions/HerdrFocusResolverTests.swift`

**Interfaces:**
- Consumes: `HERDR_SOCKET_PATH`, `HERDR_PANE_ID`, provider session ID, frontmost app PID.
- Produces: `HerdrQuerying.currentPane(socketPath:)`, `HerdrFocusResolver`.
- Herdr is never imported as a library and no Herdr config is modified.

- [ ] **Step 1: Write Herdr response decoding and focus tests**

```swift
import XCTest
@testable import Relay

final class HerdrFocusResolverTests: XCTestCase {
    func testFocusedPaneAndMatchingNativeAgentSessionIsFocused() async {
        let herdr = StubHerdrQuery(
            pane: .init(
                paneID: "w1:p2",
                focused: true,
                agentSession: .init(source: "herdr:claude", agent: "claude", kind: "id", value: "claude-a")
            )
        )
        let ownership = StubHerdrHostOwnership(owns: true)
        let resolver = HerdrFocusResolver(herdr: herdr, hostOwnership: ownership)
        let session = makeHerdrSession(provider: .claudeCode, sessionID: "claude-a", pane: "w1:p2")
        let context = FocusContext(
            frontmostApplication: .init(pid: 20, bundleIdentifier: nil, localizedName: "Ghostty"),
            sessions: [session], now: Date()
        )
        XCTAssertEqual((await resolver.resolve(session: session, context: context)).state, .focused)
    }

    func testMatchingPaneInBackgroundHerdrClientIsNotAuthorized() async {
        let herdr = StubHerdrQuery(pane: .init(paneID: "w1:p2", focused: true, agentSession: nil))
        let resolver = HerdrFocusResolver(herdr: herdr, hostOwnership: StubHerdrHostOwnership(owns: false))
        let session = makeHerdrSession(provider: .claudeCode, sessionID: "a", pane: "w1:p2")
        let context = FocusContext(
            frontmostApplication: .init(pid: 88, bundleIdentifier: "com.apple.Safari", localizedName: "Safari"),
            sessions: [session], now: Date()
        )
        XCTAssertEqual((await resolver.resolve(session: session, context: context)).state, .notFocused)
    }

    func testDifferentActivePaneIsNotFocused() async {
        let resolver = HerdrFocusResolver(
            herdr: StubHerdrQuery(pane: .init(paneID: "w1:p9", focused: true, agentSession: nil)),
            hostOwnership: StubHerdrHostOwnership(owns: true)
        )
        let session = makeHerdrSession(provider: .codex, sessionID: "c", pane: "w1:p2")
        let context = FocusContext(frontmostApplication: .init(pid: 20, bundleIdentifier: nil, localizedName: "Ghostty"), sessions: [session], now: Date())
        XCTAssertEqual((await resolver.resolve(session: session, context: context)).state, .notFocused)
    }
}

private struct StubHerdrQuery: HerdrQuerying {
    let pane: HerdrPaneInfo
    func currentPane(socketPath: String) async throws -> HerdrPaneInfo { pane }
}

private struct StubHerdrHostOwnership: HerdrHostOwnershipChecking {
    let owns: Bool
    func frontmostAppOwnsClient(frontmostPID: Int32, socketPath: String) async -> Bool { owns }
}

private func makeHerdrSession(provider: AgentProvider, sessionID: String, pane: String) -> AgentSession {
    let event = AgentResponseEvent(
        id: UUID(), provider: provider, providerSessionID: sessionID, turnID: nil,
        text: "done", cwd: "/tmp/repo", transcriptPath: nil, parentPID: 900,
        environment: ["HERDR_SOCKET_PATH": "/tmp/herdr.sock", "HERDR_PANE_ID": pane], capturedAt: Date()
    )
    return AgentSession(
        id: .init(provider: provider, providerSessionID: sessionID), cwd: event.cwd,
        terminalContext: TerminalContext(event: event), processAncestry: [], tty: nil,
        latestResponse: event, lastActivityAt: event.capturedAt
    )
}
```

- [ ] **Step 2: Implement the documented newline-delimited Herdr socket request**

```swift
// Relay/Sessions/Herdr/HerdrModels.swift
import Foundation

struct HerdrAgentSession: Codable, Equatable, Sendable {
    let source: String
    let agent: String
    let kind: String
    let value: String
}

struct HerdrPaneInfo: Equatable, Sendable {
    let paneID: String
    let focused: Bool
    let agentSession: HerdrAgentSession?
}

struct HerdrPaneWire: Decodable {
    let paneID: String
    let focused: Bool
    let agentSession: HerdrAgentSession?
    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case focused
        case agentSession = "agent_session"
    }
}

struct HerdrPaneResult: Decodable { let type: String; let pane: HerdrPaneWire }
struct HerdrResponse: Decodable { let id: String; let result: HerdrPaneResult? }
```

```swift
// Relay/Sessions/Herdr/HerdrSocketClient.swift
import Foundation
import Darwin

protocol HerdrQuerying: Sendable {
    func currentPane(socketPath: String) async throws -> HerdrPaneInfo
}

struct HerdrSocketClient: HerdrQuerying {
    func currentPane(socketPath: String) async throws -> HerdrPaneInfo {
        let request = #"{"id":"relay_focus","method":"pane.current","params":{}}"# + "\n"
        let line = try await UnixLineRequest.send(path: socketPath, line: request, timeoutMilliseconds: 400)
        let response = try JSONDecoder().decode(HerdrResponse.self, from: Data(line.utf8))
        guard let pane = response.result?.pane else { throw HerdrQueryError.invalidResponse }
        return HerdrPaneInfo(paneID: pane.paneID, focused: pane.focused, agentSession: pane.agentSession)
    }
}

enum HerdrQueryError: Error { case invalidResponse, socketFailure, pathTooLong, responseTooLarge }

enum UnixLineRequest {
    static func send(path: String, line: String, timeoutMilliseconds: Int32) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try sendBlocking(path: path, line: line, timeoutMilliseconds: timeoutMilliseconds)
        }.value
    }

    private static func sendBlocking(path: String, line: String, timeoutMilliseconds: Int32) throws -> String {
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw HerdrQueryError.pathTooLong
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HerdrQueryError.socketFailure }
        defer { Darwin.close(fd) }

        var tv = timeval(tv_sec: 0, tv_usec: timeoutMilliseconds * 1_000)
        _ = withUnsafePointer(to: &tv) { ptr in
            Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }
        _ = withUnsafePointer(to: &tv) { ptr in
            Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }

        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { dst in
            dst.initializeMemory(as: UInt8.self, repeating: 0)
            pathBytes.withUnsafeBytes { src in
                dst.copyBytes(from: src.prefix(dst.count))
            }
        }
        let addressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, addressLength)
            }
        }
        guard connected == 0 else { throw HerdrQueryError.socketFailure }

        let bytes = Array(line.utf8)
        var sent = 0
        while sent < bytes.count {
            let wrote = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(fd, base.advanced(by: sent), bytes.count - sent)
            }
            guard wrote > 0 else { throw HerdrQueryError.socketFailure }
            sent += wrote
        }

        var response = Data()
        var byte: UInt8 = 0
        while response.count <= 64 * 1024 {
            let count = Darwin.read(fd, &byte, 1)
            guard count > 0 else { throw HerdrQueryError.socketFailure }
            if byte == 0x0A { return String(decoding: response, as: UTF8.self) }
            response.append(byte)
        }
        throw HerdrQueryError.responseTooLarge
    }
}
```

This client connects to the **existing Herdr socket**, writes one line, reads one response line, and closes. It never uses Relay's own hook socket path.

Herdr's documented behavior is important: omitting `caller_pane_id` from `pane.current` returns the Herdr server's active focused pane. `PaneInfo` may also expose the stored native `agent_session`, which can be used as additional evidence when its `value` matches `providerSessionID`.

- [ ] **Step 3: Verify that the queried Herdr session belongs to the frontmost terminal host**

Create a narrow protocol so the ownership check can be tested independently:

```swift
protocol HerdrHostOwnershipChecking: Sendable {
    func frontmostAppOwnsClient(frontmostPID: Int32, socketPath: String) async -> Bool
}
```

Implement the checker exactly as a read-only process/socket proof:

```swift
struct HerdrHostOwnershipChecker: HerdrHostOwnershipChecking {
    let processInspector: ProcessInspector

    func frontmostAppOwnsClient(frontmostPID: Int32, socketPath: String) async -> Bool {
        guard let snapshot = try? processInspector.snapshot() else { return false }
        let candidates = snapshot.descendants(of: frontmostPID).filter {
            URL(fileURLWithPath: $0.command).lastPathComponent.lowercased() == "herdr"
        }
        for candidate in candidates where lsof(pid: candidate.pid, contains: socketPath) {
            return true
        }
        return false
    }

    private func lsof(pid: Int32, contains socketPath: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: "/usr/sbin/lsof") else { return false }
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-a", "-p", String(pid), "-U", "-Fn"]
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return false }
        let text = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).contains { line in
            line.first == "n" && String(line.dropFirst()) == socketPath
        }
    }
}
```

This is deliberately conservative: a background Herdr server may still report an internally focused pane, but it must not authorize speech unless a client connected to that same socket belongs to the current frontmost macOS app.

- [ ] **Step 4: Implement the Herdr resolver**

```swift
// Relay/Sessions/Resolvers/HerdrFocusResolver.swift
import Foundation

struct HerdrFocusResolver: FocusResolver {
    let id = "herdr"
    let herdr: any HerdrQuerying
    let hostOwnership: any HerdrHostOwnershipChecking

    func supports(_ session: AgentSession) -> Bool {
        session.terminalContext.herdrSocketPath != nil && session.terminalContext.herdrPaneID != nil
    }

    func resolve(session: AgentSession, context: FocusContext) async -> FocusDecision {
        guard let frontmostPID = context.frontmostApplication?.pid,
              let socket = session.terminalContext.herdrSocketPath,
              let producingPane = session.terminalContext.herdrPaneID else {
            return .unknown(resolverID: id, reason: "missing frontmost app or Herdr identifiers")
        }
        guard await hostOwnership.frontmostAppOwnsClient(frontmostPID: frontmostPID, socketPath: socket) else {
            return .notFocused(resolverID: id, reason: "frontmost app does not own a client for this Herdr socket")
        }
        do {
            let current = try await herdr.currentPane(socketPath: socket)
            guard current.paneID == producingPane else {
                return .notFocused(resolverID: id, reason: "Herdr active focused pane differs from producing pane")
            }
            if let nativeSession = current.agentSession,
               nativeSession.value != session.id.providerSessionID {
                return .notFocused(resolverID: id, reason: "Herdr focused pane belongs to a different native agent session")
            }
            return .focused(resolverID: id, reason: "frontmost Herdr client and active pane match producing session")
        } catch {
            return .unknown(resolverID: id, reason: "Herdr focus query failed")
        }
    }
}
```

- [ ] **Step 5: Run tests and commit**

```bash
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -only-testing:RelayTests/HerdrFocusResolverTests test
git add Relay/Sessions/Herdr Relay/Sessions/Resolvers/HerdrFocusResolver.swift RelayTests/Sessions/HerdrFocusResolverTests.swift
git commit -m "feat: resolve focused Herdr agent pane"
```

Expected: PASS.

---

## Task 7: Track recent voice interaction as supporting evidence only

**Files:**
- Create: `Relay/Sessions/RecentInteractionTracker.swift`
- Modify: `Relay/SpeechIn/DictationCoordinator.swift`
- Test: `RelayTests/Sessions/RecentInteractionTrackerTests.swift`

**Interfaces:**
- Produces: `RecentVoiceInteraction`, `RecentInteractionTracker.record(frontmostApplication:at:)`, `latest()`.
- This signal must never independently return `focused(high)`.

- [ ] **Step 1: Write expiry and replacement tests**

```swift
import XCTest
@testable import Relay

final class RecentInteractionTrackerTests: XCTestCase {
    func testNewestDictationReplacesPriorInteraction() async {
        let tracker = RecentInteractionTracker(maxAge: 120)
        await tracker.record(frontmostApplication: .init(pid: 20, bundleIdentifier: nil, localizedName: "Terminal"), at: Date(timeIntervalSince1970: 10))
        await tracker.record(frontmostApplication: .init(pid: 30, bundleIdentifier: nil, localizedName: "Other"), at: Date(timeIntervalSince1970: 20))
        XCTAssertEqual((await tracker.latest(now: Date(timeIntervalSince1970: 21)))?.frontmostPID, 30)
    }

    func testOldInteractionExpires() async {
        let tracker = RecentInteractionTracker(maxAge: 120)
        await tracker.record(frontmostApplication: .init(pid: 20, bundleIdentifier: nil, localizedName: "Terminal"), at: Date(timeIntervalSince1970: 10))
        XCTAssertNil(await tracker.latest(now: Date(timeIntervalSince1970: 200)))
    }
}
```

- [ ] **Step 2: Implement memory-only recent interaction state**

```swift
// Relay/Sessions/RecentInteractionTracker.swift
import Foundation

struct RecentVoiceInteraction: Equatable, Sendable {
    let frontmostPID: Int32
    let capturedAt: Date
}

actor RecentInteractionTracker {
    private var value: RecentVoiceInteraction?
    private let maxAge: TimeInterval

    init(maxAge: TimeInterval = 120) { self.maxAge = maxAge }

    func record(frontmostApplication: FrontmostApplication, at: Date = Date()) {
        value = .init(frontmostPID: frontmostApplication.pid, capturedAt: at)
    }

    func latest(now: Date = Date()) -> RecentVoiceInteraction? {
        guard let value, now.timeIntervalSince(value.capturedAt) <= maxAge else { return nil }
        return value
    }
}
```

- [ ] **Step 3: Record the app receiving dictation without changing dictation behavior**

Inject `FrontmostAppMonitoring` and `RecentInteractionTracker` into `DictationCoordinator`. Immediately before microphone capture begins, call `frontmostApps.current()` and record the returned app. Existing behavior remains:

```text
start dictation
-> SpeechCoordinator.stop()
-> record recent frontmost app if available
-> microphone capture starts
```

The tracker is **supporting metadata only**. In v1 it may be exposed in diagnostics and may help future resolvers break ties, but it does not override an ambiguous direct-terminal result or a negative tmux/Herdr result.

- [ ] **Step 4: Run tests and commit**

```bash
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -only-testing:RelayTests/RecentInteractionTrackerTests test
git add Relay/Sessions/RecentInteractionTracker.swift Relay/SpeechIn/DictationCoordinator.swift RelayTests/Sessions/RecentInteractionTrackerTests.swift
git commit -m "feat: track recent voice interaction"
```

Expected: PASS.

---

## Task 8: Publish completed agent events into session intelligence and auto-read only focused sessions

**Files:**
- Modify: `Relay/Integrations/IntegrationManager.swift`
- Create: `Relay/Sessions/AgentAutoReadCoordinator.swift`
- Test: `RelayTests/Sessions/AgentAutoReadCoordinatorTests.swift`

**Interfaces:**
- `IntegrationManager` adds a decoded-event callback; provider adapters remain unchanged.
- `AgentAutoReadCoordinator.handle(_:)` captures process context, upserts the session, resolves current focus, and conditionally submits one automatic `SpeechRequest`.
- Consumes: `RulesSpeechPreprocessor`, `SpeechCoordinator`, `AppSettings.autoReadEnabled`.

- [ ] **Step 1: Write auto-read acceptance tests around focus outcomes**

```swift
import XCTest
@testable import Relay

@MainActor
final class AgentAutoReadCoordinatorTests: XCTestCase {
    func testFocusedHighResponseSpeaksAutomatically() async throws {
        let speech = RecordingSpeechSink()
        let coordinator = makeCoordinator(focus: .focused(resolverID: "tmux", reason: "exact pane"), speech: speech, autoRead: true)
        await coordinator.handle(makeAutoReadEvent(text: "**Done.**"))
        XCTAssertEqual(speech.requests.count, 1)
        XCTAssertEqual(speech.requests[0].mode, .automatic)
        XCTAssertEqual(speech.requests[0].sessionID, "claude-code:a")
    }

    func testBackgroundResponseStaysSilentButRegistryKeepsIt() async throws {
        let speech = RecordingSpeechSink()
        let harness = makeCoordinatorHarness(focus: .notFocused(resolverID: "tmux", reason: "other pane"), speech: speech, autoRead: true)
        await harness.coordinator.handle(makeAutoReadEvent(text: "background"))
        XCTAssertTrue(speech.requests.isEmpty)
        XCTAssertEqual((await harness.registry.sessions()).first?.latestResponse.text, "background")
    }

    func testUnknownFocusStaysSilent() async {
        let speech = RecordingSpeechSink()
        let coordinator = makeCoordinator(focus: .unknown(resolverID: "generic", reason: "ambiguous"), speech: speech, autoRead: true)
        await coordinator.handle(makeAutoReadEvent(text: "done"))
        XCTAssertTrue(speech.requests.isEmpty)
    }

    func testDisabledAutoReadSkipsFocusAndSpeech() async {
        let speech = RecordingSpeechSink()
        let coordinator = makeCoordinator(focus: .focused(resolverID: "tmux", reason: "exact pane"), speech: speech, autoRead: false)
        await coordinator.handle(makeAutoReadEvent(text: "done"))
        XCTAssertTrue(speech.requests.isEmpty)
    }
}

private struct StubSessionFocusResolver: SessionFocusResolving {
    let decision: FocusDecision
    func resolve(session: AgentSession) async -> FocusDecision { decision }
}

private struct StubProcessContextCapture: AgentProcessContextCapturing {
    func capture(parentPID: Int32) async -> AgentProcessContext {
        .init(ancestry: [parentPID, 20, 1], tty: "/dev/ttys001")
    }
}

@MainActor
private final class RecordingSpeechSink: SpeechSubmitting {
    var requests: [SpeechRequest] = []
    func speak(_ request: SpeechRequest) async throws { requests.append(request) }
}

private struct AutoReadHarness {
    let coordinator: AgentAutoReadCoordinator
    let registry: AgentSessionRegistry
}

@MainActor
private func makeCoordinatorHarness(
    focus: FocusDecision,
    speech: RecordingSpeechSink,
    autoRead: Bool
) -> AutoReadHarness {
    let registry = AgentSessionRegistry()
    let coordinator = AgentAutoReadCoordinator(
        registry: registry,
        processContext: StubProcessContextCapture(),
        focus: StubSessionFocusResolver(decision: focus),
        preprocess: { $0.replacingOccurrences(of: "**", with: "") },
        speech: speech,
        autoReadEnabled: { autoRead }
    )
    return .init(coordinator: coordinator, registry: registry)
}

@MainActor
private func makeCoordinator(
    focus: FocusDecision,
    speech: RecordingSpeechSink,
    autoRead: Bool
) -> AgentAutoReadCoordinator {
    makeCoordinatorHarness(focus: focus, speech: speech, autoRead: autoRead).coordinator
}

private func makeAutoReadEvent(text: String) -> AgentResponseEvent {
    .init(
        id: UUID(), provider: .claudeCode, providerSessionID: "a", turnID: nil,
        text: text, cwd: "/tmp/repo", transcriptPath: nil,
        parentPID: 900, environment: [:], capturedAt: Date()
    )
}
```

- [ ] **Step 2: Make speech submission injectable without changing Phase 1 semantics**

Add a narrow protocol next to `SpeechCoordinator`:

```swift
@MainActor
protocol SpeechSubmitting: AnyObject {
    func speak(_ request: SpeechRequest) async throws
}

extension SpeechCoordinator: SpeechSubmitting {}
```

Tests use `RecordingSpeechSink`; production still uses the existing coordinator/router.

- [ ] **Step 3: Publish decoded events from `IntegrationManager`**

Add this stored callback to the Phase 2 `IntegrationManager`:

```swift
private let onResponse: @Sendable (AgentResponseEvent) async -> Void
```

Add `onResponse: @escaping @Sendable (AgentResponseEvent) async -> Void = { _ in }` as the final parameter of the manager's existing designated initializer, and assign it with:

```swift
self.onResponse = onResponse
```

After a provider adapter successfully decodes and `LatestAgentResponseStore` receives the event, invoke:

```swift
await onResponse(event)
```

Malformed events remain ignored/status-reported exactly as Phase 2 specifies. Do not move provider-specific decoding into the new coordinator.

- [ ] **Step 4: Implement session capture and focused-only auto-read**

```swift
// Relay/Sessions/AgentAutoReadCoordinator.swift
import Foundation

struct AgentProcessContext: Sendable, Equatable {
    let ancestry: [Int32]
    let tty: String?
}

protocol AgentProcessContextCapturing: Sendable {
    func capture(parentPID: Int32) async -> AgentProcessContext
}

struct AgentProcessContextCapture: AgentProcessContextCapturing {
    let processInspector: ProcessInspector

    func capture(parentPID: Int32) async -> AgentProcessContext {
        guard let snapshot = try? processInspector.snapshot() else {
            return .init(ancestry: [], tty: nil)
        }
        let records = snapshot.ancestry(from: parentPID)
        return .init(ancestry: records.map(\.pid), tty: records.compactMap(\.tty).first)
    }
}

actor AgentAutoReadCoordinator {
    private let registry: AgentSessionRegistry
    private let processContext: any AgentProcessContextCapturing
    private let focus: any SessionFocusResolving
    private let preprocess: @Sendable (String) -> String
    private let speech: any SpeechSubmitting
    private let autoReadEnabled: @Sendable () async -> Bool

    init(
        registry: AgentSessionRegistry,
        processContext: any AgentProcessContextCapturing,
        focus: any SessionFocusResolving,
        preprocess: @escaping @Sendable (String) -> String,
        speech: any SpeechSubmitting,
        autoReadEnabled: @escaping @Sendable () async -> Bool
    ) {
        self.registry = registry
        self.processContext = processContext
        self.focus = focus
        self.preprocess = preprocess
        self.speech = speech
        self.autoReadEnabled = autoReadEnabled
    }

    func handle(_ event: AgentResponseEvent) async {
        let captured = await processContext.capture(parentPID: event.parentPID)
        let session = await registry.upsert(
            response: event,
            processAncestry: captured.ancestry,
            tty: captured.tty
        )

        guard await autoReadEnabled() else { return }
        let decision = await focus.resolve(session: session)
        guard decision.state == .focused, decision.confidence == .high else { return }

        let source: SpeechSource = event.provider == .claudeCode ? .claudeCode : .codex
        let request = SpeechRequest(
            text: preprocess(event.text),
            source: source,
            mode: .automatic,
            sessionID: "\(event.provider.rawValue):\(event.providerSessionID)"
        )
        try? await speech.speak(request)
    }
}
```

`preprocess` is wired to Phase 1 `RulesSpeechPreprocessor` in `.automatic` mode. Long responses/code blocks therefore use the existing speech-friendly policy before TTS.

- [ ] **Step 5: Run tests and commit**

```bash
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' -only-testing:RelayTests/AgentAutoReadCoordinatorTests test
git add Relay/Integrations/IntegrationManager.swift Relay/Sessions/AgentAutoReadCoordinator.swift Relay/SpeechOut/SpeechCoordinator.swift RelayTests/Sessions/AgentAutoReadCoordinatorTests.swift
git commit -m "feat: auto-read only confidently focused agent responses"
```

Expected: PASS.

---

## Task 9: Wire resolvers, settings, diagnostics, and end-to-end acceptance tests

**Files:**
- Modify: `Relay/App/AppModel.swift`
- Modify: `Relay/App/MenuBarContentView.swift`
- Modify: `Relay/App/SettingsView.swift`
- Test: manual matrix below; existing XCTest suite must remain green.

**Interfaces:**
- App resolver order is `HerdrFocusResolver`, `TmuxFocusResolver`, `GenericTerminalFocusResolver`.
- `HotkeyAction.toggleAutoRead` toggles existing `AppSettings.autoReadEnabled`.
- Menu UI exposes no hidden “force focus” override in v1.

- [ ] **Step 1: Build the production dependency graph in `AppModel`**

Instantiate one shared set of objects in this order:

```swift
let sessionRegistry = AgentSessionRegistry()
let processInspector = ProcessInspector()
let frontmostApps = FrontmostAppMonitor()
let recentInteractionTracker = RecentInteractionTracker()
let tmuxRunner = TmuxExecutableLocator().locate().map { TmuxClient(executable: $0) }
let herdrClient = HerdrSocketClient()
let agentProcessContext = AgentProcessContextCapture(processInspector: processInspector)
```

Construct the resolver list dynamically:

```swift
var resolvers: [any FocusResolver] = []
resolvers.append(HerdrFocusResolver(
    herdr: herdrClient,
    hostOwnership: HerdrHostOwnershipChecker(processInspector: processInspector)
))
if let tmuxRunner {
    resolvers.append(TmuxFocusResolver(runner: tmuxRunner, processTrees: processInspector))
}
resolvers.append(GenericTerminalFocusResolver())
```

Then build `FocusResolutionService`, `AgentAutoReadCoordinator(registry:processContext:focus:preprocess:speech:autoReadEnabled:)` using `agentProcessContext`, and inject `onResponse: { event in await autoRead.handle(event) }` into `IntegrationManager`.

`DictationCoordinator` receives the same `frontmostApps` and `recentInteractionTracker` instances.

- [ ] **Step 2: Wire the configurable auto-read hotkey and settings row**

The Phase 1 `.toggleAutoRead` action must mutate/persist `AppSettings.autoReadEnabled`. Settings should show:

```text
Agent responses
[✓] Automatically speak confidently focused Claude/Codex sessions
    Background or ambiguous sessions stay silent.
```

Keep all hotkeys configurable through the existing Phase 1 hotkey editor; do not introduce a second keybinding store.

- [ ] **Step 3: Add compact diagnostics without persisting response text**

Menu-bar diagnostics may show only metadata:

```text
Agent Sessions
Claude Code   /repo/api     Focus: tmux/high
Codex         /repo/web     Focus: background
```

Do **not** render or persist full response text in the diagnostic list. `Speak Latest Agent Response` remains the explicit manual action from Phase 2.

- [ ] **Step 4: Run the complete automated suite**

```bash
xcodegen generate
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' test
```

Expected: all Phase 1, Phase 2, and Phase 3 tests PASS.

- [ ] **Step 5: Perform the real-world focus matrix**

Use two short Claude/Codex prompts that produce distinct final messages, and verify each row exactly:

| Environment | Setup | Focus at completion | Expected |
|---|---|---|---|
| Ghostty direct | one Claude session | Claude terminal frontmost | speaks |
| Ghostty direct | Claude terminal | Safari frontmost | silent |
| Ghostty direct | two agent sessions sharing same Ghostty app process | either direct session | silent if exact pane cannot be proven |
| Ghostty + tmux | Claude pane A, Codex pane B | pane A | only A speaks |
| Ghostty + tmux | Claude pane A, Codex pane B | pane B | only B speaks |
| Ghostty + tmux | agent pane | Safari frontmost | silent |
| Ghostty + Herdr | Claude pane A, Codex pane B | pane A | only A speaks |
| Ghostty + Herdr | Claude pane A, Codex pane B | pane B | only B speaks |
| Ghostty + Herdr | agent pane | another macOS app frontmost | silent |
| plain terminal without tmux/Herdr installed | one Codex session | terminal frontmost | speaks |
| any environment | focused response, auto-read disabled | focused | silent |
| any environment | background response then `Speak Latest Agent Response` | manual action | speaks latest explicitly |
| any environment | automatic speech active then dictation hotkey | user starts dictating | speech stops immediately |
| any macOS app | selected text + read-selection hotkey | explicit action | selected text speaks and overrides auto speech |

For tmux/Herdr rows, start both agents before sending prompts so simultaneous session tracking is exercised rather than sequential single-session behavior.

- [ ] **Step 6: Verify privacy/state behavior**

After exercising all environments:

```bash
find "$HOME/Library/Application Support/Relay" -maxdepth 2 -type f -print
```

Expected: settings/model-related files only. No audio, transcripts, agent response text, focus snapshots, or session history.

Quit/relaunch Relay and verify the agent-session list is empty until new hook events arrive.

- [ ] **Step 7: Commit Phase 3 integration**

```bash
git add Relay RelayTests project.yml
git commit -m "feat: complete focused-session auto-read"
```

---

## Phase 3 Exit Criteria

Phase 3 is complete only when all of the following are true:

- Claude Code and Codex completion events still arrive through the Phase 2 hook transport without provider-specific code in the speech/session core.
- Multiple Claude/Codex provider sessions are tracked independently in memory.
- One direct agent session in a frontmost terminal can auto-speak without Relay knowing the terminal product name.
- Ambiguous multiple direct sessions in one terminal app process stay silent.
- tmux pane identity uses the event's `TMUX_PANE` and the currently active pane of the tmux client associated with the frontmost macOS app.
- Herdr pane identity uses `HERDR_SOCKET_PATH` / `HERDR_PANE_ID`, Herdr's `pane.current`, and proof that the frontmost app owns a client connected to that Herdr socket.
- Switching away before an agent finishes makes the response silent.
- Switching back to that exact tmux/Herdr session before completion allows it to speak.
- Background/unknown responses remain available for explicit manual speech.
- Disabling auto-read prevents automatic speech regardless of focus.
- Dictation interrupts current automatic speech immediately.
- Explicit selected-text speech keeps higher priority than agent auto-read.
- No session/focus/response history survives app restart.
- The entire Phase 1–3 test suite is green.

---

## Implementation Notes and Deliberate Boundaries

### Why direct terminals are conservative

A macOS terminal application can host multiple windows/tabs/panes inside one app process. Process ancestry can prove that an agent belongs to the **frontmost terminal application**, but it cannot always prove which internal terminal surface is selected. Relay therefore auto-speaks a direct session only when that mapping is unambiguous. tmux/Herdr provide stronger pane identity and remove that ambiguity.

### Why Herdr is an enhancement rather than an integration dependency

The Claude/Codex hook payload already identifies the provider session. When that process also carries `HERDR_SOCKET_PATH` and `HERDR_PANE_ID`, the focus layer can opportunistically query Herdr. Removing Herdr or returning to tmux changes only the resolver that supplies focus evidence; the integration and speech pipeline stay unchanged.

### Why current focus wins

Relay resolves focus when the completion event is handled, not when the original prompt was sent. A session that was backgrounded while working stays silent if still backgrounded at completion; if the user returns to it before completion, exact tmux/Herdr focus may authorize speech.

### Recent interaction is intentionally weak in v1

Recent voice interaction is stored because it is useful supporting context and matches the product design, but it never overrules missing/ambiguous pane evidence. A later release can combine it with richer terminal adapters without weakening the conservative v1 safety rule.

---

## Current External Contracts Used by This Plan

Validate these contracts once at implementation start because external tools can evolve:

- **tmux:** `TMUX_PANE` identifies the pane; `list-clients -F` exposes attached clients; `display-message -p -c <client> '#{pane_id}'` returns the active pane in that client's context. Reference: https://man7.org/linux/man-pages/man1/tmux.1.html
- **Herdr:** managed pane processes receive `HERDR_SOCKET_PATH` and `HERDR_PANE_ID`; the socket is newline-delimited JSON; `pane.current` with omitted `caller_pane_id` returns the active focused pane; `PaneInfo` may expose `agent_session`. Reference: https://herdr.dev/docs/socket-api/

If either external contract has changed, update only its resolver/client implementation and tests. Do not alter the core `FocusResolver`, `AgentSession`, speech backend, or integration event contracts merely to accommodate provider-specific drift.
