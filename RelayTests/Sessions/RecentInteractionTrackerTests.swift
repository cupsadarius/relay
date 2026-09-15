import XCTest
@testable import Relay

final class RecentInteractionTrackerTests: XCTestCase {
    func testNewestDictationReplacesPriorInteraction() async {
        let tracker = RecentInteractionTracker(maxAge: 120)
        await tracker.record(frontmostApplication: .init(pid: 20, bundleIdentifier: nil, localizedName: "Terminal"), at: Date(timeIntervalSince1970: 10))
        await tracker.record(frontmostApplication: .init(pid: 30, bundleIdentifier: nil, localizedName: "Other"), at: Date(timeIntervalSince1970: 20))
        let latest = await tracker.latest(now: Date(timeIntervalSince1970: 21))
        XCTAssertEqual(latest?.frontmostPID, 30)
    }

    func testOldInteractionExpires() async {
        let tracker = RecentInteractionTracker(maxAge: 120)
        await tracker.record(frontmostApplication: .init(pid: 20, bundleIdentifier: nil, localizedName: "Terminal"), at: Date(timeIntervalSince1970: 10))
        let latest = await tracker.latest(now: Date(timeIntervalSince1970: 200))
        XCTAssertNil(latest)
    }
}
