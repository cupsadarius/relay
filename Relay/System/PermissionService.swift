import AVFoundation
@preconcurrency import ApplicationServices
import CoreGraphics

struct PermissionSnapshot: Equatable, Sendable {
    let inputMonitoringGranted: Bool
    let accessibilityGranted: Bool
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
        native.requestListenForEvents(); native.requestPostEvents(); native.requestAccessibilityTrust()
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
