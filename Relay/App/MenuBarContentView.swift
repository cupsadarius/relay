import SwiftUI

struct MenuBarContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.statusText)
            Divider()
            SettingsLink { Text("Settings...") }
            Button("Quit Relay") { NSApplication.shared.terminate(nil) }
        }
        .padding(8)
        .frame(minWidth: 220)
    }
}
