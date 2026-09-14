import SwiftUI

struct MenuBarContentView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.statusText)
            Divider()
            SettingsLink { Text("Settings...") }
            Button("Diagnostics…") { openWindow(id: "diagnostics") }
            Button("Quit Relay") { NSApplication.shared.terminate(nil) }
        }
        .padding(8)
        .frame(minWidth: 220)
    }
}
