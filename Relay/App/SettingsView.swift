import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Text("Relay settings")
        }
        .padding()
        .frame(width: 520, height: 360)
    }
}
