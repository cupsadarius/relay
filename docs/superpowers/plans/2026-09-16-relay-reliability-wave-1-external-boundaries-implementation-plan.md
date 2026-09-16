# Relay Reliability — Wave 1: External Boundaries Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make every external boundary (subprocess, hook socket, listen socket, session registry, installed helper path) bounded, self-recovering, and unable to sabotage another Relay instance or the coding agent.

**Why:** A static reliability audit (`relay-reliability-simplification-review.md`, §3, §5.1, §6.1) found five P0/P1 boundary defects, all verified TRUE against commit `cfcdf27`:
1. `TmuxClient.run()` can deadlock forever (waits for exit before draining stdout, unread stderr pipe, no timeout).
2. `RelayHook` blocks the coding agent with deadline-free `connect()`/`write()` and reads all of stdin into memory before checking the size cap.
3. `UnixSocketServer` unlinks any current-user socket at its path without probing for a live listener — a second Relay silently hijacks the first's socket.
4. `AgentSessionRegistry` never expires sessions, so dead agents poison generic-terminal focus.
5. Claude/Codex installers write an app-bundle helper path that dies on rebuild/move, and detection by basename masks the stale path.

**Architecture:** The repository already contains a correct bounded-subprocess pattern in `ProcessInspector.snapshot()` and `HerdrHostOwnershipChecker.lsof(...)` (concurrent stdout drain, stderr → `/dev/null`, semaphore deadline, terminate-on-timeout, private `LockedBox`). Wave 1 extracts that pattern into one shared `BoundedProcessRunner`, routes `TmuxClient`/`ProcessInspector`/`HerdrHostOwnership` through it, then hardens the two socket boundaries, adds session pruning, and moves the installed helper to a stable path with migration.

**Tech Stack:** Swift 6 strict concurrency, Foundation, Darwin sockets, XCTest, XcodeGen.

**Templates to mirror (read these first):** `Relay/Sessions/ProcessInspector.swift` (the correct bounded pattern + `LockedBox`), `Relay/Sessions/Herdr/HerdrHostOwnership.swift` (second copy of the same pattern; a copy that Task 1 deletes), `Relay/Sessions/Herdr/HerdrSocketClient.swift` (correct `SO_RCVTIMEO`/`SO_SNDTIMEO` + total-deadline socket client — the model for Task 2), `Relay/Integrations/Transport/UnixSocketServer.swift`, `Relay/Integrations/ClaudeCode/ClaudeCodeInstaller.swift`, `Relay/Integrations/Codex/CodexInstaller.swift`.

---

## Ground rules
- Work on `main`. No worktrees. **Run implementers one at a time — do not let two agents commit to this tree concurrently.**
- Generate the project only via `xcodegen generate`. Never hand-edit `Relay.xcodeproj`.
- TDD each task; build with zero warnings; suite must end `** TEST SUCCEEDED **`.
- **No commit trailers.** Plain messages. No `Co-Authored-By`, no `Generated with`, no session line.
- Privacy: never log spoken text, transcripts, audio, file paths, socket paths, PIDs tied to a user, or raw error strings in logs/Diagnostics/overlay. Structural facts only (e.g. `.timedOut`, `.staleSocketRemoved`).
- These tasks are sequential and independent to commit. Do Task 1 first (others build on the runner where noted). Commit after every task.
- Test command template (replace `<Suite>/<test>`):
  ```bash
  xcodegen generate
  xcodebuild test -scheme Relay -destination 'platform=macOS' \
    -only-testing:RelayTests/<Suite>/<test> 2>&1 | tail -30
  ```
  Full suite before each commit: `xcodebuild test -scheme Relay -destination 'platform=macOS' 2>&1 | tail -30`.

---

## Task 1: Shared `BoundedProcessRunner`; fix `TmuxClient` deadlock; de-duplicate the pattern

