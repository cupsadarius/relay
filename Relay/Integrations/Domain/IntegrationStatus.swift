import Foundation

enum IntegrationStatus: Equatable, Sendable {
    case notInstalled
    case installedAwaitingFirstEvent
    case installedTrustRequired
    case active(lastEventAt: Date)
    case configurationError(String)
}
