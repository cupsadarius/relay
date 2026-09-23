import SwiftUI

struct MenuBarContentView: View {
    @Bindable var model: AppModel
    var presentation: BuildFlavorPresentation = .current
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header = presentation.menuHeader {
                Text(header)
                    .font(.headline)
                Divider()
            }
            Text(model.activityStatusText)
            Divider()
            Button("Speak Latest Agent Response") {
                Task { await model.speakLatestAgentResponse() }
            }
            .disabled(!model.integrationSetup.latestResponseAvailable)
            Button(model.settings.autoReadEnabled ? "Auto-read: On" : "Auto-read: Off") {
                model.settingsController.toggleAutoRead()
            }
            Divider()
            Button("Settings...") { windowFocus.openSettings() }
            Button("Diagnostics…") { windowFocus.openDiagnostics() }
            Button(presentation.quitTitle) { NSApplication.shared.terminate(nil) }
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
