import SwiftUI

struct IntegrationsSettingsView: View {
    @Bindable var model: AppModel
    @State private var agentSessions: [AppModel.AgentSessionSummary] = []

    var body: some View {
        Form {
            Section("Socket") {
                HStack {
                    Text(model.isSocketListening ? "Listening" : "Not listening")
                        .foregroundStyle(model.isSocketListening ? .green : .orange)
                    Spacer()
                    Text(AppModel.integrationSocketPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("Claude Code") {
                integrationRow(for: .claudeCode)
            }

            Section("Codex") {
                integrationRow(for: .codex)
            }

            Section("Agent responses") {
                Toggle(isOn: Binding(
                    get: { model.settings.autoReadEnabled },
                    set: { model.setAutoReadEnabled($0) }
                )) {
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
                                Text(Self.providerLabel(session.provider))
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
                Button("Refresh") { Task { agentSessions = await model.agentSessionSummaries() } }
            }
        }
        .formStyle(.grouped)
        .task {
            model.checkIntegration(.claudeCode)
            model.checkIntegration(.codex)
            agentSessions = await model.agentSessionSummaries()
        }
    }

    private static func providerLabel(_ provider: AgentProvider) -> String {
        switch provider {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    @ViewBuilder
    private func integrationRow(for provider: AgentProvider) -> some View {
        let status = model.integrationStatus(for: provider)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(Self.statusLabel(status))
                    .foregroundStyle(Self.statusColor(status))
                Spacer()
                Button("Install") { model.installIntegration(provider) }
                Button("Uninstall") { model.uninstallIntegration(provider) }
                Button("Check") { model.checkIntegration(provider) }
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

    /// Extra guidance shown under the status label. For Codex trust-required and
    /// config-disabled states this is the exact copy the plan specifies.
    private static func statusDetail(_ status: IntegrationStatus) -> String? {
        switch status {
        case .installedTrustRequired:
            "Run /hooks in Codex and trust the Relay hook."
        case let .configurationError(message):
            message
        default:
            nil
        }
    }
}
