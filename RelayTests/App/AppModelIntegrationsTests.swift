import Foundation
import XCTest
@testable import Relay

/// SAFETY: every test in this file points `ClaudeCodeInstaller`/`CodexInstaller` at a unique
/// temporary directory created in `setUp` and removed in `tearDown`. No test may read or write
/// the real `~/.claude` or `~/.codex` directories, and no test ever calls
/// `AppModel.startIntegrations()` — that would open the real, fixed-path Unix socket at
/// `~/Library/Application Support/Relay/relay.sock`. Runtime event flow is exercised instead by
/// constructing an `IntegrationManager` directly around a manually driven `AsyncStream`, exactly
/// as `IntegrationManagerTests` does.
@MainActor
final class AppModelIntegrationsTests: XCTestCase {
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

    private func makeModel(
        claudeCodeInstaller: ClaudeCodeInstaller? = nil,
        codexInstaller: CodexInstaller? = nil,
        integrationManager: IntegrationManager? = nil
    ) -> AppModel {
        AppModel(
            settingsStore: FakeSettingsStore(),
            selectionReader: FakeSelectionReader(),
            preprocessor: RulesSpeechPreprocessor(),
            speechCoordinator: FakeSpeechCoordinator(),
            hotkeyManager: FakeHotkeyManager(),
            integrationManager: integrationManager,
            claudeCodeInstaller: claudeCodeInstaller ?? makeClaudeInstaller(),
            codexInstaller: codexInstaller ?? makeCodexInstaller()
        )
    }

    // MARK: - Baseline: no test ever touches a real socket

    func testConstructingAModelNeverOpensASocketOrHasStatusListening() {
        let model = makeModel()

        XCTAssertFalse(model.isSocketListening)
        XCTAssertEqual(model.integrationStatus(for: .claudeCode), .notInstalled)
        XCTAssertEqual(model.integrationStatus(for: .codex), .notInstalled)
        XCTAssertFalse(model.latestAgentResponseAvailable)
    }

    // MARK: - Claude Code install/uninstall/check drive the real (temp-dir) installer

    func testInstallClaudeCodeIntegrationSucceedsAndRefreshesStatus() {
        let model = makeModel()

        model.installIntegration(.claudeCode)

        XCTAssertEqual(model.integrationStatus(for: .claudeCode), .installedAwaitingFirstEvent)
    }

    func testUninstallClaudeCodeIntegrationRemovesEntryAndRefreshesStatus() {
        let model = makeModel()
        model.installIntegration(.claudeCode)
        XCTAssertEqual(model.integrationStatus(for: .claudeCode), .installedAwaitingFirstEvent)

        model.uninstallIntegration(.claudeCode)

        XCTAssertEqual(model.integrationStatus(for: .claudeCode), .notInstalled)
    }

    func testCheckClaudeCodeIntegrationReflectsCurrentOnDiskState() throws {
        let installer = makeClaudeInstaller()
        let model = makeModel(claudeCodeInstaller: installer)
        XCTAssertEqual(model.integrationStatus(for: .claudeCode), .notInstalled)

        try installer.install() // simulate a change made outside this AppModel instance

        model.checkIntegration(.claudeCode)

        XCTAssertEqual(model.integrationStatus(for: .claudeCode), .installedAwaitingFirstEvent)
    }

