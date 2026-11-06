import SwiftUI

struct IntegrationsSettingsView: View {
    @Bindable var model: AppModel
    @State private var agentSessions: [IntegrationSetupModel.AgentSessionSummary] = []

    var body: some View {
        Form {
            Section("Socket") {
                HStack {
                    Text(model.integrationSetup.isSocketListening ? "Listening" : "Not listening")
                        .foregroundStyle(model.integrationSetup.isSocketListening ? .green : .orange)
                    Spacer()
                    Text(model.integrationSetup.socketPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let message = model.integrationSetup.socketStatusMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            ForEach(AgentProvider.allCases, id: \.self) { provider in
                Section(provider.displayName) {
                    integrationRow(for: provider)
                }
            }

            Section("Agent responses") {
                Toggle(
                    isOn: Binding(
                        get: { model.settings.autoReadEnabled },
                        set: { model.settingsController.setAutoReadEnabled($0) }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automatically speak confidently focused Claude/Codex sessions")
                        Text("Background or ambiguous sessions stay silent.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Agent Sessions") {
                if agentSessions.isEmpty {
                    Text("No agent sessions yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(agentSessions) { session in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(session.provider.displayName)
                                Spacer()
                                Text(session.lastActivityAt, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(session.cwd)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                Button("Refresh") { Task { agentSessions = await model.integrationSetup.agentSessionSummaries() } }
            }
        }
        .formStyle(.grouped)
        .task {
            model.integrationSetup.check(.claudeCode)
            model.integrationSetup.check(.codex)
            agentSessions = await model.integrationSetup.agentSessionSummaries()
        }
    }

    @ViewBuilder
    private func integrationRow(for provider: AgentProvider) -> some View {
        let status = model.integrationSetup.status(for: provider)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(Self.statusLabel(status))
                    .foregroundStyle(Self.statusColor(status))
                Spacer()
                Button("Install") { model.integrationSetup.install(provider) }
                Button("Uninstall") { model.integrationSetup.uninstall(provider) }
                Button("Check") { model.integrationSetup.check(provider) }
            }
            if let detail = Self.statusDetail(status) {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func statusLabel(_ status: IntegrationStatus) -> String {
        switch status {
        case .notInstalled: "Not installed"
        case .installedAwaitingFirstEvent: "Installed, awaiting first event"
        case .installedTrustRequired: "Trust required"
        case .active: "Active"
        case .configurationError: "Configuration error"
        }
    }

    private static func statusColor(_ status: IntegrationStatus) -> Color {
        switch status {
        case .notInstalled: .secondary
        case .installedAwaitingFirstEvent: .orange
        case .installedTrustRequired: .orange
        case .active: .green
        case .configurationError: .red
        }
    }

    /// Extra guidance shown under the status label.
    private static func statusDetail(_ status: IntegrationStatus) -> String? {
        switch status {
        case .installedTrustRequired:
            CodexInstaller.trustRequiredMessage
        case let .configurationError(message):
            message
        default:
            nil
        }
    }
}
