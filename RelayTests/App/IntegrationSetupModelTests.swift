import Foundation
import XCTest
@testable import Relay

/// SAFETY: every test in this file points `ClaudeCodeInstaller`/`CodexInstaller` at a unique
/// temporary directory created in `setUp` and removed in `tearDown`. No test may read or write
/// the real `~/.claude` or `~/.codex` directories. No test may open the real, fixed-path Unix
/// socket at `~/Library/Application Support/Relay/relay.sock` either: `RelayRuntime.testing`
/// defaults the socket path to a unique `/tmp` path per call, so even a test that calls
/// `IntegrationSetupModel.start()` without overriding it can never reach the real socket. Most
/// tests never call `start()` at all — runtime event flow is exercised instead by
/// constructing an `IntegrationManager` directly around a manually driven `AsyncStream`, exactly
/// as `IntegrationManagerTests` does.
@MainActor
final class IntegrationSetupModelTests: XCTestCase {
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

    private func makeClaudeInstaller() -> ClaudeCodeInstaller {
        ClaudeCodeInstaller(
            baseDirectory: tempDirectory.appendingPathComponent("claude", isDirectory: true),
            helperPath: helperPath
        )
    }

    private func makeCodexInstaller() -> CodexInstaller {
        CodexInstaller(
            baseDirectory: tempDirectory.appendingPathComponent("codex", isDirectory: true),
            helperPath: helperPath
        )
    }

    /// A `HelperInstaller` rooted under this test's own temp directory — never the real
    /// `~/Library/Application Support`. Paired by default with `nonexistentBundledHelperURL`
    /// below, so by default it is never actually invoked (matching the production default's
    /// behavior when no app bundle is present, e.g. in a test host).
    private func makeHelperInstaller() -> HelperInstaller {
        HelperInstaller(baseDirectory: tempDirectory.appendingPathComponent("appsupport", isDirectory: true))
    }

    /// A path that never exists, standing in for the production default (`Bundle.main` inside
    /// a test host normally has no `Contents/Helpers/RelayHook`) — `installBundledHelperIfPresent`
    /// no-ops whenever this doesn't exist.
    private var nonexistentBundledHelperURL: URL {
        tempDirectory.appendingPathComponent("no-such-bundle", isDirectory: true)
            .appendingPathComponent("RelayHook")
    }

    /// The integration-pipeline log every runtime in this file writes to.
    private let integrationLog = IntegrationDiagnosticsLog()

    private func makeRuntime(
        claudeCodeInstaller: ClaudeCodeInstaller? = nil,
        codexInstaller: CodexInstaller? = nil,
        helperInstaller: HelperInstaller? = nil,
        bundledHelperURL: URL? = nil,
        integrationManager: IntegrationManager? = nil,
        hookEnvelopeReceiver: HookEnvelopeReceiver = HookEnvelopeReceiver(),
        hookSocketPath: String? = nil
    ) -> RelayRuntime {
        .testing(
            integrationDiagnosticsLog: integrationLog,
            hookEnvelopeReceiver: hookEnvelopeReceiver,
            integrationManager: integrationManager,
            claudeCodeInstaller: claudeCodeInstaller ?? makeClaudeInstaller(),
            codexInstaller: codexInstaller ?? makeCodexInstaller(),
            helperInstaller: helperInstaller ?? makeHelperInstaller(),
            bundledHelperURL: bundledHelperURL ?? nonexistentBundledHelperURL,
            hookSocketPath: hookSocketPath
        )
    }

    private func makeModel(
        claudeCodeInstaller: ClaudeCodeInstaller? = nil,
        codexInstaller: CodexInstaller? = nil,
        helperInstaller: HelperInstaller? = nil,
        bundledHelperURL: URL? = nil,
        integrationManager: IntegrationManager? = nil,
        hookEnvelopeReceiver: HookEnvelopeReceiver = HookEnvelopeReceiver(),
        hookSocketPath: String? = nil
    ) -> IntegrationSetupModel {
        IntegrationSetupModel(runtime: makeRuntime(
            claudeCodeInstaller: claudeCodeInstaller,
            codexInstaller: codexInstaller,
            helperInstaller: helperInstaller,
            bundledHelperURL: bundledHelperURL,
            integrationManager: integrationManager,
            hookEnvelopeReceiver: hookEnvelopeReceiver,
            hookSocketPath: hookSocketPath
        ))
    }

