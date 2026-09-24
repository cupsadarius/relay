import Dispatch
import Foundation
import Synchronization

protocol MemoryPressureMonitoring: Sendable {
    /// Calls `handler` on every `.warning` or `.critical` event. Called once.
    func start(_ handler: @escaping @Sendable () -> Void)
}

/// `DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical])` (spec §9.3).
final class DispatchMemoryPressureMonitor: MemoryPressureMonitoring {
    private let queue = DispatchQueue(label: "dev.relaymac.Relay.cleanup-memory-pressure")
    private let source = Mutex<(any DispatchSourceMemoryPressure)?>(nil)

    func start(_ handler: @escaping @Sendable () -> Void) {
        source.withLock { source in
            guard source == nil else { return }
            let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
            pressure.setEventHandler(handler: handler)
            pressure.resume()
            source = pressure
        }
    }
}