    func testInstallClaudeCodeIntegrationWithMalformedSettingsSurfacesConfigurationErrorWithoutCrashing() throws {
        let claudeDirectory = tempDirectory.appendingPathComponent("claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        try #"{"hooks": "not-an-object"}"#.data(using: .utf8)!
            .write(to: claudeDirectory.appendingPathComponent("settings.json"))
        let model = makeModel()

        model.installIntegration(.claudeCode)

        guard case .configurationError = model.integrationStatus(for: .claudeCode) else {
            return XCTFail("expected .configurationError, got \(model.integrationStatus(for: .claudeCode))")
        }
    }

    // MARK: - Codex install/uninstall/check, including its two special-case messages

    func testInstallCodexIntegrationFlipsToTrustRequired() {
        let model = makeModel()

        model.installIntegration(.codex)

        XCTAssertEqual(model.integrationStatus(for: .codex), .installedTrustRequired)
    }

    func testUninstallCodexIntegrationRemovesEntryAndRefreshesStatus() {
        let model = makeModel()
        model.installIntegration(.codex)
        XCTAssertEqual(model.integrationStatus(for: .codex), .installedTrustRequired)

        model.uninstallIntegration(.codex)

        XCTAssertEqual(model.integrationStatus(for: .codex), .notInstalled)
    }

    func testCodexHooksDisabledInConfigSurfacesConfigurationErrorOnInstallWithoutCrashing() throws {
        let codexDirectory = tempDirectory.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        try "[features]\nhooks = false\n".data(using: .utf8)!
            .write(to: codexDirectory.appendingPathComponent("config.toml"))
        let model = makeModel()

        model.installIntegration(.codex)

        XCTAssertEqual(model.integrationStatus(for: .codex), .configurationError(CodexInstaller.hooksDisabledMessage))
    }

    func testCheckCodexIntegrationSurfacesHooksDisabledMessageWithoutInstalling() throws {
        let codexDirectory = tempDirectory.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        try "[features]\nhooks = false\n".data(using: .utf8)!
            .write(to: codexDirectory.appendingPathComponent("config.toml"))
        let model = makeModel()

        model.checkIntegration(.codex)

        XCTAssertEqual(model.integrationStatus(for: .codex), .configurationError(CodexInstaller.hooksDisabledMessage))
    }

    // MARK: - latestAgentResponseAvailable / speakLatestAgentResponse delegate to the injected manager

    func testLatestAgentResponseAvailableReflectsTheInjectedManagerAndSpeakLatestDelegatesToItsCoordinator() async {
        let event = AgentResponseEvent(
            id: UUID(),
            provider: .claudeCode,
            providerSessionID: "session-1",
            turnID: nil,
            text: "All done.",
            cwd: "/Users/me/project",
            transcriptPath: nil,
            parentPID: 100,
            environment: [:],
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let integration = AlwaysSucceedIntegration(provider: .claudeCode, event: event)
        let speech = FakeSpeechCoordinator()
        var continuation: AsyncStream<HookEnvelope>.Continuation!
        let events = AsyncStream<HookEnvelope> { continuation = $0 }
        let manager = IntegrationManager(events: events, integrations: [integration], speechCoordinator: speech)
        let model = makeModel(integrationManager: manager)

        XCTAssertFalse(model.latestAgentResponseAvailable)

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

        await waitUntil { model.latestAgentResponseAvailable }

        await model.speakLatestAgentResponse()

        XCTAssertEqual(speech.requests.count, 1)
        XCTAssertEqual(speech.requests.first?.source, .claudeCode)
        XCTAssertEqual(speech.requests.first?.mode, .userRequested)
        XCTAssertEqual(model.statusText, "Speaking latest agent response")
    }

    func testSpeakLatestAgentResponseFailureIsCaughtAndSurfacedWithoutCrashing() async {
        let event = AgentResponseEvent(
            id: UUID(),
            provider: .codex,
            providerSessionID: "session-2",
            turnID: "turn-1",
            text: "Done.",
            cwd: "/Users/me/project",
            transcriptPath: nil,
            parentPID: 100,
            environment: [:],
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let store = LatestAgentResponseStore()
        await store.set(event)
        let speech = FakeSpeechCoordinator(speakError: TestError.boom)
        let events = AsyncStream<HookEnvelope> { _ in }
        let manager = IntegrationManager(events: events, integrations: [], store: store, speechCoordinator: speech)
        let model = makeModel(integrationManager: manager)

        await model.speakLatestAgentResponse()

        XCTAssertEqual(model.statusText, "Could not speak the latest agent response.")
    }

    func testIntegrationStatusPrefersActiveRuntimeStatusOverInstallerStatus() async {
        let claudeInstaller = makeClaudeInstaller()
        let event = AgentResponseEvent(
            id: UUID(),
            provider: .claudeCode,
            providerSessionID: "session-3",
            turnID: nil,
            text: "All done.",
            cwd: "/Users/me/project",
            transcriptPath: nil,
            parentPID: 100,
            environment: [:],
            capturedAt: Date(timeIntervalSince1970: 1_700_000_777)
        )
        let integration = AlwaysSucceedIntegration(provider: .claudeCode, event: event)
        var continuation: AsyncStream<HookEnvelope>.Continuation!
        let events = AsyncStream<HookEnvelope> { continuation = $0 }
        let manager = IntegrationManager(events: events, integrations: [integration], speechCoordinator: FakeSpeechCoordinator())
        let model = makeModel(claudeCodeInstaller: claudeInstaller, integrationManager: manager)

        model.installIntegration(.claudeCode)
        XCTAssertEqual(model.integrationStatus(for: .claudeCode), .installedAwaitingFirstEvent)

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

        await waitUntil { model.integrationStatus(for: .claudeCode) == .active(lastEventAt: event.capturedAt) }
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
private final class FakeSettingsStore: SettingsStoring {
    func load() -> AppSettings { .defaults }
    func save(_ value: AppSettings) throws {}
}

@MainActor
private final class FakeSelectionReader: SelectionReading {
    func readSelection() throws -> SelectionResult { .init(text: "selected", source: .accessibility) }
}

@MainActor
private final class FakeHotkeyManager: HotkeyManaging {
    func register(
        settings: AppSettings,
        handler: @escaping @MainActor (HotkeyAction, HotkeyPhase) -> Void
    ) -> HotkeyRegistrationStatus {
        .registered
    }
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
    func stop() {}
    func stop(sessionID: UUID) {}
    func replayLast() async throws {}
}
