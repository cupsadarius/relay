import XCTest
import SwiftUI
@testable import Relay

final class SettingsViewsSmokeTests: XCTestCase {
    @MainActor
    func testAllSettingsTabViewsConstruct() {
        let model = AppModel()
        _ = SettingsView(model: model)
        _ = KeybindsSettingsView(model: model)
        _ = DictationSettingsView(model: model)
        _ = TTSSettingsView(model: model)
        _ = PermissionsSettingsView(model: model)
    }
}