**The bug:** `Relay/Sessions/Tmux/TmuxClient.swift:30-41` — `run()` sets `process.standardError = Pipe()` (line 36, an unread pipe), calls `process.run()` then `process.waitUntilExit()` (lines 37-38), and only *after* exit reads stdout to EOF (line 40). No timeout. If `tmux` writes >64 KB to stdout, or anything to stderr, the child blocks on a full kernel pipe buffer while Relay blocks in `waitUntilExit()` → permanent deadlock on the focus path.

**The fix:** extract the already-correct pattern from `ProcessInspector.snapshot()` (`Relay/Sessions/ProcessInspector.swift:70-112`) into one shared runner and route all three subprocess call sites through it.

**Files:**
- Create: `Relay/System/BoundedProcessRunner.swift`
- Create: `RelayTests/System/BoundedProcessRunnerTests.swift`
- Modify: `Relay/Sessions/Tmux/TmuxClient.swift:30-41`
- Modify: `Relay/Sessions/ProcessInspector.swift:70-112` (delegate to the runner; keep `LockedBox` here as the shared one)
- Modify: `Relay/Sessions/Herdr/HerdrHostOwnership.swift:46-108` (delegate to the runner; delete its duplicate `LockedBox`)

- [ ] **Step 1: Write the failing test** — `RelayTests/System/BoundedProcessRunnerTests.swift`

```swift
import XCTest
@testable import Relay

final class BoundedProcessRunnerTests: XCTestCase {
    private let runner = BoundedProcessRunner()

    func testSuccessReturnsStdoutAndZeroStatus() throws {
        let result = try runner.run(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello"],
            timeout: 5,
            maxOutputBytes: 1024
        )
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "hello\n")
    }

    func testNonZeroExitReportsStatusNotThrow() throws {
        let result = try runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 3"],
            timeout: 5,
            maxOutputBytes: 1024
        )
        XCTAssertEqual(result.terminationStatus, 3)
    }

    func testOversizedOutputThrows() {
        // Emit ~1 MB but cap at 4 KB.
        XCTAssertThrowsError(try runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "yes ABCDEFGH | head -c 1000000"],
            timeout: 5,
            maxOutputBytes: 4096
        )) { error in
            XCTAssertEqual(error as? BoundedProcessError, .outputTooLarge)
        }
    }

    func testBlockedProcessTimesOut() {
        let start = Date()
        XCTAssertThrowsError(try runner.run(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            timeout: 0.3,
            maxOutputBytes: 1024
        )) { error in
            XCTAssertEqual(error as? BoundedProcessError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "must not block for the child's full lifetime")
    }

    func testStderrFloodDoesNotDeadlock() throws {
        // Child floods stderr (>64KB). Must not wedge: stderr goes to /dev/null.
        let result = try runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "yes ERR | head -c 200000 1>&2; echo done"],
            timeout: 5,
            maxOutputBytes: 4096
        )
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "done\n")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' -only-testing:RelayTests/BoundedProcessRunnerTests 2>&1 | tail -20`
Expected: FAIL — `BoundedProcessRunner` / `BoundedProcessError` not defined.

- [ ] **Step 3: Implement `BoundedProcessRunner`** — `Relay/System/BoundedProcessRunner.swift`

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

/// Runs a child process with three hard bounds: stderr is discarded (never an
/// unread pipe that can wedge the child), stdout is drained concurrently and
/// capped at `maxOutputBytes`, and the whole call is bounded by `timeout`
/// (the child is terminated on expiry). This is the single approved way to
/// launch a subprocess in Relay — see the audit's P0 "TmuxClient deadlock".
protocol ProcessRunning: Sendable {
    func run(executable: URL, arguments: [String], timeout: TimeInterval, maxOutputBytes: Int) throws -> ProcessResult
}

