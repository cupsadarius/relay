import AppKit
import Observation

/// Permissions and startup settings for the Security/General tabs and Diagnostics: the global
/// permission snapshot, microphone, privacy panes, login item, and the app-activation hook that
/// triggers a recheck.
@MainActor
@Observable
final class PermissionsModel {
    private(set) var snapshot: PermissionSnapshot
    private(set) var microphoneGranted: Bool
    /// Mirrors the OS login-item registration; never persisted separately.
    private(set) var launchAtLoginEnabled: Bool

    /// Privacy-safe metadata of the last capture (never audio/text/paths).
    var lastMicrophoneCaptureDiagnostics: MicrophoneCaptureDiagnostics? {
        diagnostics.lastMicrophoneCaptureDiagnostics
    }

    @ObservationIgnored private let permissionService: any GlobalPermissionAuthorizing
    @ObservationIgnored private let microphone: any MicrophonePermissionStatusProviding
    @ObservationIgnored private let opener: any PrivacySettingsOpening
    @ObservationIgnored private let loginItems: any LoginItemControlling
    @ObservationIgnored private let diagnostics: DiagnosticsRecorder
    @ObservationIgnored private let statusSink: StatusSink
    @ObservationIgnored private var activationObservation: NotificationObservation?

    init(runtime: RelayRuntime) {
        permissionService = runtime.permissionService
        microphone = runtime.microphonePermissions
        opener = runtime.privacySettingsOpener
        loginItems = runtime.loginItemService
        diagnostics = runtime.diagnostics
        statusSink = runtime.status
        snapshot = runtime.permissionService.snapshot()
        microphoneGranted = runtime.microphonePermissions.isGranted()
        launchAtLoginEnabled = runtime.loginItemService.isEnabled
    }

    /// Runs `onActivate` every time Relay becomes active, for as long as this model lives.
    func observeActivation(center: NotificationCenter = .default, _ onActivate: @escaping @MainActor () -> Void) {
        activationObservation = NotificationObservation(
            center: center,
            name: NSApplication.didBecomeActiveNotification,
            handler: onActivate
        )
    }

    func recheck() {
        snapshot = permissionService.snapshot()
        microphoneGranted = microphone.isGranted()
        diagnostics.record(.permissionRechecked)
    }

    func requestAccessibility() {
        permissionService.requestPermissions()
        diagnostics.record(.permissionRequested)
        snapshot = permissionService.snapshot()
    }

    func requestMicrophone() async {
        _ = await microphone.requestPermission()
        microphoneGranted = microphone.isGranted()
        statusSink.post(microphoneGranted
            ? "Microphone permission granted"
            : "Allow Microphone permission in System Settings to dictate.")
    }

    func openPrivacySettings(_ pane: PrivacySettingsPane) {
        opener.open(pane)
    }

    /// One-click fix for a stale post-rebuild microphone grant.
    func openMicrophoneSettings() {
        opener.open(.microphone)
    }

    /// On failure (e.g. a dev build outside /Applications) re-reads the real status instead of
    /// drifting, and posts a non-fatal message.
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try loginItems.setEnabled(enabled)
            launchAtLoginEnabled = enabled
        } catch {
            launchAtLoginEnabled = loginItems.isEnabled
            statusSink.post("Could not change launch-at-login.")
        }
    }
}
