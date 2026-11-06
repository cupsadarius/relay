import CryptoKit
import Foundation
import Synchronization

@testable import Relay

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Writes the given files into the staging directory and reports each one's oid. `lie` reports
/// a wrong oid for that path; `omit` writes nothing for that path and leaves it out of the list.
/// `claimedPath` reports a different `relativePath` than the (always-safe) path the bytes are
/// actually written to — simulating a downloader that misreports a path, without this fake itself
/// ever writing outside the staging directory (review fix 12).
final class FakeSnapshotDownloader: SnapshotDownloading {
    private let files: [String: Data]
    private let lie: Set<String>
    private let claimedPath: [String: String]
    private let error: (any Error)?
    private let calls = Mutex(0)

    init(files: [String: Data], lie: Set<String> = [], claimedPath: [String: String] = [:], error: (any Error)? = nil) {
        self.files = files
        self.lie = lie
        self.claimedPath = claimedPath
        self.error = error
    }

    var callCount: Int { calls.withLock { $0 } }

    func download(
        _ snapshot: PinnedSnapshot,
        into directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [VerifiedModelFile] {
        calls.withLock { $0 += 1 }
        if let error { throw error }
        var result: [VerifiedModelFile] = []
        for (path, data) in files.sorted(by: { $0.key < $1.key }) {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            let digest = lie.contains(path) ? String(repeating: "0", count: 64) : sha256Hex(data)
            result.append(VerifiedModelFile(relativePath: claimedPath[path] ?? path, oid: .sha256(digest)))
        }
        progress(1)
        return result
    }
}
