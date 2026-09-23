import SwiftUI

struct GeneralSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Live Transcription") {
                Toggle("Live transcription in the pill", isOn: liveTranscriptionBinding)
                Text("Show interim text while you speak. Re-transcribes about twice a second (uses more CPU).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Activity Overlay") {
                Picker("Style", selection: activityOverlayStyleBinding) {
                    Text("Off").tag(ActivityOverlayStyle.off)
                    Text("Minimal").tag(ActivityOverlayStyle.minimal)
                    Text("Interactive").tag(ActivityOverlayStyle.interactive)
                }
                .pickerStyle(.segmented)
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: launchAtLoginBinding)
                Text("Start Relay automatically when you log in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var liveTranscriptionBinding: Binding<Bool> {
        Binding(
            get: { model.settings.liveTranscriptionEnabled },
            set: { model.settingsController.setLiveTranscriptionEnabled($0) }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { model.permissions.launchAtLoginEnabled },
            set: { model.permissions.setLaunchAtLogin($0) }
        )
    }

    private var activityOverlayStyleBinding: Binding<ActivityOverlayStyle> {
        Binding(
            get: { model.settings.activityOverlayStyle },
            set: { model.setActivityOverlayStyle($0) }
        )
    }
}
