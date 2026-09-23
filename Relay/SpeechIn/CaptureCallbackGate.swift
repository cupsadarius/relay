import Foundation

/// Coordinates the audio tap thread with `stop()` without holding any lock across a callout.
/// - The tap brackets each delivery with `enter()`/`leave()`, and delivers samples outside the
///   lock.
/// - `close()` stops admitting callbacks and waits until in-flight ones have left. When it
///   returns, no further samples are delivered until the next `open()`.
/// - `fail(_:)` records the first failure and closes the gate without waiting, so a callback can
///   call it on itself.
///
/// `close()` blocks its thread briefly: at most one tap callback's conversion time.
final class CaptureCallbackGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = false
    private var inFlight = 0
    private var failure: (any Error)?

    /// Starts a new capture: admits callbacks and clears any previous failure.
    func open() {
        condition.withLock {
            isOpen = true
            failure = nil
        }
    }

    /// Tap thread. `true` means this callback may deliver samples; balance it with `leave()`.
    func enter() -> Bool {
        condition.withLock {
            guard isOpen else { return false }
            inFlight += 1
            return true
        }
    }

    func leave() {
        condition.withLock {
            inFlight -= 1
            if inFlight == 0 {
                condition.broadcast()
            }
        }
    }

    /// Records `error` and closes the gate. Returns `true` only for the call that closed it, so the
    /// terminal error is reported exactly once. Never waits for in-flight callbacks.
    func fail(_ error: any Error) -> Bool {
        condition.withLock {
            guard isOpen else { return false }
            isOpen = false
            failure = error
            return true
        }
    }

    /// Closes the gate, waits until no callback is delivering samples, and returns (then clears)
    /// the failure recorded since `open()`, if any.
    func close() -> (any Error)? {
        condition.withLock {
            isOpen = false
            while inFlight > 0 {
                condition.wait()
            }
            defer { failure = nil }
            return failure
        }
    }
}
