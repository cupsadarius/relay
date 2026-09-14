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
                .background(RelayWindowTagger(target: .settings).frame(width: 0, height: 0))
        }
        Window("Diagnostics", id: "diagnostics") {
            DiagnosticsView(model: model)
                .background(RelayWindowTagger(target: .diagnostics).frame(width: 0, height: 0))
        }
    }
}
