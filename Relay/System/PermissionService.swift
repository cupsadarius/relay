import AVFoundation
import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics

@MainActor
protocol MicrophonePermissionStatusProviding: AnyObject {
    func isGranted() -> Bool
    func requestPermission() async -> Bool
}

@MainActor
final class SystemMicrophonePermissionStatusProvider: MicrophonePermissionStatusProviding {
    func isGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func requestPermission() async -> Bool {
        await SystemMicrophonePermissionAuthorizer().requestPermission()
    }
}

enum PrivacySettingsPane: Equatable {
    case microphone
    case accessibility
    case inputMonitoring

    var url: URL {
        let anchor = switch self {
        case .microphone: "Privacy_Microphone"
        case .accessibility: "Privacy_Accessibility"
        case .inputMonitoring: "Privacy_ListenEvent"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

@MainActor
protocol PrivacySettingsOpening: AnyObject {
    func open(_ pane: PrivacySettingsPane)
}

@MainActor
final class SystemPrivacySettingsOpener: PrivacySettingsOpening {
    func open(_ pane: PrivacySettingsPane) {
        NSWorkspace.shared.open(pane.url)
    }
}

struct PermissionSnapshot: Equatable, Sendable {
    let inputMonitoringGranted: Bool
    let accessibilityGranted: Bool

    var globalHotkeysGranted: Bool {
        inputMonitoringGranted || accessibilityGranted
    }
}

protocol GlobalPermissionAuthorizing: AnyObject {
    func snapshot() -> PermissionSnapshot
    func requestPermissions()
}

protocol NativePermissionChecking: AnyObject {
    func canListenForEvents() -> Bool
    func canPostEvents() -> Bool
    func isAccessibilityTrusted() -> Bool
    func requestListenForEvents()
    func requestPostEvents()
    func requestAccessibilityTrust()
}

final class PermissionService: GlobalPermissionAuthorizing {
    private let native: any NativePermissionChecking
    init(native: any NativePermissionChecking = SystemNativePermissions()) { self.native = native }
    func snapshot() -> PermissionSnapshot {
        .init(inputMonitoringGranted: native.canListenForEvents(), accessibilityGranted: native.canPostEvents() && native.isAccessibilityTrusted())
    }
    func requestPermissions() {
        guard !snapshot().accessibilityGranted else { return }
        native.requestAccessibilityTrust()
    }
}

final class SystemNativePermissions: NativePermissionChecking {
    func canListenForEvents() -> Bool { CGPreflightListenEventAccess() }
    func canPostEvents() -> Bool { CGPreflightPostEventAccess() }
    func isAccessibilityTrusted() -> Bool { AXIsProcessTrusted() }
    func requestListenForEvents() { _ = CGRequestListenEventAccess() }
    func requestPostEvents() { _ = CGRequestPostEventAccess() }
    func requestAccessibilityTrust() { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }
}

protocol MicrophonePermissionAuthorizing: Sendable {
    func requestPermission() async -> Bool
}

struct SystemMicrophonePermissionAuthorizer: MicrophonePermissionAuthorizing {
    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            true
        case .notDetermined:
            await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            false
        @unknown default:
            false
        }
    }
}
