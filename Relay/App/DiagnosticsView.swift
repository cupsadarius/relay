import SwiftUI
import AppKit

struct DiagnosticsView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Permissions")
            Text("Input Monitoring (listen events): \(model.permissionSnapshot.inputMonitoringGranted ? "Granted" : "Not granted")")
            Text("Accessibility (post events): \(model.permissionSnapshot.accessibilityGranted ? "Granted" : "Not granted")")
            Text("Global event tap: \(eventTapText)")
            HStack { Button("Request Permissions") { model.requestPermissions() }; Button("Recheck / Retry") { model.recheckDiagnostics() } }
            Divider(); Text("Recent diagnostics")
            Text("Received: \(model.diagnosticsCounters.received)  Matched: \(model.diagnosticsCounters.matched)  Dispatched: \(model.diagnosticsCounters.dispatched)")
            List(model.diagnosticsEntries) { Text($0.copyLine()) }
            HStack { Button("Clear") { model.clearDiagnostics() }; Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.diagnosticsCopyText, forType: .string) } }
        }.padding().frame(minWidth: 520, minHeight: 420)
    }

    private var eventTapText: String {
        switch model.eventTapStatus { case .registered: "Registered"; case .unavailable: "Unavailable" }
    }
}