struct BoundedProcessRunner: ProcessRunning {
    func run(executable: URL, arguments: [String], timeout: TimeInterval, maxOutputBytes: Int) throws -> ProcessResult {
        let process = Process()
        let stdoutPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        // Unread Pipe() fills its 64KB kernel buffer and blocks the child on write.
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { throw BoundedProcessError.launchFailed }

        // Drain stdout on a background thread so we can bound the whole call and
        // read the pipe to EOF concurrently with the child's execution (never
        // after waitUntilExit()). Stop early if output exceeds the cap.
        let readSemaphore = DispatchSemaphore(value: 0)
        let dataBox = LockedBox<Data>(Data())
        let overflowBox = LockedBox<Bool>(false)
        let readQueue = DispatchQueue(label: "BoundedProcessRunner.stdoutDrain")
        readQueue.async {
            let handle = stdoutPipe.fileHandleForReading
            var accumulated = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break } // EOF
                accumulated.append(chunk)
                if accumulated.count > maxOutputBytes {
                    overflowBox.value = true
                    break
                }
            }
            dataBox.value = accumulated
            readSemaphore.signal()
        }

        let deadline = DispatchTime.now() + timeout
        guard readSemaphore.wait(timeout: deadline) == .success else {
            process.terminate()
            throw BoundedProcessError.timedOut
        }
        if overflowBox.value {
            process.terminate()
            throw BoundedProcessError.outputTooLarge
        }

        process.waitUntilExit()
        return ProcessResult(stdout: dataBox.value, terminationStatus: process.terminationStatus)
    }
}

/// Shared `NSLock`-protected box for handing values back from the background
/// drain thread. Was previously duplicated in ProcessInspector and
/// HerdrHostOwnership; now lives here as the one copy.
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}
```

- [ ] **Step 4: Run — verify the runner tests pass**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' -only-testing:RelayTests/BoundedProcessRunnerTests 2>&1 | tail -20`
Expected: PASS (5 tests). Note: `Relay/Sessions/ProcessInspector.swift:118-126` and `Relay/Sessions/Herdr/HerdrHostOwnership.swift:100-107` each still define a private `LockedBox`; the new file-level one will collide in name only if they were `private` (they are). Building may warn about the now-shared name — proceed to Step 5 which removes the duplicates.

- [ ] **Step 5: Fix `TmuxClient` to use the runner (failing test first).**

Add `RelayTests/Sessions/Tmux/TmuxClientBoundsTests.swift`. Inject a fake `ProcessRunning` and assert `TmuxClient` routes through it with bounded params (the deadlock/flood behavior itself is covered by `BoundedProcessRunnerTests`; here we prove `TmuxClient` no longer launches a process directly):

```swift
import XCTest
@testable import Relay

final class TmuxClientBoundsTests: XCTestCase {
    private final class FakeRunner: ProcessRunning, @unchecked Sendable {
        var lastTimeout: TimeInterval?
        var lastMaxOutputBytes: Int?
        func run(executable: URL, arguments: [String], timeout: TimeInterval, maxOutputBytes: Int) throws -> ProcessResult {
            lastTimeout = timeout
            lastMaxOutputBytes = maxOutputBytes
            return ProcessResult(stdout: Data("main\t123\n".utf8), terminationStatus: 0)
        }
    }

    func testListClientsRoutesThroughBoundedRunner() async throws {
        let runner = FakeRunner()
        let client = TmuxClient(executable: "/opt/homebrew/bin/tmux", runner: runner, timeout: 3)
        let listing = try await client.listClients(socketPath: "/tmp/s")
        XCTAssertEqual(listing, [TmuxClientListing(name: "main", pid: 123)])
        XCTAssertEqual(runner.lastTimeout, 3)          // bounded
        XCTAssertNotNil(runner.lastMaxOutputBytes)      // capped
    }
}
```

Then change `TmuxClient` to hold a `ProcessRunning` and route `run(_:)` through it. Replace `Relay/Sessions/Tmux/TmuxClient.swift:13-42`:

