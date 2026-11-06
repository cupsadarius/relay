import Foundation

enum BackendAvailability: Equatable, Sendable {
    case available
    case unavailable(String)
    case modelNotDownloaded
    case permissionDenied
    case unsupportedHardware
    case failed(String)
}
