import AVFoundation
import XCTest

@testable import Relay

final class AudioEngineConfigurationObserverTests: XCTestCase {
    func testFiresOnlyForTheObservedEngine() {
        let center = NotificationCenter()
        let engine = NSObject()
        let other = NSObject()
        let counter = ChangeCounter()
        let observer = AudioEngineConfigurationObserver(engine: engine, center: center) { counter.increment() }

        center.post(name: .AVAudioEngineConfigurationChange, object: other)
        XCTAssertEqual(counter.value, 0)
        center.post(name: .AVAudioEngineConfigurationChange, object: engine)
        XCTAssertEqual(counter.value, 1)

        withExtendedLifetime(observer) {}
    }

    func testStopsObservingOnceReleased() {
        let center = NotificationCenter()
        let engine = NSObject()
        let counter = ChangeCounter()
        var observer: AudioEngineConfigurationObserver? = AudioEngineConfigurationObserver(engine: engine, center: center) {
            counter.increment()
        }
        XCTAssertNotNil(observer)
        observer = nil

        center.post(name: .AVAudioEngineConfigurationChange, object: engine)
        XCTAssertEqual(counter.value, 0)
    }
}

private final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
