import Foundation
import Observation
import os

/// Thrown by `IntegrationSetupModel.installBundledHelperIfPresent` when, after attempting to
/// refresh the bundled `RelayHook` helper at its stable Application Support path, there is still
/// no valid (present and executable) helper there. `install(_:)` surfaces it as
/// `.configurationError` instead of writing an agent config that points at nothing runnable.
enum HelperInstallVerificationError: Error, Sendable {
    case stableHelperUnavailable
}

/// Agent-integration setup for the Integrations tab and app lifecycle: the hook socket, the
/// per-provider Stop-hook installers, the stable helper, and the compact session list.
@MainActor
@Observable
final class IntegrationSetupModel {
    /// Compact, privacy-safe metadata for one ephemeral agent session: provider, cwd, last
    /// activity. Never response text, never a focus verdict.
    struct AgentSessionSummary: Identifiable, Equatable, Sendable {
        let id: AgentSessionID
        let cwd: String
        let lastActivityAt: Date

        var provider: AgentProvider { id.provider }
    }

    static let anotherInstanceOwnsSocketMessage =
        "Another Relay instance is already listening for agent hooks. Quit it, then relaunch Relay."
    static let socketStartFailedMessage =
        "Relay could not open the agent hook socket. See Diagnostics for details."

    /// Only ever flipped by `start()`/`stop()`, called from the real app lifecycle.
    private(set) var isSocketListening = false
    /// Why the hook socket could not be opened, when the user can act on it. `nil` while
    /// listening, and before `start()` has run.
    private(set) var socketStatusMessage: String?
    /// Install-time status per provider; `status(for:)` merges it with the manager's runtime status.
    private(set) var installerStatuses: [AgentProvider: IntegrationStatus] = [:]

    /// Where `start()` opens the hook socket (`IntegrationServices.productionSocketPath` in the
    /// app, a temp path in tests). Shown in Integrations settings.
    @ObservationIgnored let socketPath: String
    @ObservationIgnored private let services: IntegrationServices
    @ObservationIgnored private let sessionRegistry: AgentSessionRegistry
    @ObservationIgnored private let integrationDiagnosticsLog: IntegrationDiagnosticsLog
    @ObservationIgnored private let installerLogger = Logger(subsystem: "dev.relaymac.Relay", category: "integrations")

    init(runtime: RelayRuntime) {
        services = runtime.integrations
        socketPath = runtime.integrations.socketPath
        sessionRegistry = runtime.sessions.registry
        integrationDiagnosticsLog = runtime.integrationDiagnosticsLog
    }

    /// Whether an ephemeral latest agent response is available to speak.
    var latestResponseAvailable: Bool {
        services.integrationManager.latestResponse != nil
    }

    /// Called ONLY from `RelayAppDelegate.applicationDidFinishLaunching`; never from an
    /// initializer, so constructing the model in a test never opens a socket. A start failure
    /// never crashes: `.alreadyStarted` (a redundant call) is ignored; anything else is recorded
    /// in `integrationDiagnosticsLog` and surfaced through `socketStatusMessage`.
    /// `isSocketListening` is always read back from the receiver afterward. Then re-reads each
    /// provider's install status and refreshes the stable `RelayHook` helper when needed.
    func start() {
        do {
            try services.hookEnvelopeReceiver.start(path: socketPath)
            socketStatusMessage = nil
        } catch UnixSocketServerError.alreadyStarted {
            // A redundant call while the receiver already listens: nothing to report.
        } catch {
            let label = (error as? UnixSocketServerError)?.diagnosticsLabel ?? "unexpected-error"
            integrationDiagnosticsLog.append(stage: "socket-start", outcome: "failed", detail: label)
            socketStatusMessage = Self.socketStartFailureMessage(for: error)
        }
        isSocketListening = services.hookEnvelopeReceiver.isListening
        services.integrationManager.start()
        refreshInstalledHelperIfNeeded()
    }

    /// Called ONLY from `RelayAppDelegate.applicationWillTerminate`.
    func stop() {
        services.integrationManager.stop()
        services.hookEnvelopeReceiver.stop()
        isSocketListening = false
    }

    /// The manager's live `.active` status when present, else the last install-time status.
    func status(for provider: AgentProvider) -> IntegrationStatus {
        if let runtimeStatus = services.integrationManager.status[provider], case .active = runtimeStatus {
            return runtimeStatus
        }
        return installerStatuses[provider] ?? .notInstalled
    }

