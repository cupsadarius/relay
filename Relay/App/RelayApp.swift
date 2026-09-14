import SwiftUI

@main
struct RelayApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("Relay", systemImage: "waveform") {
            MenuBarContentView(model: model)
        }
        Settings {
            SettingsView(model: model)
        }
        Window("Diagnostics", id: "diagnostics") {
            DiagnosticsView(model: model)
        }
    }
}