    // MARK: - Baseline: no test ever touches a real socket

    func testConstructingAModelNeverOpensASocketOrHasStatusListening() {
        let model = makeModel()

        XCTAssertFalse(model.isSocketListening)
        XCTAssertEqual(model.status(for: .claudeCode), .notInstalled)
        XCTAssertEqual(model.status(for: .codex), .notInstalled)
        XCTAssertFalse(model.latestResponseAvailable)
    }

    // MARK: - Claude Code install/uninstall/check drive the real (temp-dir) installer

    func testInstallClaudeCodeIntegrationSucceedsAndRefreshesStatus() {
        let model = makeModel()

        model.install(.claudeCode)

        XCTAssertEqual(model.status(for: .claudeCode), .installedAwaitingFirstEvent)
    }

    func testUninstallClaudeCodeIntegrationRemovesEntryAndRefreshesStatus() {
        let model = makeModel()
        model.install(.claudeCode)
        XCTAssertEqual(model.status(for: .claudeCode), .installedAwaitingFirstEvent)

        model.uninstall(.claudeCode)

        XCTAssertEqual(model.status(for: .claudeCode), .notInstalled)
    }

    func testCheckClaudeCodeIntegrationReflectsCurrentOnDiskState() throws {
        let installer = makeClaudeInstaller()
        let model = makeModel(claudeCodeInstaller: installer)
        XCTAssertEqual(model.status(for: .claudeCode), .notInstalled)

        try installer.install() // simulate a change made outside this AppModel instance

        model.check(.claudeCode)

        XCTAssertEqual(model.status(for: .claudeCode), .installedAwaitingFirstEvent)
    }

    func testInstallClaudeCodeIntegrationWithMalformedSettingsSurfacesConfigurationErrorWithoutCrashing() throws {
        let claudeDirectory = tempDirectory.appendingPathComponent("claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        try #"{"hooks": "not-an-object"}"#.data(using: .utf8)!
            .write(to: claudeDirectory.appendingPathComponent("settings.json"))
        let model = makeModel()

        model.install(.claudeCode)

        guard case .configurationError = model.status(for: .claudeCode) else {
            return XCTFail("expected .configurationError, got \(model.status(for: .claudeCode))")
        }
    }

    // MARK: - installIntegration aborts (never reports "installed") when the bundled helper
    // cannot be made available at its stable path

    /// A bundled helper that DOES exist, but whose stable-path `bin` directory cannot be
    /// created because its parent has no write permission, so `HelperInstaller.
    /// installBundledHelper` throws and leaves nothing behind. `installIntegration` must
    /// surface this as a failure and must NOT go on to write the agent config — a config
    /// pointing at a stable path with nothing runnable there would silently never fire while
    /// `status()` still reported "installed".
    func testInstallSurfacesFailureAndDoesNotWriteConfigWhenBundledHelperCannotReachStablePath() throws {
        let bundleDirectory = tempDirectory.appendingPathComponent("bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleDirectory, withIntermediateDirectories: true)
        let bundledHelperURL = bundleDirectory.appendingPathComponent("RelayHook")
        try "#!/bin/sh\necho hi\n".data(using: .utf8)!.write(to: bundledHelperURL)

        let unwritableBase = tempDirectory.appendingPathComponent("unwritable-appsupport", isDirectory: true)
        try FileManager.default.createDirectory(at: unwritableBase, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: unwritableBase.path)
        defer {
            // Restore write permission before `tearDown` tries to remove `tempDirectory`.
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unwritableBase.path)
        }

        let model = makeModel(
            helperInstaller: HelperInstaller(baseDirectory: unwritableBase),
            bundledHelperURL: bundledHelperURL
        )

        model.install(.claudeCode)

        guard case .configurationError = model.status(for: .claudeCode) else {
            return XCTFail("expected .configurationError, got \(model.status(for: .claudeCode))")
        }
        // The per-provider installer must never have run: no settings.json was written.
        let settingsURL = tempDirectory.appendingPathComponent("claude", isDirectory: true)
            .appendingPathComponent("settings.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsURL.path))
    }

    /// The mirror-image case: a helper already installed at the stable path from an earlier,
    /// successful install is left alone (and install still succeeds) even when THIS
    /// particular refresh copy fails — an already-working install must not start failing over
    /// a transient refresh problem.
    func testInstallSucceedsWhenRefreshFailsButAPreviouslyInstalledHelperIsStillPresent() throws {
        let bundleDirectory = tempDirectory.appendingPathComponent("bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleDirectory, withIntermediateDirectories: true)
        let bundledHelperURL = bundleDirectory.appendingPathComponent("RelayHook")
        try "#!/bin/sh\necho hi\n".data(using: .utf8)!.write(to: bundledHelperURL)

        let appSupportBase = tempDirectory.appendingPathComponent("appsupport", isDirectory: true)
        let helperInstaller = HelperInstaller(baseDirectory: appSupportBase)
        // Simulate a prior successful install.
        try helperInstaller.installBundledHelper(from: bundledHelperURL)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helperInstaller.installedHelperURL.path))

        // Now make the `bin` directory (which already exists from the prior install) read-only,
        // so a subsequent refresh copy fails, while the previously installed helper stays put.
        let binDirectory = helperInstaller.installedHelperURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: binDirectory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binDirectory.path)
        }