```swift
struct TmuxClient: TmuxCommandRunning {
    let executable: String
    let runner: ProcessRunning
    /// tmux queries on the focus path must stay snappy; bound them tightly.
    private let timeout: TimeInterval

    init(executable: String, runner: ProcessRunning = BoundedProcessRunner(), timeout: TimeInterval = 3) {
        self.executable = executable
        self.runner = runner
        self.timeout = timeout
    }

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
        let result = try runner.run(
            executable: URL(fileURLWithPath: executable),
            arguments: arguments,
            timeout: timeout,
            maxOutputBytes: 256 * 1024
        )
        guard result.terminationStatus == 0 else { throw TmuxError.commandFailed }
        return String(decoding: result.stdout, as: UTF8.self)
    }
}
```

Check every `TmuxClient(...)` construction site (grep `TmuxClient(`) and update if the initializer signature changed for callers that passed only `executable:` — the defaulted params keep them source-compatible.

- [ ] **Step 6: Route `ProcessInspector` and `HerdrHostOwnership` through the runner; delete duplicate `LockedBox`.**

- In `Relay/Sessions/ProcessInspector.swift`: replace the body of `snapshot()` (lines 70-112) so it calls a `ProcessRunning` (add a stored `runner: ProcessRunning = BoundedProcessRunner()` and a `maxOutputBytes` cap ~4 MB for the full `ps` table), keeping `timeout` semantics. Then `ProcessSnapshot.parse(String(decoding: result.stdout, as: UTF8.self))`. Map `BoundedProcessError.timedOut` → `ProcessInspectionError.timedOut`, nonzero status → `.psFailed`. Delete the private `LockedBox` (lines 118-126) — now shared.
- In `Relay/Sessions/Herdr/HerdrHostOwnership.swift`: replace the body of `lsof(pid:contains:)` (lines 46-92) with a `runner.run(...)` call bounded by `lsofTimeout`; a thrown error → `return false` (ownership unproven). Delete the private `LockedBox` (lines 100-107).
- Preserve all existing tests for `ProcessInspector` and `HerdrHostOwnership` (there are watchdog/timeout tests — keep them green; inject a fake `ProcessRunning` if a test previously injected a slow executable).

- [ ] **Step 7: Run the full suite; verify no deadlock tests regressed**

Run: `xcodebuild test -scheme Relay -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`, zero warnings.

- [ ] **Step 8: Commit**

```bash
git add Relay/System/BoundedProcessRunner.swift RelayTests/System/BoundedProcessRunnerTests.swift \
  Relay/Sessions/Tmux/TmuxClient.swift RelayTests/Sessions/Tmux/TmuxClientBoundsTests.swift \
  Relay/Sessions/ProcessInspector.swift Relay/Sessions/Herdr/HerdrHostOwnership.swift
git commit -m "fix(process): bound all subprocess launches via shared BoundedProcessRunner"
```

**Acceptance:** no production path waits for exit before draining stdout; no child has an unread stderr pipe; every subprocess has a timeout and an output cap; one `LockedBox` remains.

---

## Task 2: Harden the `RelayHook` transport

**The bug:** `RelayHook/HookTransportClient.swift` — blocking `socket(AF_UNIX, SOCK_STREAM, 0)` (line ~44), blocking `connect()` (line ~68), blocking `write()` loop (line ~84), only `SO_NOSIGPIPE` set (lines ~53-54); no `SO_SNDTIMEO`/`SO_RCVTIMEO`, no non-blocking + `poll()`, no connect/write deadline. A hung or half-open Relay peer blocks the hook — and therefore Claude Code / Codex — indefinitely. Separately, `RelayHook/main.swift:77-100` reads *all* of stdin into memory (`readToEnd()`) then checks `<= maxInputBytes` (`1_500 * 1_024` ≈ 1.46 MiB) *after* the full read.

**Product invariant:** Relay must never make the coding agent less reliable. Hook delivery is optional. If Relay cannot accept an event within the deadline, drop it and exit success.

**Model to copy:** `Relay/Sessions/Herdr/HerdrSocketClient.swift` already sets `SO_RCVTIMEO`/`SO_SNDTIMEO` and a ~1s total deadline. Mirror its approach (simplest reliable fix: non-blocking socket + `poll()` with a total deadline; or blocking socket + both `SO_*TIMEO` — the plan uses non-blocking + `poll()` for a strict *total* budget across connect+write).

