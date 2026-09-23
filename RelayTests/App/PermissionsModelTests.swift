import AppKit
import XCTest

@testable import Relay

@MainActor
final class PermissionsModelTests: XCTestCase {
    private func makeModel(
        permissions: SpyPermissionService? = nil,
        microphone: SpyMicrophonePermission? = nil,
        opener: SpyPrivacyOpener? = nil,
        loginItem: SpyLoginItemController? = nil,
        diagnostics: DiagnosticsRecorder? = nil
    ) -> (model: PermissionsModel, runtime: RelayRuntime) {
        let permissions = permissions ?? SpyPermissionService()
        let microphone = microphone ?? SpyMicrophonePermission(granted: true)
        let opener = opener ?? SpyPrivacyOpener()
        let loginItem = loginItem ?? SpyLoginItemController(enabled: false)
        let diagnostics = diagnostics ?? DiagnosticsRecorder(capacity: 10)
        let runtime = RelayRuntime.testing(
            permissionService: permissions,
            microphonePermissions: microphone,
            privacySettingsOpener: opener,
            loginItemService: loginItem,
            diagnostics: diagnostics
        )
        return (PermissionsModel(runtime: runtime), runtime)
    }

    func testRecheckRefreshesSnapshotAndMicrophoneAndRecordsDiagnostic() {
        let permissions = SpyPermissionService(snapshot: .init(inputMonitoringGranted: false, accessibilityGranted: false))
        let microphone = SpyMicrophonePermission(granted: false)
        let (model, runtime) = makeModel(permissions: permissions, microphone: microphone)
        XCTAssertFalse(model.microphoneGranted)

        microphone.grantedValue = true
        model.recheck()

        XCTAssertEqual(permissions.snapshotCount, 2)
        XCTAssertTrue(model.microphoneGranted)
        XCTAssertFalse(model.snapshot.inputMonitoringGranted)
        XCTAssertEqual(runtime.diagnostics.entries.last?.event, .permissionRechecked)
    }

    func testRequestMicrophoneRefreshesStateAndAnnounces() async {
        let microphone = SpyMicrophonePermission(granted: false, requestResult: true)
        let (model, runtime) = makeModel(microphone: microphone)

        await model.requestMicrophone()

        XCTAssertEqual(microphone.requestCount, 1)
        XCTAssertTrue(model.microphoneGranted)
        XCTAssertEqual(runtime.status.message, "Microphone permission granted")
    }

    func testRequestAccessibilityDelegatesAndRefreshesSnapshot() {
        let permissions = SpyPermissionService()
        let (model, runtime) = makeModel(permissions: permissions)

        model.requestAccessibility()

        XCTAssertEqual(permissions.requestCount, 1)
        XCTAssertEqual(permissions.snapshotCount, 2)
        XCTAssertEqual(runtime.diagnostics.entries.last?.event, .permissionRequested)
    }

    func testPrivacyPanesOpenThroughTheInjectedOpener() {
        let opener = SpyPrivacyOpener()
        let (model, _) = makeModel(opener: opener)

        model.openPrivacySettings(.accessibility)
        model.openMicrophoneSettings()

        XCTAssertEqual(opener.opened, [.accessibility, .microphone])
    }

    func testLastMicrophoneCaptureDiagnosticsPassesThroughTheRecorder() {
        let recorder = DiagnosticsRecorder(capacity: 10)
        let (model, _) = makeModel(diagnostics: recorder)
        XCTAssertNil(model.lastMicrophoneCaptureDiagnostics)
        let record = MicrophoneCaptureDiagnostics(inputSampleRate: 48_000, frameCount: 0, capturedAt: Date(timeIntervalSince1970: 1))

        recorder.recordMicrophoneCapture(record)

        XCTAssertEqual(model.lastMicrophoneCaptureDiagnostics, record)
    }

    func testLaunchAtLoginReflectsServiceAndUpdatesOnSuccess() {
        let loginItem = SpyLoginItemController(enabled: false)
        let (model, _) = makeModel(loginItem: loginItem)
        XCTAssertFalse(model.launchAtLoginEnabled)

        model.setLaunchAtLogin(true)

        XCTAssertEqual(loginItem.setEnabledCalls, [true])
        XCTAssertTrue(model.launchAtLoginEnabled)
    }

    /// The service starting already enabled must be reflected at construction, not just after a
    /// later `setLaunchAtLogin` call.
    func testLaunchAtLoginReflectsAnAlreadyEnabledService() {
        let loginItem = SpyLoginItemController(enabled: true)
        let (model, _) = makeModel(loginItem: loginItem)

        XCTAssertTrue(model.launchAtLoginEnabled)
    }

    func testLaunchAtLoginCanBeTurnedOff() {
        let loginItem = SpyLoginItemController(enabled: true)
        let (model, _) = makeModel(loginItem: loginItem)
        XCTAssertTrue(model.launchAtLoginEnabled)

        model.setLaunchAtLogin(false)

        XCTAssertEqual(loginItem.setEnabledCalls, [false])
        XCTAssertFalse(model.launchAtLoginEnabled)
    }

    func testLaunchAtLoginFailureKeepsActualStatusAndAnnounces() {
        let loginItem = SpyLoginItemController(enabled: false, setEnabledError: CancellationError())
        let (model, runtime) = makeModel(loginItem: loginItem)

        model.setLaunchAtLogin(true)

        XCTAssertFalse(model.launchAtLoginEnabled)
        XCTAssertEqual(runtime.status.message, "Could not change launch-at-login.")
    }

    func testActivationNotificationRunsTheHandler() async {
        let center = NotificationCenter()
        let (model, _) = makeModel()
        let activations = ActivationCounter()
        model.observeActivation(center: center) { activations.value += 1 }

        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        let deadline = Date().addingTimeInterval(2)
        while activations.value == 0, Date() < deadline { await Task.yield() }

        XCTAssertEqual(activations.value, 1)
    }
}

/// A reference the escaping `@MainActor` activation closure can mutate (no captured `var`).
@MainActor
private final class ActivationCounter {
    var value = 0
}