        let model = makeModel(helperInstaller: helperInstaller, bundledHelperURL: bundledHelperURL)

        model.install(.claudeCode)

        XCTAssertEqual(model.status(for: .claudeCode), .installedAwaitingFirstEvent)
    }

    // MARK: - Codex install/uninstall/check, including its two special-case messages

    func testInstallCodexIntegrationFlipsToTrustRequired() {
        let model = makeModel()

        model.install(.codex)

        XCTAssertEqual(model.status(for: .codex), .installedTrustRequired)
    }

    func testUninstallCodexIntegrationRemovesEntryAndRefreshesStatus() {
        let model = makeModel()
        model.install(.codex)
        XCTAssertEqual(model.status(for: .codex), .installedTrustRequired)

        model.uninstall(.codex)

        XCTAssertEqual(model.status(for: .codex), .notInstalled)
    }

    func testCodexHooksDisabledInConfigSurfacesConfigurationErrorOnInstallWithoutCrashing() throws {
        let codexDirectory = tempDirectory.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        try "[features]\nhooks = false\n".data(using: .utf8)!
            .write(to: codexDirectory.appendingPathComponent("config.toml"))
        let model = makeModel()

        model.install(.codex)

        XCTAssertEqual(model.status(for: .codex), .configurationError(CodexInstaller.hooksDisabledMessage))
    }

    func testCheckCodexIntegrationSurfacesHooksDisabledMessageWithoutInstalling() throws {
        let codexDirectory = tempDirectory.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        try "[features]\nhooks = false\n".data(using: .utf8)!
            .write(to: codexDirectory.appendingPathComponent("config.toml"))
        let model = makeModel()

        model.check(.codex)

        XCTAssertEqual(model.status(for: .codex), .configurationError(CodexInstaller.hooksDisabledMessage))
    }

    // MARK: - latestAgentResponseAvailable reflects the injected manager

    func testLatestAgentResponseAvailableReflectsTheInjectedManager() async {
        let event = AgentResponseEvent(
            id: UUID(),
            provider: .claudeCode,
            providerSessionID: "session-1",
            text: "All done.",
            cwd: "/Users/me/project",
            parentPID: 100,
            environment: [:],
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let integration = AlwaysSucceedIntegration(provider: .claudeCode, event: event)
        let speech = FakeSpeechCoordinator()
        var continuation: AsyncStream<HookEnvelope>.Continuation!
        let events = AsyncStream<HookEnvelope> { continuation = $0 }
        let manager = IntegrationManager(events: events, integrations: [integration], speechCoordinator: speech)
        let model = AppModel(runtime: makeRuntime(integrationManager: manager))

        XCTAssertFalse(model.integrationSetup.latestResponseAvailable)

        manager.start()
        defer { manager.stop() }
        continuation.yield(HookEnvelope(
            schemaVersion: 1,
            provider: .claudeCode,
            rawPayload: "{}",
            parentPID: 100,
            environment: [:],
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))

        await waitUntil { model.integrationSetup.latestResponseAvailable }
    }

    func testIntegrationStatusPrefersActiveRuntimeStatusOverInstallerStatus() async {
        let claudeInstaller = makeClaudeInstaller()
        let event = AgentResponseEvent(
            id: UUID(),
            provider: .claudeCode,
            providerSessionID: "session-3",
            text: "All done.",
            cwd: "/Users/me/project",
            parentPID: 100,
            environment: [:],
            capturedAt: Date(timeIntervalSince1970: 1_700_000_777)
        )
        let integration = AlwaysSucceedIntegration(provider: .claudeCode, event: event)
        var continuation: AsyncStream<HookEnvelope>.Continuation!
        let events = AsyncStream<HookEnvelope> { continuation = $0 }
        let manager = IntegrationManager(events: events, integrations: [integration], speechCoordinator: FakeSpeechCoordinator())
        let model = makeModel(claudeCodeInstaller: claudeInstaller, integrationManager: manager)

        model.install(.claudeCode)
        XCTAssertEqual(model.status(for: .claudeCode), .installedAwaitingFirstEvent)

        manager.start()
        defer { manager.stop() }
        continuation.yield(HookEnvelope(
            schemaVersion: 1,
            provider: .claudeCode,
            rawPayload: "{}",
            parentPID: 100,
            environment: [:],
            capturedAt: event.capturedAt
        ))

        await waitUntil { model.status(for: .claudeCode) == .active(lastEventAt: event.capturedAt) }
    }

    // MARK: - Fix 1: the socket indicator stays authoritative after start

    func testStartIntegrationsCalledTwiceKeepsSocketListeningTrueDespiteAlreadyStartedThrow() throws {
        let receiver = HookEnvelopeReceiver()
        let socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path
        // Pre-start the receiver on a TEMP path. `UnixSocketServer.start` rejects a second
        // `start` on an already-listening instance (`.alreadyStarted`) before it ever touches
        // the path passed to it — so the calls below never open, bind, or unlink anything,
        // regardless of `makeModel`'s (already non-production) default `hookSocketPath`.
        try receiver.start(path: socketPath)
        defer { receiver.stop() }
        let model = makeModel(hookEnvelopeReceiver: receiver)

        model.start() // throws .alreadyStarted internally; caught
        XCTAssertTrue(model.isSocketListening)

        model.start() // throws .alreadyStarted again
        XCTAssertTrue(model.isSocketListening)
        // A redundant start is not a problem worth reporting.
        XCTAssertNil(model.socketStatusMessage)
        XCTAssertFalse(integrationLog.snapshot().contains { $0.stage == "socket-start" })
    }

    /// Uses a short `/tmp` path (a unix socket path must fit in `sun_path`, 104 bytes) that is
    /// never the production socket. A second `UnixSocketServer` already holds that directory's
    /// single-instance lock, standing in for another running Relay.
    func testAnotherInstanceOwningTheSocketIsSurfacedAndRecorded() throws {
        let directory = "/tmp/relay-it-\(UUID().uuidString.prefix(8))"
        let socketPath = "\(directory)/relay.sock"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let otherInstance = UnixSocketServer()
        try otherInstance.start(path: socketPath) { _ in }
        defer { otherInstance.stop() }
        let model = makeModel(hookSocketPath: socketPath)

        model.start()

        XCTAssertFalse(model.isSocketListening)
        XCTAssertEqual(model.socketStatusMessage, IntegrationSetupModel.anotherInstanceOwnsSocketMessage)
        XCTAssertTrue(integrationLog.snapshot().contains {
            $0.stage == "socket-start" && $0.outcome == "failed" && $0.detail == "active-listener-present"
        })
    }

    // MARK: - Launch-time helper refresh

    private func startedTempReceiver() throws -> HookEnvelopeReceiver {
        let receiver = HookEnvelopeReceiver()
        try receiver.start(path: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path)
        return receiver
    }

    private func writeBundledHelper(_ script: String) throws -> URL {
        let bundleDirectory = tempDirectory.appendingPathComponent("bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleDirectory, withIntermediateDirectories: true)
        let bundledHelperURL = bundleDirectory.appendingPathComponent("RelayHook")
        try Data(script.utf8).write(to: bundledHelperURL)
        return bundledHelperURL
    }

    func testStartIntegrationsRefreshesAStaleStableHelperWhenAProviderIsInstalled() throws {
        let bundledHelperURL = try writeBundledHelper("#!/bin/sh\necho old\n")
        let helperInstaller = makeHelperInstaller()
        try helperInstaller.installBundledHelper(from: bundledHelperURL)
        // An app update ships a new bundled helper; nobody presses Install again.
        try Data("#!/bin/sh\necho new\n".utf8).write(to: bundledHelperURL)
        let claudeInstaller = makeClaudeInstaller()
        try claudeInstaller.install()
        let receiver = try startedTempReceiver()
        defer { receiver.stop() }
        let model = makeModel(
            claudeCodeInstaller: claudeInstaller,
            helperInstaller: helperInstaller,
            bundledHelperURL: bundledHelperURL,
            hookEnvelopeReceiver: receiver
        )

        model.start()

        XCTAssertEqual(
            try Data(contentsOf: helperInstaller.installedHelperURL),
            Data("#!/bin/sh\necho new\n".utf8)
        )
        XCTAssertEqual(model.status(for: .claudeCode), .installedAwaitingFirstEvent)
    }

    func testStartIntegrationsDoesNotInstallAHelperWhenNoProviderIsInstalled() throws {
        let bundledHelperURL = try writeBundledHelper("#!/bin/sh\necho new\n")
        let helperInstaller = makeHelperInstaller()
        let receiver = try startedTempReceiver()
        defer { receiver.stop() }
        let model = makeModel(
            helperInstaller: helperInstaller,
            bundledHelperURL: bundledHelperURL,
            hookEnvelopeReceiver: receiver
        )

        model.start()

        XCTAssertFalse(FileManager.default.fileExists(atPath: helperInstaller.installedHelperURL.path))
    }

    func testStartIntegrationsRecordsAHelperRefreshFailureWithoutThrowing() throws {
        let bundledHelperURL = try writeBundledHelper("#!/bin/sh\necho new\n")
        let unwritableBase = tempDirectory.appendingPathComponent("unwritable-appsupport", isDirectory: true)
        try FileManager.default.createDirectory(at: unwritableBase, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: unwritableBase.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unwritableBase.path)
        }
        let claudeInstaller = makeClaudeInstaller()
        try claudeInstaller.install()
        let receiver = try startedTempReceiver()
        defer { receiver.stop() }
        let model = makeModel(
            claudeCodeInstaller: claudeInstaller,
            helperInstaller: HelperInstaller(baseDirectory: unwritableBase),
            bundledHelperURL: bundledHelperURL,
            hookEnvelopeReceiver: receiver
        )

        model.start()

        XCTAssertTrue(integrationLog.snapshot().contains {
            $0.stage == "helper" && $0.outcome == "refresh-failed" && $0.detail == "stable-helper-unavailable"
        })
        XCTAssertTrue(model.isSocketListening)
    }

    // MARK: - Fix 2: uninstall gives an immediate, truthful status change

    func testUninstallAfterRuntimeActiveReportsNotInstalledInsteadOfStaleActive() async {
        let claudeInstaller = makeClaudeInstaller()
        let event = AgentResponseEvent(
            id: UUID(),
            provider: .claudeCode,
            providerSessionID: "session-4",
            text: "All done.",
            cwd: "/Users/me/project",
            parentPID: 100,
            environment: [:],
            capturedAt: Date(timeIntervalSince1970: 1_700_000_888)
        )
        let integration = AlwaysSucceedIntegration(provider: .claudeCode, event: event)
        var continuation: AsyncStream<HookEnvelope>.Continuation!
        let events = AsyncStream<HookEnvelope> { continuation = $0 }
        let manager = IntegrationManager(events: events, integrations: [integration], speechCoordinator: FakeSpeechCoordinator())
        let model = makeModel(claudeCodeInstaller: claudeInstaller, integrationManager: manager)

        model.install(.claudeCode)
        XCTAssertEqual(model.status(for: .claudeCode), .installedAwaitingFirstEvent)

        manager.start()
        defer { manager.stop() }
        continuation.yield(HookEnvelope(
            schemaVersion: 1,
            provider: .claudeCode,
            rawPayload: "{}",
            parentPID: 100,
            environment: [:],
            capturedAt: event.capturedAt
        ))
        await waitUntil { model.status(for: .claudeCode) == .active(lastEventAt: event.capturedAt) }

        model.uninstall(.claudeCode)

        XCTAssertEqual(model.status(for: .claudeCode), .notInstalled)
        XCTAssertNil(manager.status[.claudeCode])
    }

    /// Polls `condition` on a bounded loop instead of waiting unboundedly.
    private func waitUntil(
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("timed out waiting for condition", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Phase 3 Task 9: `onResponse` wiring reaches `AgentAutoReadCoordinator`
    //
    // These build the SAME shape of graph `RelayRuntime.makeProduction()` wires
    // (an `IntegrationManager` whose `onResponse` forwards to an `AgentAutoReadCoordinator`), but
    // with fakes for focus/speech/process-context standing in for the real resolvers — exactly as
    // `AgentAutoReadCoordinatorTests` does for the coordinator alone. This verifies the wiring
    // itself: a decoded event reaches the coordinator, upserts a session into the registry, and
    // speaks exactly once when focus is stubbed `.focused`/`.high` and auto-read is enabled; a
    // disabled flag or a non-`.focused`/`.high` decision stays silent while still upserting.
    //
    // NOTE: these validate the onResponse -> coordinator wiring SHAPE via this harness, not the
    // production `RelayRuntime.makeProduction()`'s real resolver graph (Herdr/tmux/generic-terminal order,
    // shared frontmost/recent-interaction instances) — that graph is verified by inspection only.
    // `SpeechBackendGraphTests` separately pins the concrete speech backend/manager types
    // `makeProduction()` wires; nothing constructs `makeProduction()` itself in tests, since doing
    // so would touch UserDefaults, the event tap, and the hook socket.

    func testOnResponseWiringSpeaksOnceWhenFocusedHighAndAutoReadEnabled() async {
        let harness = makeAutoReadWiringHarness(
            focus: .focused(resolverID: "stub", reason: "test"),
            autoRead: true
        )
        let model = makeModel(integrationManager: harness.manager)
        harness.manager.start()
        defer { harness.manager.stop() }

        harness.continuation.yield(HookEnvelope(
            schemaVersion: 1,
            provider: .claudeCode,
            rawPayload: "{}",
            parentPID: harness.event.parentPID,
            environment: [:],
            capturedAt: harness.event.capturedAt
        ))

        await waitUntil { !harness.speech.requests.isEmpty }

        XCTAssertEqual(harness.speech.requests.count, 1)
        XCTAssertEqual(harness.speech.requests.first?.mode, .automatic)
        let sessions = await harness.registry.sessions()
        XCTAssertEqual(sessions.first?.latestResponse.text, harness.event.text)
        withExtendedLifetime(model) {}
    }

    func testOnResponseWiringStaysSilentWhenAutoReadDisabled() async {
        let harness = makeAutoReadWiringHarness(
            focus: .focused(resolverID: "stub", reason: "test"),
            autoRead: false
        )
        let model = makeModel(integrationManager: harness.manager)
        harness.manager.start()
        defer { harness.manager.stop() }

        harness.continuation.yield(HookEnvelope(
            schemaVersion: 1,
            provider: .claudeCode,
            rawPayload: "{}",
            parentPID: harness.event.parentPID,
            environment: [:],
            capturedAt: harness.event.capturedAt
        ))

        await waitUntil { model.latestResponseAvailable }

        XCTAssertTrue(harness.speech.requests.isEmpty)
        // `latestAgentResponseAvailable` flips the moment `IntegrationManager.consume()` calls
        // `store.set(event)`, strictly BEFORE it awaits `onResponse` (the coordinator), so the
        // registry upsert can still be in flight here (now one snapshot-fetch await further out
        // than before Task 11's shared-snapshot rework) — poll instead of reading once.
        var sessions = await harness.registry.sessions()
        let deadline = Date().addingTimeInterval(2)
        while sessions.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
            sessions = await harness.registry.sessions()
        }
        XCTAssertEqual(sessions.first?.latestResponse.text, harness.event.text)
    }

    func testOnResponseWiringStaysSilentWhenFocusUnknown() async {
        let harness = makeAutoReadWiringHarness(
            focus: .unknown(resolverID: "stub", reason: "ambiguous"),
            autoRead: true
        )
        let model = makeModel(integrationManager: harness.manager)
        harness.manager.start()
        defer { harness.manager.stop() }

        harness.continuation.yield(HookEnvelope(
            schemaVersion: 1,
            provider: .claudeCode,
            rawPayload: "{}",
            parentPID: harness.event.parentPID,
            environment: [:],
            capturedAt: harness.event.capturedAt
        ))

        await waitUntil { model.latestResponseAvailable }

        XCTAssertTrue(harness.speech.requests.isEmpty)
    }
}

private struct AutoReadWiringHarness {
    let manager: IntegrationManager
    let registry: AgentSessionRegistry
    let speech: RecordingWiringSpeechSink
    let continuation: AsyncStream<HookEnvelope>.Continuation
    let event: AgentResponseEvent
}

@MainActor
private func makeAutoReadWiringHarness(focus: FocusDecision, autoRead: Bool) -> AutoReadWiringHarness {
    let event = AgentResponseEvent(
        id: UUID(),
        provider: .claudeCode,
        providerSessionID: "wiring-session",
        text: "All wired up.",
        cwd: "/Users/me/project",
        parentPID: 100,
        environment: [:],
        // Real wall-clock time, not a fixed historical timestamp: `AgentAutoReadCoordinator`
        // prunes sessions past its default inactivity TTL against `Date()`, and a fixed past
        // date would make this session look stale (and get pruned before focus resolution) no
        // matter how recently the test actually runs.
        capturedAt: Date()
    )
    let integration = AlwaysSucceedIntegration(provider: .claudeCode, event: event)
    let registry = AgentSessionRegistry()
    let speech = RecordingWiringSpeechSink()
    let coordinator = AgentAutoReadCoordinator(
        registry: registry,
        focus: StubWiringSessionFocusResolver(decision: focus),
        preprocess: { $0 },
        speech: speech,
        autoReadEnabled: { autoRead },
        // A real `ProcessInspector()` default would shell out to `/bin/ps` and, finding no live
        // process at the fabricated pid 100, prune the session before focus resolution ever runs
        // — this fake keeps liveness a non-factor for a test that's only exercising the
        // onResponse -> coordinator wiring shape.
        processInspector: ProcessInspector(runner: AllPIDsAliveProcessRunner())
    )
    var continuation: AsyncStream<HookEnvelope>.Continuation!
    let events = AsyncStream<HookEnvelope> { continuation = $0 }
    let manager = IntegrationManager(
        events: events,
        integrations: [integration],
        speechCoordinator: FakeSpeechCoordinator(),
        onResponse: { decoded in await coordinator.handle(decoded) }
    )
    return .init(manager: manager, registry: registry, speech: speech, continuation: continuation, event: event)
}

private struct StubWiringSessionFocusResolver: SessionFocusResolving {
    let decision: FocusDecision
    func resolve(session: AgentSession) async -> FocusDecision { decision }
}

/// `@unchecked Sendable`: `AgentAutoReadCoordinator` requires `any SpeechSubmitting & Sendable`
/// since it calls `speak(_:)` — `@MainActor`-isolated — from its own actor isolation. All mutable
/// state here (`requests`) is touched only from `@MainActor`.
@MainActor
private final class RecordingWiringSpeechSink: SpeechSubmitting, @unchecked Sendable {
    var requests: [SpeechRequest] = []
    func speak(_ request: SpeechRequest) async throws { requests.append(request) }
}

// MARK: - Test doubles

private enum TestError: Error {
    case boom
}

/// A `RelayIntegration` test double that always succeeds with a fixed event, regardless of the
/// envelope's contents.
private struct AlwaysSucceedIntegration: RelayIntegration {
    let provider: AgentProvider
    let event: AgentResponseEvent

    func decode(_ envelope: HookEnvelope) throws -> AgentResponseEvent { event }
}

@MainActor
private final class FakeSpeechCoordinator: SpeechCoordinating {
    private(set) var requests: [SpeechRequest] = []
    let speakError: Error?

    init(speakError: Error? = nil) {
        self.speakError = speakError
    }

    func speak(_ request: SpeechRequest) async throws {
        requests.append(request)
        if let speakError { throw speakError }
    }
    func previewVoice(text: String, backendID: String, options: TTSOptions) async throws {}
    func stop() {}
    func stop(sessionID: UUID) {}
    func replayLast() async throws {}
}
