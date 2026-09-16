import SwiftUI

@main
struct RelayApp: App {
    @NSApplicationDelegateAdaptor(RelayAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Relay", systemImage: "waveform") {
            MenuBarContentView(model: appDelegate.model)
        }
        Settings {
            SettingsView(model: appDelegate.model)
                .background(RelayWindowTagger(target: .settings).frame(width: 0, height: 0))
        }
        Window("Diagnostics", id: "diagnostics") {
            DiagnosticsView(model: appDelegate.model)
                .background(RelayWindowTagger(target: .diagnostics).frame(width: 0, height: 0))
        }
    }
}

/// Owns the single production `AppModel` instance and drives its agent-integration socket
/// lifecycle from real app-launch/termination events. Never used by tests: every test
/// constructs its own `AppModel` directly and never calls `startIntegrations()`/
/// `stopIntegrations()`, so no test ever opens a real socket or touches real `~/.claude`/
/// `~/.codex` config.
@MainActor
final class RelayAppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel(runtime: .makeProduction())

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.startIntegrations()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stopIntegrations()
    }
}
