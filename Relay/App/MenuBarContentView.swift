import SwiftUI

struct MenuBarContentView: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.activityStatusText)
            Divider()
            Button("Speak Latest Agent Response") {
                Task { await model.speakLatestAgentResponse() }
            }
            .disabled(!model.latestAgentResponseAvailable)
            Button(model.settings.autoReadEnabled ? "Auto-read: On" : "Auto-read: Off") {
                model.toggleAutoRead()
            }
            Divider()
            Button("Settings...") { windowFocus.openSettings() }
            Button("Diagnostics…") { windowFocus.openDiagnostics() }
            Button("Quit Relay") { NSApplication.shared.terminate(nil) }
        }
        .padding(8)
        .frame(minWidth: 220)
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
