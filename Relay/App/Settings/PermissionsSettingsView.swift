import SwiftUI

struct PermissionsSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Permissions") {
                permissionRow(
                    title: "Microphone",
                    granted: model.microphonePermissionGranted,
                    request: { Task { await model.requestMicrophonePermission() } },
                    settings: { model.openPrivacySettings(.microphone) }
                )
                permissionRow(
                    title: "Accessibility",
                    granted: model.permissionSnapshot.accessibilityGranted,
                    settings: { model.openPrivacySettings(.accessibility) }
                )
                Button("Request Accessibility") { model.requestPermissions() }
                    .controlSize(.small)
            }
        }
        .formStyle(.grouped)
    }

    private func permissionRow(
        title: String,
        granted: Bool,
        request: (() -> Void)? = nil,
        settings: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(granted ? "Allowed" : "Required")
                .foregroundStyle(granted ? .green : .orange)
            if !granted {
                if let request { Button("Allow", action: request) }
                Button("Open Settings", action: settings)
            }
        }
    }
}
