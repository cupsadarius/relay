import XCTest
@testable import Relay

final class ProcessInspectorTests: XCTestCase {
    func testParsesSnapshotAndWalksAncestry() throws {
        let fixture = """
          1     0 ??       launchd
         20     1 ??       Ghostty
        101    20 ttys001  zsh
        202   101 ttys001  claude
        303   202 ttys001  RelayHook
        """
        let snapshot = try ProcessSnapshot.parse(fixture)
        XCTAssertEqual(snapshot.ancestry(from: 303).map(\.pid), [303, 202, 101, 20, 1])
        XCTAssertEqual(snapshot.record(pid: 303)?.tty, "ttys001")
    }

    func testDescendantsAreComputedFromParentEdges() throws {
        let snapshot = try ProcessSnapshot.parse("""
          20 1 ?? Ghostty
         100 20 ttys001 zsh
         101 20 ttys002 zsh
         200 100 ttys001 herdr
        """)
        XCTAssertEqual(Set(snapshot.descendants(of: 20).map(\.pid)), [100, 101, 200])
    }
}
