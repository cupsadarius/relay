import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            GeneralSettingsView(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            KeybindsSettingsView(model: model)
                .tabItem { Label("Keybinds", systemImage: "keyboard") }
            DictationSettingsView(model: model)
                .tabItem { Label("Dictation", systemImage: "mic") }
            TTSSettingsView(model: model)
                .tabItem { Label("TTS", systemImage: "speaker.wave.2") }
            PermissionsSettingsView(model: model)
                .tabItem { Label("Security", systemImage: "lock.shield") }
            IntegrationsSettingsView(model: model)
                .tabItem { Label("Integrations", systemImage: "app.connected.to.app.below.fill") }
        }
        .frame(width: 620, height: 610)
        .task { await model.refreshSpeechBackendStatuses() }
    }
}
