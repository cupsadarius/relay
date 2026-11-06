import XCTest

@testable import Relay

final class ProcessInspectorTests: XCTestCase {
    func testParsesSnapshotAndWalksAncestry() throws {
        let fixture = """
              1     0 launchd
             20     1 Ghostty
            101    20 zsh
            202   101 claude
            303   202 RelayHook
            """
        let snapshot = ProcessSnapshot.parse(fixture)
        XCTAssertEqual(snapshot.ancestry(from: 303).map(\.pid), [303, 202, 101, 20, 1])
    }

    func testDescendantsAreComputedFromParentEdges() throws {
        let snapshot = ProcessSnapshot.parse(
            """
              20 1 Ghostty
             100 20 zsh
             101 20 zsh
             200 100 herdr
            """)
        XCTAssertEqual(Set(snapshot.descendants(of: 20).map(\.pid)), [100, 101, 200])
    }

    /// `/bin/ps` output on a busy machine exceeds the 64KB pipe buffer, so stdout must drain
    /// before the process exits or the call deadlocks.
    func testSnapshotReturnsAndIncludesCurrentProcessAncestry() async throws {
        let inspector = ProcessInspector()
        let snapshot = try await inspector.snapshot()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        XCTAssertNotNil(snapshot.record(pid: ownPID), "snapshot should include the current test process")
        XCTAssertFalse(snapshot.ancestry(from: ownPID).isEmpty)
    }
}
