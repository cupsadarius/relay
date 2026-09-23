import SwiftUI

@main
struct RelayApp: App {
    @NSApplicationDelegateAdaptor(RelayAppDelegate.self) private var appDelegate
    private let presentation = BuildFlavorPresentation.current

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(model: appDelegate.model, presentation: presentation)
        } label: {
            MenuBarLabel(presentation: presentation)
        }
        Settings {
            SettingsView(model: appDelegate.model)
                .background(
                    RelayWindowTagger(target: .settings, title: presentation.settingsWindowTitle)
                        .frame(width: 0, height: 0)
                )
        }
        Window("Diagnostics", id: "diagnostics") {
            DiagnosticsView(model: appDelegate.model)
                .background(RelayWindowTagger(target: .diagnostics).frame(width: 0, height: 0))
        }
    }
}

/// Owns the single production `AppModel`, which retains the `RelayRuntime` it is built from, and
/// drives the agent-integration socket from real launch/termination events. Tests never use this
/// type and never call `makeProduction()`.
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