    /// Refreshes the stable helper first; the config is never written pointing at nothing runnable.
    func install(_ provider: AgentProvider) {
        do {
            try installBundledHelperIfPresent()
            switch provider {
            case .claudeCode: try services.claudeCodeInstaller.install()
            case .codex: try services.codexInstaller.install()
            }
            check(provider)
        } catch {
            installerStatuses[provider] = Self.configurationErrorStatus(for: provider, error: error)
        }
    }

    /// Also clears the provider's runtime status so a stale `.active` can't outlive the uninstall.
    func uninstall(_ provider: AgentProvider) {
        do {
            switch provider {
            case .claudeCode: try services.claudeCodeInstaller.uninstall()
            case .codex: try services.codexInstaller.uninstall()
            }
            services.integrationManager.clearRuntimeStatus(for: provider)
            check(provider)
        } catch {
            installerStatuses[provider] = Self.configurationErrorStatus(for: provider, error: error)
        }
    }

    func check(_ provider: AgentProvider) {
        do {
            switch provider {
            case .claudeCode: installerStatuses[provider] = try services.claudeCodeInstaller.status()
            case .codex: installerStatuses[provider] = try services.codexInstaller.status()
            }
        } catch {
            installerStatuses[provider] = Self.configurationErrorStatus(for: provider, error: error)
        }
    }

    /// Most-recently-active first. Diagnostics display only; never persisted.
    func agentSessionSummaries() async -> [AgentSessionSummary] {
        await sessionRegistry.sessions().map {
            AgentSessionSummary(id: $0.id, cwd: $0.cwd, lastActivityAt: $0.lastActivityAt)
        }
    }

    // MARK: Private

    /// Keeps the stable-path `RelayHook` copy in step with the helper bundled in THIS build, but
    /// only when at least one provider's config points hooks at it. Never throws: a failure is
    /// recorded in `integrationDiagnosticsLog`, and a previously installed helper stays.
    private func refreshInstalledHelperIfNeeded() {
        for provider in AgentProvider.allCases {
            check(provider)
        }
        guard AgentProvider.allCases.contains(where: { Self.hooksInstalled(installerStatuses[$0]) }) else {
            return
        }
        do {
            try installBundledHelperIfPresent()
        } catch {
            integrationDiagnosticsLog.append(stage: "helper", outcome: "refresh-failed", detail: "stable-helper-unavailable")
        }
    }

    private static func hooksInstalled(_ status: IntegrationStatus?) -> Bool {
        switch status {
        case .installedAwaitingFirstEvent, .installedTrustRequired, .active:
            true
        case .notInstalled, .configurationError, nil:
            false
        }
    }

    /// Copies the bundled helper to its stable path (no-op when this build ships none), then
    /// verifies something executable is there; throws `HelperInstallVerificationError` if not.
    private func installBundledHelperIfPresent() throws {
        let bundledHelperURL = services.bundledHelperURL
        guard FileManager.default.fileExists(atPath: bundledHelperURL.path) else { return }

        let fileManager = FileManager.default
        let installedHelperPath = services.helperInstaller.installedHelperURL.path
        let hadValidStableHelperBefore = fileManager.isExecutableFile(atPath: installedHelperPath)

        do {
            try services.helperInstaller.installBundledHelper(from: bundledHelperURL)
            integrationDiagnosticsLog.append(stage: "helper", outcome: "refreshed", detail: "")
        } catch {
            if hadValidStableHelperBefore {
                installerLogger.log("bundled RelayHook helper refresh failed; a previously installed helper is still present")
            } else {
                installerLogger.log("bundled RelayHook helper refresh failed")
            }
            integrationDiagnosticsLog.append(
                stage: "helper",
                outcome: "refresh-failed",
                detail: hadValidStableHelperBefore ? "previous-helper-kept" : "copy-failed"
            )
        }

        guard fileManager.isExecutableFile(atPath: installedHelperPath) else {
            installerLogger.log("stable RelayHook helper unavailable after refresh; aborting hook install")
            throw HelperInstallVerificationError.stableHelperUnavailable
        }
    }

    private static func socketStartFailureMessage(for error: Error) -> String {
        if case UnixSocketServerError.activeListenerPresent = error {
            return anotherInstanceOwnsSocketMessage
        }
        return socketStartFailedMessage
    }

    /// Never includes the underlying error's text (it may carry paths or content).
    private static func configurationErrorStatus(for provider: AgentProvider, error: Error) -> IntegrationStatus {
        if provider == .codex, case IntegrationInstallerError.hooksDisabledInConfig = error {
            return .configurationError(CodexInstaller.hooksDisabledMessage)
        }
        switch provider {
        case .claudeCode: return .configurationError("Could not update the Claude Code integration.")
        case .codex: return .configurationError("Could not update the Codex integration.")
        }
    }
}
