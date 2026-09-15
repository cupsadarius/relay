import SwiftUI

struct MenuBarContentView: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.statusText)
            Divider()
            Button("Speak Latest Agent Response") {
                Task { await model.speakLatestAgentResponse() }
            }
            .disabled(!model.latestAgentResponseAvailable)
            Divider()
            Text("Claude Code: \(Self.statusLabel(model.integrationStatus(for: .claudeCode)))")
            Text("Codex: \(Self.statusLabel(model.integrationStatus(for: .codex)))")
            Divider()
            Button("Settings...") { windowFocus.openSettings() }
            Button("Diagnostics…") { windowFocus.openDiagnostics() }
            Button("Quit Relay") { NSApplication.shared.terminate(nil) }
        }
        .padding(8)
        .frame(minWidth: 220)
    }

    /// Short menu-bar label for an `IntegrationStatus`. Never includes the underlying
    /// configuration-error message text (shown in full in the Integrations settings tab instead).
    private static func statusLabel(_ status: IntegrationStatus) -> String {
        switch status {
        case .notInstalled: "Not installed"
        case .installedAwaitingFirstEvent: "Installed, awaiting first event"
        case .installedTrustRequired: "Trust required"
        case .active: "Active"
        case .configurationError: "Config error"
        }
    }

    private var windowFocus: WindowFocusCoordinator {
        WindowFocusCoordinator(
            application: RelayApplicationActivator(),
            windows: RelayWindowActions(
                openSettings: { openSettings() },
                openDiagnostics: { openWindow(id: "diagnostics") }
            ),
            finder: RelayAppWindowFinder(),
            scheduler: MainLoopScheduler()
        )
    }
}
