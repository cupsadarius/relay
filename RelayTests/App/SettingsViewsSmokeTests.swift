import XCTest
import SwiftUI
@testable import Relay

final class SettingsViewsSmokeTests: XCTestCase {
    @MainActor
    func testAllSettingsTabViewsConstruct() {
        let model = AppModel()
        _ = SettingsView(model: model)
        _ = GeneralSettingsView(model: model)
        _ = KeybindsSettingsView(model: model)
        _ = DictationSettingsView(model: model)
        _ = TTSSettingsView(model: model)
        _ = PermissionsSettingsView(model: model)
        _ = IntegrationsSettingsView(model: model)
    }

    /// The menu bar shows and toggles auto-read state alongside the agent-response controls;
    /// this only guards that the view still constructs with the button title reflecting
    /// `model.settings.autoReadEnabled` in both states. `AppModel()` loads the real, persisted
    /// settings store, so this reads whatever `autoReadEnabled` already is rather than assuming
    /// the shipped default, and restores it afterward so the on-disk value isn't left flipped
    /// for whichever run reuses this store next.
    @MainActor
    func testMenuBarContentViewConstructsInBothAutoReadStates() {
        let model = AppModel()
        let initial = model.settings.autoReadEnabled
        _ = MenuBarContentView(model: model)

        model.toggleAutoRead()

        XCTAssertEqual(model.settings.autoReadEnabled, !initial)
        _ = MenuBarContentView(model: model)

        model.toggleAutoRead()
        XCTAssertEqual(model.settings.autoReadEnabled, initial)
    }
}
