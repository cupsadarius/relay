import ServiceManagement

/// Seam over `SMAppService.mainApp` so `AppModel` can be tested without touching the real
/// login-item registry. `isEnabled` mirrors the OS's own registration state; `setEnabled`
/// registers/unregisters Relay as a login item and rethrows whatever `SMAppService` throws
/// (e.g. a dev build running outside `/Applications` failing to register) so the caller can
/// degrade gracefully instead of crashing.
@MainActor
protocol LoginItemControlling: AnyObject {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

@MainActor
final class SystemLoginItemController: LoginItemControlling {
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
