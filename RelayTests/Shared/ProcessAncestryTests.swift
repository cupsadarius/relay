import XCTest
@testable import Relay

final class ProcessAncestryTests: XCTestCase {
    private func table(_ rows: [(Int32, Int32, String)]) -> (Int32) -> ProcessAncestry.Entry? {
        let entries = Dictionary(uniqueKeysWithValues: rows.map {
            ($0.0, ProcessAncestry.Entry(pid: $0.0, parentPID: $0.1, command: $0.2))
        })
        return { entries[$0] }
    }

    func testRealChainStartsAtThisProcessThenItsParent() {
        let chain = ProcessAncestry.chain(from: getpid())
        XCTAssertEqual(chain.first?.pid, getpid())
        XCTAssertEqual(chain.dropFirst().first?.pid, getppid())
        XCTAssertLessThanOrEqual(chain.count, ProcessAncestry.maxDepth)
    }

    func testMissingProcessYieldsAnEmptyChain() {
        XCTAssertTrue(ProcessAncestry.chain(from: 900, lookup: table([])).isEmpty)
    }

    func testCyclesAndDepthAreBounded() {
        let cyclic = table([(10, 11, "a"), (11, 10, "b")])
        XCTAssertEqual(ProcessAncestry.chain(from: 10, lookup: cyclic).map(\.pid), [10, 11])

        let deep = table((1...40).map { (Int32($0), Int32($0 + 1), "p") })
        XCTAssertEqual(ProcessAncestry.chain(from: 1, lookup: deep).count, ProcessAncestry.maxDepth)
    }

    func testLeadingWrapperShellIsTrimmedSoTheAgentComesFirst() {
        let lookup = table([(900, 800, "sh"), (800, 700, "claude"), (700, 20, "zsh"), (20, 1, "Ghostty"), (1, 0, "launchd")])
        XCTAssertEqual(ProcessAncestry.agentAncestry(from: 900, lookup: lookup), [800, 700, 20, 1])
    }

    func testDirectExecChainIsUnchangedAndTheLoginShellAboveTheAgentIsKept() {
        let lookup = table([(800, 700, "claude"), (700, 20, "zsh"), (20, 1, "Ghostty"), (1, 0, "launchd")])
        XCTAssertEqual(ProcessAncestry.agentAncestry(from: 800, lookup: lookup), [800, 700, 20, 1])
    }

    func testAllShellChainIsKeptUntrimmed() {
        let lookup = table([(900, 800, "sh"), (800, 0, "zsh")])
        XCTAssertEqual(ProcessAncestry.agentAncestry(from: 900, lookup: lookup), [900, 800])
    }
}