**Files:**
- Modify: `RelayHook/HookTransportClient.swift`
- Modify: `RelayHook/main.swift:77-100` (stdin reader) **and `:134`** (the existing call site `try client.send(line: line)` — update it to the new signature so it still compiles)
- Test: `RelayTests/Integrations/HookTransportClientTests.swift` (create)
- Testability: `RelayHook` is an executable target (`PRODUCT_NAME: RelayHook`, and `RelayTests` depends only on `Relay`), so it is NOT `@testable`-importable. Compile `HookTransportClient.swift` (one source file) into BOTH the `RelayHook` and `Relay` targets in `project.yml`, and have the test do `@testable import Relay`. Do not add a new scheme.

- [ ] **Step 1: Failing tests.** Add a test that stands up a local `AF_UNIX` server which (a) does not exist, (b) accepts but never `read()`s, and asserts the client returns within the deadline in every case, never throwing past ~600 ms.

```swift
import XCTest
@testable import Relay   // HookTransportClient is compiled into Relay too (see Files > Testability)

final class HookTransportClientTests: XCTestCase {
    func testMissingSocketReturnsQuicklyWithoutThrowingUpward() {
        let start = Date()
        let client = HookTransportClient(socketPath: "/tmp/relay-nonexistent-\(UUID().uuidString).sock",
                                         totalDeadline: 0.4)
        // Deliberately no server. Delivery must fail fast, not hang.
        _ = client.send(Data("{}".utf8))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testPeerThatNeverReadsDoesNotBlockPastDeadline() throws {
        let path = "/tmp/relay-slowpeer-\(UUID().uuidString).sock"
        let server = TestAcceptOnlyServer(path: path) // accepts, never reads
        defer { server.stop() }
        let start = Date()
        let client = HookTransportClient(socketPath: path, totalDeadline: 0.4)
        _ = client.send(Data(repeating: 0x41, count: 2 * 1024 * 1024)) // big enough to fill buffers
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }
}
```

(Write `TestAcceptOnlyServer` as a small helper that `socket`/`bind`/`listen`/`accept`s on a background queue and never reads — mirror the socket setup in `UnixSocketServer`.)

- [ ] **Step 2: Run — verify fail** (hangs today or `HookTransportClient(socketPath:totalDeadline:)` undefined).

- [ ] **Step 3: Implement.**
  - `HookTransportClient`: create the socket, set `O_NONBLOCK` (`fcntl`), `SO_NOSIGPIPE`. `connect()` returns `EINPROGRESS`; `poll(POLLOUT)` with the remaining budget. Then write in a loop, each iteration `poll(POLLOUT)` with the remaining budget, `write()`, subtract elapsed. If the total deadline (250–500 ms; default 400 ms) elapses at any point → give up cleanly. Add `init(socketPath:totalDeadline:)` and a `send(_:) -> Bool` returning delivered/undelivered.
  - `main.swift`: replace `readStandardInputToEOF()` with a chunked bounded reader that reads at most `maxInputBytes + 1` bytes and stops early; if it exceeds `maxInputBytes`, reject (exit success, deliver nothing). Never buffer more than the cap.

- [ ] **Step 4: Run — verify pass.** Expected: both tests PASS, each well under 1 s. (Testability is handled per the Files > Testability note: `HookTransportClient.swift` compiled into both `RelayHook` and `Relay`, test uses `@testable import Relay`.)

- [ ] **Step 5: Commit**

```bash
git add RelayHook/HookTransportClient.swift RelayHook/main.swift \
  RelayTests/Integrations/HookTransportClientTests.swift project.yml
git commit -m "fix(hook): bound RelayHook connect/write with a total deadline and cap stdin"
```

