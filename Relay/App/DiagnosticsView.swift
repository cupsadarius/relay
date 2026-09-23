import AppKit
import SwiftUI

struct DiagnosticsView: View {
    static let accessibilityPermissionLabel = "Accessibility"

    @Bindable var model: AppModel
    @State private var integrationDiagnosticsEntries: [IntegrationDiagnosticsEntry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Permissions")
            Text("Input Monitoring (optional, listen events): \(model.permissions.snapshot.inputMonitoringGranted ? "Granted" : "Not granted")")
            Text("\(Self.accessibilityPermissionLabel): \(model.permissions.snapshot.accessibilityGranted ? "Granted" : "Not granted")")
            Text("Global Hotkeys (effective): \(model.permissions.snapshot.globalHotkeysGranted ? "Granted" : "Not granted")")
            Text("Global event tap: \(eventTapText)")
            HStack {
                Button("Request Accessibility") { model.permissions.requestAccessibility() }; Button("Recheck / Retry") { model.recheckDiagnostics() }
            }
            Divider(); Text("Recent diagnostics")
            Text(
                "Received: \(model.diagnosticsCounters.received)  Matched: \(model.diagnosticsCounters.matched)  Dispatched: \(model.diagnosticsCounters.dispatched)"
            )
            List(model.diagnosticsEntries) { Text($0.copyLine()) }
            HStack {
                Button("Clear") { model.clearDiagnostics() };
                Button("Copy") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.diagnosticsCopyText, forType: .string)
                }
            }
            Divider(); Text("Integration Pipeline")
            List(integrationDiagnosticsEntries) { entry in
                Text("\(DiagnosticTimestampFormatter.local.string(from: entry.timestamp)) [\(entry.stage)] \(entry.outcome) — \(entry.detail)")
            }
            HStack {
                Button("Refresh") { integrationDiagnosticsEntries = model.integrationDiagnosticsEntries() }
                Button("Clear") {
                    model.clearIntegrationDiagnostics()
                    integrationDiagnosticsEntries = model.integrationDiagnosticsEntries()
                }
            }
        }.padding().frame(minWidth: 520, minHeight: 420)
            .task { integrationDiagnosticsEntries = model.integrationDiagnosticsEntries() }
    }

    private var eventTapText: String {
        switch model.hotkeys.eventTapStatus {
        case .registered: "Registered";
        case .unavailable: "Unavailable"
        }
    }
}
