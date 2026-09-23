import XCTest
@testable import Relay

@MainActor
final class NotificationObservationTests: XCTestCase {
    private let notificationName = Notification.Name("relay.test.notification")

    func testHandlerRunsWhileTheTokenIsAlive() async {
        let center = NotificationCenter()
        let counter = Counter()
        let observation = NotificationObservation(center: center, name: notificationName) { counter.value += 1 }

        center.post(name: notificationName, object: nil)
        let deadline = Date().addingTimeInterval(2)
        while counter.value == 0, Date() < deadline { await Task.yield() }

        XCTAssertEqual(counter.value, 1)
        withExtendedLifetime(observation) {}
    }

    func testReleasingTheTokenStopsDelivery() async {
        let center = NotificationCenter()
        let counter = Counter()
        var observation: NotificationObservation? = NotificationObservation(center: center, name: notificationName) { counter.value += 1 }
        XCTAssertNotNil(observation)

        observation = nil
        center.post(name: notificationName, object: nil)
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(counter.value, 0)
    }
}

@MainActor
private final class Counter {
    var value = 0
}
