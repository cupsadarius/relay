import Foundation

enum CleanupModelManagerError: Error, Equatable, Sendable {
    case unknownModel(String)
    /// Cleanup has no on-demand activation, so selecting a model that is not on disk is refused.
    case notDownloaded
    /// The Apple model is unavailable on this Mac right now.
    case unavailable
    /// Download/remove on the built-in Apple model.
    case notSupported
}
