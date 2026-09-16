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
            Section("Microphone Diagnostics") {
                VStack(alignment: .leading, spacing: 4) {
                    Button("Open Microphone Settings") { model.openMicrophoneSettings() }
                        .controlSize(.small)
                    Text("After a rebuild, macOS can keep the Microphone toggle on while delivering no audio. Use this to toggle Relay's grant off and back on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let capture = model.lastMicrophoneCaptureDiagnostics {
                    captureDiagnosticsRow(capture)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Privacy-safe: renders only `capture`'s counts/rate/timestamp fields — never audio samples,
    /// transcript text, or file paths.
    private func captureDiagnosticsRow(_ capture: MicrophoneCaptureDiagnostics) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Last capture: \(capture.frameCount) frames at \(Int(capture.inputSampleRate.rounded())) Hz")
                .foregroundStyle(.secondary)
            if capture.frameCount == 0 {
                Text("No audio was captured. After a rebuild the microphone grant can go stale — open Microphone Settings and toggle Relay off then on.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
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