**Acceptance:** a broken/hung Relay cannot stall the coding agent beyond the deadline; RelayHook exits success whether Relay runs or not; stdin memory is bounded; tests cover missing socket, accept-but-never-read, oversized payload.

---

## Task 3: Harden socket ownership / restart

**The bug:** `Relay/Integrations/Transport/UnixSocketServer.swift` — `start()` calls `removeStaleSocketIfSafe(at:)` (line 103). That helper (lines 322-342) unlinks the path when it is a socket owned by the current user, with **no probe** for a live listener and **no** single-instance guard. A second Relay launch unlinks the first's live socket and rebinds → the first process keeps a dead listener; integrations silently stop.

**The fix:** before unlink, probe-connect. If a live peer answers, do not unlink — surface "active owner" and refuse to start (or let the caller decide). Only unlink a stale/refused socket. Add an explicit single-instance guard via `flock` on a lockfile so two Relays can never both believe they own the socket.

**Files:**
- Modify: `Relay/Integrations/Transport/UnixSocketServer.swift` (add probe + new error cases; add lockfile guard)
- Test: `RelayTests/Integrations/UnixSocketServerOwnershipTests.swift` (create)

- [ ] **Step 1: Failing tests.**
  - `testProbeDetectsLiveListenerAndRefusesToUnlink`: start server A on a temp path; attempt `removeStaleSocketIfSafe`-equivalent → must NOT unlink; A's socket still accepts.
  - `testStaleSocketAfterCrashIsRecovered`: create a socket file with no listener (bind+close, or leftover) → probe fails → safe to remove → second start succeeds.
  - `testForeignNonSocketPathNeverDeleted`: put a regular file at the path → `unsafeStaleSocket`, file still present.
  - `testSecondInstanceCannotStartWhileFirstListens`: A `start()`s; B `start()` on same path throws the new "active owner" error; A still listening.

- [ ] **Step 2: Run — verify fail** (today B silently hijacks A).

- [ ] **Step 3: Implement.**
  - Add a private `static func probeLiveListener(at path: String) -> Bool` that `socket`/`connect`s (non-blocking + short `poll`, ~200 ms) to the path; `true` if connect succeeds.
  - In `removeStaleSocketIfSafe`: after confirming `isSocket && ownedByCurrentUser`, call `probeLiveListener`. If `true`, throw a new `UnixSocketServerError.activeListenerPresent` (do NOT unlink). If `false`, unlink as today.
  - Add a lockfile guard: `flock(LOCK_EX | LOCK_NB)` on `<socketDir>/relay.lock` held for the server's lifetime; if the lock is already held, throw `.activeListenerPresent`. Store the lock fd and close it in teardown.
  - Diagnostics must distinguish (privacy-safe, structural): active owner, stale socket removed, unsafe path, permission failure. Reuse the existing `IntegrationDiagnosticsLog` categories.

- [ ] **Step 4: Run — verify pass.** Full suite green.

- [ ] **Step 5: Commit**

```bash
git add Relay/Integrations/Transport/UnixSocketServer.swift \
  RelayTests/Integrations/UnixSocketServerOwnershipTests.swift
git commit -m "fix(socket): probe for a live listener and add single-instance guard before unlink"
```

**Acceptance:** starting Relay twice never damages the first; crash leftovers recover; foreign/non-socket paths are never deleted; diagnostics distinguish the four cases.

---

## Task 4: Prune agent sessions (process-liveness + TTL)

**The bug:** `Relay/Sessions/AgentSessionRegistry.swift` — the only removal is `removeAll()` (line 32). `upsert` (lines 6-24) only inserts/replaces; `lastActivityAt` (line 20) is used only to sort in `sessions()` (line 29). The registry grows unbounded; a dead agent's session lingers and makes generic-terminal focus permanently ambiguous.

**The fix:** prune sessions whose process is no longer alive, or whose inactivity exceeds a TTL (default 20 min). Prune before focus resolution.

