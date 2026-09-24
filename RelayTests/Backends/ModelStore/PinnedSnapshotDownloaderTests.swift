import Synchronization
import XCTest

@testable import Relay

/// Serves canned responses by URL and records every request. One test at a time uses it
/// (`setUp` installs the table, `tearDown` clears it).
final class StubURLProtocol: URLProtocol {
    struct Reply: Sendable {
        let status: Int
        let body: Data
        let headers: [String: String]
    }

    static let table = Mutex<[String: Reply]>([:])
    static let requests = Mutex<[String]>([])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!.absoluteString
        Self.requests.withLock { $0.append(url) }
        let reply = Self.table.withLock { $0[url] } ?? Reply(status: 404, body: Data(), headers: [:])
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class PinnedSnapshotDownloaderTests: XCTestCase {
    private let sha = "73e3e38d981303bc594367cd910ea6eb48349da8"
    private let treeURL = "https://huggingface.co/api/models/org/model/tree/73e3e38d981303bc594367cd910ea6eb48349da8?recursive=true"
    private let config = Data("{}".utf8)
    private let weights = Data("weights".utf8)
    private var staging: URL!

    override func setUpWithError() throws {
        staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        StubURLProtocol.table.withLock { $0 = [:] }
        StubURLProtocol.requests.withLock { $0 = [] }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: staging)
        StubURLProtocol.table.withLock { $0 = [:] }
    }

    private func downloader() -> PinnedSnapshotDownloader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return PinnedSnapshotDownloader(session: URLSession(configuration: configuration))
    }

    private func snapshot(pinned: [String: String]) -> PinnedSnapshot {
        PinnedSnapshot(
            repo: "org/model", revision: sha, allowlist: ["config.json", "model.safetensors"],
            requiredFiles: ["config.json", "model.safetensors"], pinnedSHA256: pinned
        )
    }

    private func serve(_ url: String, _ body: Data, status: Int = 200, headers: [String: String] = [:]) {
        StubURLProtocol.table.withLock { $0[url] = .init(status: status, body: body, headers: headers) }
    }

    private func tree(_ entries: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: entries)
    }

    private var standardTree: Data {
        tree([
            ["type": "file", "path": "config.json", "size": 2, "oid": "blob-config"],
            ["type": "file", "path": "model.safetensors", "size": 7, "oid": "pointer", "lfs": ["oid": sha256Hex(weights), "size": 7]],
            ["type": "file", "path": "README.md", "size": 1, "oid": "readme"],
            ["type": "directory", "path": "extra", "size": 0, "oid": "dir"],
        ])
    }

    func testFetchesTheTreeAndFilesAtTheCommitSHAAndFiltersToTheAllowlist() async throws {
        serve(treeURL, standardTree)
        serve("https://huggingface.co/org/model/resolve/\(sha)/config.json", config)
        serve("https://huggingface.co/org/model/resolve/\(sha)/model.safetensors", weights)

        let files = try await downloader().download(snapshot(pinned: ["model.safetensors": sha256Hex(weights)]), into: staging) { _ in }

        XCTAssertEqual(
            files.sorted { $0.relativePath < $1.relativePath },
            [
                VerifiedModelFile(relativePath: "config.json", oid: .gitBlobSHA1("blob-config")),
                VerifiedModelFile(relativePath: "model.safetensors", oid: .sha256(sha256Hex(weights))),
            ]
        )
        XCTAssertEqual(try Data(contentsOf: staging.appendingPathComponent("model.safetensors")), weights)
        let requests = StubURLProtocol.requests.withLock { $0 }
        XCTAssertFalse(requests.contains { $0.contains("/main") }, "never a branch ref")
        XCTAssertFalse(requests.contains { $0.contains("README") })
    }

    func testPinnedHashMismatchFailsBeforeAnyFileIsFetched() async {
        serve(treeURL, standardTree)
        do {
            _ = try await downloader().download(snapshot(pinned: ["model.safetensors": String(repeating: "b", count: 64)]), into: staging) { _ in }
            XCTFail("expected a pinned hash mismatch")
        } catch {
            XCTAssertEqual(error as? PinnedSnapshotDownloaderError, .pinnedHashMismatch)
        }
        XCTAssertEqual(StubURLProtocol.requests.withLock { $0 }, [treeURL])
    }

    func testPinnedFileMissingFromTheTreeFails() async {
        serve(treeURL, tree([["type": "file", "path": "config.json", "size": 2, "oid": "blob-config"]]))
        do {
            _ = try await downloader().download(snapshot(pinned: ["model.safetensors": sha256Hex(weights)]), into: staging) { _ in }
            XCTFail("expected a pinned hash mismatch")
        } catch {
            XCTAssertEqual(error as? PinnedSnapshotDownloaderError, .pinnedHashMismatch)
        }
    }

    func testFollowsTreePagination() async throws {
        let page2 = treeURL + "&cursor=2"
        serve(treeURL, tree([["type": "file", "path": "config.json", "size": 2, "oid": "blob-config"]]), headers: ["Link": "<\(page2)>; rel=\"next\""])
        serve(page2, tree([["type": "file", "path": "model.safetensors", "size": 7, "oid": "p", "lfs": ["oid": sha256Hex(weights), "size": 7]]]))
        serve("https://huggingface.co/org/model/resolve/\(sha)/config.json", config)
        serve("https://huggingface.co/org/model/resolve/\(sha)/model.safetensors", weights)

        let files = try await downloader().download(snapshot(pinned: [:]), into: staging) { _ in }

        XCTAssertEqual(files.count, 2)
    }

    func testHTTPErrorsThrow() async {
        serve(treeURL, Data(), status: 500)
        do {
            _ = try await downloader().download(snapshot(pinned: [:]), into: staging) { _ in }
            XCTFail("expected an HTTP error")
        } catch {
            XCTAssertEqual(error as? PinnedSnapshotDownloaderError, .httpError)
        }
    }
}
