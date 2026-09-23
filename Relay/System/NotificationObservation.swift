import Foundation

/// A NotificationCenter block observer that removes itself when released. Owners just hold the
/// token; they need no `deinit` of their own (which, on a `@MainActor` class, is nonisolated and
/// can't safely read the non-Sendable observer handle).
final class NotificationObservation: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    /// `handler` runs on the main actor (the observer is registered on the main queue).
    init(
        center: NotificationCenter = .default,
        name: Notification.Name,
        handler: @escaping @MainActor () -> Void
    ) {
        self.center = center
        token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    deinit {
        center.removeObserver(token)
    }
}