**Files:**
- Modify: `Relay/Sessions/AgentSessionRegistry.swift` (add `prune(now:isAlive:)` and a per-id `remove`)
- Modify: `Relay/Sessions/AgentAutoReadCoordinator.swift:99` — the auto-read focus decision gathers its session list here (`let sessions = await registry.sessions()` → `focus.focusedSession(among: sessions)`). Prune immediately before this call. (Note: `FocusResolutionService.resolve()` reads `registry.sessions()` at line 24 only to build comparison context and never sees the coordinator's gathered list — pruning only there would NOT remove dead sessions from the actual decision. Other reads exist at `AppModel.swift:716,948`.) Prefer pruning at the coordinator entry, or centralize so every focus-relevant call site sees a pruned registry.
- Test: `RelayTests/Sessions/AgentSessionRegistryPruneTests.swift` (create)

- [ ] **Step 1: Failing tests.**

```swift
func testPruneRemovesDeadProcessSessions() async {
    let registry = AgentSessionRegistry()
    // upsert one session with processAncestry [111], one with [222]
    // prune with isAlive = { pid in pid != 111 } -> only 222 remains
}
func testPruneRemovesSessionsPastTTL() async {
    // upsert with lastActivityAt far in the past; prune(now:) with ttl -> removed
}
func testPruneKeepsFreshLiveSessions() async { /* stays */ }
```

- [ ] **Step 2: Run — verify fail** (`prune` undefined).

- [ ] **Step 3: Implement** in `AgentSessionRegistry`:

```swift
/// Default inactivity TTL before a session is considered stale.
static let defaultTTL: TimeInterval = 20 * 60

func remove(id: AgentSessionID) { values[id] = nil }

/// Drops sessions whose root process is dead or whose inactivity exceeds `ttl`.
/// `isAlive` is `@Sendable` and injected (production passes a
/// ProcessInspector-backed check) so this stays testable without touching the
/// real process table and satisfies Swift 6 strict concurrency across the actor
/// boundary.
func prune(now: Date = Date(), ttl: TimeInterval = AgentSessionRegistry.defaultTTL,
           isAlive: @Sendable (Int32) -> Bool) {
    for (id, session) in values {
        let rootPID = session.processAncestry.first
        let dead = rootPID.map { !isAlive($0) } ?? false
        let expired = now.timeIntervalSince(session.lastActivityAt) > ttl
        if dead || expired { values[id] = nil }
    }
}
```

At the `AgentAutoReadCoordinator` entry (before `registry.sessions()` at line 99), call `await registry.prune(isAlive:)`. **Capture ONE `ProcessInspector.snapshot()` and close over it** so `isAlive` is `{ pid in snapshot.record(pid: pid) != nil }` — do NOT call `snapshot()` per PID (that would launch N subprocesses per prune). If the snapshot throws, skip pruning this cycle (fail safe: keep sessions rather than wrongly dropping live ones).

- [ ] **Step 4: Run — verify pass.** Full suite green.

- [ ] **Step 5: Commit**

```bash
git add Relay/Sessions/AgentSessionRegistry.swift \
  Relay/Sessions/AgentAutoReadCoordinator.swift \
  RelayTests/Sessions/AgentSessionRegistryPruneTests.swift
git commit -m "fix(sessions): prune dead and expired agent sessions before focus resolution"
```

**Acceptance:** dead-process sessions and TTL-expired sessions disappear; pruning runs before every focus decision; historical sessions cannot poison focus.

---

## Task 5: Install `RelayHook` at a stable path, with migration

**The bug:** `Relay/Integrations/ClaudeCode/ClaudeCodeInstaller.swift:55-60` (`defaultHelperPath()`) and `Relay/Integrations/Codex/CodexInstaller.swift` (~lines 76-80) point the hook command at `Bundle.main.bundleURL/Contents/Helpers/RelayHook` — an app-bundle absolute path that dies on rebuild/move/DerivedData change. Detection `isRelayOwnedCommand` (Claude lines 67-73) matches by basename `RelayHook` + `--provider …` suffix regardless of path, so `status()` reports "installed" and `install()` no-ops (lines 91-97) even when the recorded absolute path is dead. Net: the hook silently fails to run and a re-`install()` won't repair it.

**The fix:** on install/update, atomically copy the bundled helper to a stable path `~/Library/Application Support/Relay/bin/RelayHook`, and write *that* path into the Claude/Codex config. On install, migrate an existing Relay-owned entry whose command is not the stable path (rewrite it), rather than no-op'ing on basename match.

**Files:**
- Create: `Relay/Integrations/HelperInstaller.swift` (shared: resolve stable path, copy bundled helper atomically)
- Modify: `Relay/Integrations/ClaudeCode/ClaudeCodeInstaller.swift` (use stable path; migrate on install)
- Modify: `Relay/Integrations/Codex/CodexInstaller.swift` (same)
- Modify: the caller that runs installers (grep `installIntegration` in `Relay/App/AppModel.swift`) to first copy the helper to the stable path
- Test: `RelayTests/Integrations/HelperInstallerTests.swift`, and extend the Claude/Codex installer tests with a migration case

- [ ] **Step 1: Failing tests.**
  - `HelperInstallerTests.testCopiesBundledHelperToStablePathAtomically` (inject source + dest dirs).
  - `ClaudeCodeInstallerTests.testInstallMigratesStaleBundlePathEntryToStablePath`: pre-seed `settings.json` with a Relay-owned entry pointing at a fake bundle path; run `install()` with `helperPath = <stable>`; assert the stored command now equals `"\(stable)" --provider claude-code` and there is exactly one Relay entry.
  - `testNonRelayEntriesUntouched` (already covered — keep).

- [ ] **Step 2: Run — verify fail** (today install no-ops on basename match; command not migrated).

- [ ] **Step 3: Implement.**
  - `HelperInstaller`: `static func stableHelperURL() -> URL` = `~/Library/Application Support/Relay/bin/RelayHook`; `func installBundledHelper(from bundledURL: URL) throws` — create the `bin` dir (0o700), copy to a temp name, `chmod +x`, atomic rename into place. Idempotent.
  - Installers: keep `isRelayOwnedCommand` for *detection*, but in `install()` change the branch: if a Relay-owned entry exists whose command ≠ `relayCommand` (stable path), rewrite it to `relayCommand` instead of no-op. Default `helperPath` becomes `HelperInstaller.stableHelperURL().path`.
  - `AppModel.installIntegration`: call `HelperInstaller().installBundledHelper(from: <Contents/Helpers/RelayHook in the bundle>)` before invoking the per-provider installer, so the stable path always exists when referenced.

- [ ] **Step 4: Run — verify pass.** Full suite green.

- [ ] **Step 5: Commit**

```bash
git add Relay/Integrations/HelperInstaller.swift \
  Relay/Integrations/ClaudeCode/ClaudeCodeInstaller.swift \
  Relay/Integrations/Codex/CodexInstaller.swift \
  Relay/App/AppModel.swift \
  RelayTests/Integrations/HelperInstallerTests.swift \
  RelayTests/Integrations/ClaudeCodeInstallerTests.swift \
  RelayTests/Integrations/CodexInstallerTests.swift
git commit -m "fix(integrations): install RelayHook at a stable Application Support path and migrate stale entries"
```

**Acceptance:** app relocation/rebuild cannot break integrations; a stale bundle-path entry is migrated on install; only Relay's own hook entry is ever modified.

---

## Execution

Recommended: **superpowers:subagent-driven-development** — a fresh implementer subagent per task, reviewed between tasks, one commit per task, no two implementers in the tree at once. Task 1 lands the shared runner other work may reuse; Tasks 2–5 are independent and can follow in any order. Run the full suite (`** TEST SUCCEEDED **`, zero warnings) before every commit.

After all five tasks merge, Wave 2 (speech lifecycle) and Wave 3 (simplification + CI) build on top. Guiding rule for every change: prefer removing a state or code path over adding another compensating guard.
