import Foundation
import os

/// One downloaded file and the oid the downloader says it should have.
struct VerifiedModelFile: Equatable, Sendable {
    let relativePath: String
    let oid: ModelFileOID
}

/// A Hugging Face snapshot pinned to a commit SHA.
struct PinnedSnapshot: Equatable, Sendable {
    let repo: String
    /// A 40-hex commit SHA, never a branch name.
    let revision: String
    /// Only these repo paths are downloaded.
    let allowlist: Set<String>
    /// The download fails unless every one of these is present.
    let requiredFiles: Set<String>
    /// Path → lowercase sha256 the file must have, whatever the tree reports.
    let pinnedSHA256: [String: String]
}

/// Fetches a snapshot's files into a staging directory. Trusted only to fetch bytes and report
/// oids: `VerifiedModelStore` re-hashes everything itself.
protocol SnapshotDownloading: Sendable {
    func download(
        _ snapshot: PinnedSnapshot,
        into directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [VerifiedModelFile]
}

enum VerifiedModelStoreError: Error, Equatable, Sendable {
    case checksumMismatch
    case missingRequiredFile
}

/// On-disk lifecycle of pinned model snapshots (spec §13.1). A model lives at `<root>/<name>/`;
/// a download lands in `<root>/<name>.incomplete/`, is verified file by file, gets a `.verified`
/// JSON manifest, and is atomically renamed into place. Any failure discards the staging folder
/// and leaves an existing ready folder untouched. `presence` is network-free and re-checks only
/// that every manifest file still exists.
struct VerifiedModelStore: Sendable {
    private static let verifiedMarkerName = ".verified"
    private static let incompleteSuffix = ".incomplete"

    let root: URL
    private let downloader: any SnapshotDownloading
    private let logger = Logger(subsystem: "dev.relaymac.Relay", category: "model-store")

    init(root: URL, downloader: any SnapshotDownloading) {
        self.root = root
        self.downloader = downloader
    }

    func directory(named name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }

    func presence(of name: String) -> Bool {
        let directory = directory(named: name)
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(Self.verifiedMarkerName)),
            let manifest = try? JSONDecoder().decode([String].self, from: data)
        else { return false }
        return manifest.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    /// Downloads, verifies and promotes `snapshot` as `<root>/<name>/`. After a successful promote,
    /// deletes every other entry in `root` whose name starts with `siblingPrefix` (older revisions
    /// and their staging folders).
    func download(
        _ snapshot: PinnedSnapshot,
        as name: String,
        siblingPrefix: String?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let staging = root.appendingPathComponent(name + Self.incompleteSuffix, isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        do {
            let files = try await downloader.download(snapshot, into: staging, progress: progress)
            for file in files {
                if let pinned = snapshot.pinnedSHA256[file.relativePath], file.oid != .sha256(pinned) {
                    throw VerifiedModelStoreError.checksumMismatch
                }
                guard try ModelFileVerifier.verify(at: staging.appendingPathComponent(file.relativePath), against: file.oid) else {
                    throw VerifiedModelStoreError.checksumMismatch
                }
            }
            let paths = Set(files.map(\.relativePath))
            guard snapshot.requiredFiles.isSubset(of: paths), Set(snapshot.pinnedSHA256.keys).isSubset(of: paths) else {
                throw VerifiedModelStoreError.missingRequiredFile
            }

            try JSONEncoder().encode(files.map(\.relativePath)).write(to: staging.appendingPathComponent(Self.verifiedMarkerName))
            let ready = directory(named: name)
            try? FileManager.default.removeItem(at: ready)
            try FileManager.default.moveItem(at: staging, to: ready)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            logger.debug("Model download failed")
            throw error
        }

        if let siblingPrefix { sweepSiblings(prefix: siblingPrefix, keeping: name) }
    }

    /// Deletes only the `.verified` marker, so `presence` is `false` at once (removal step 1).
    func invalidatePresence(of name: String) {
        try? FileManager.default.removeItem(at: directory(named: name).appendingPathComponent(Self.verifiedMarkerName))
    }

    /// Deletes a model folder. A no-op when it is absent.
    func remove(_ name: String) async throws {
        let directory = directory(named: name)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    private func sweepSiblings(prefix: String, keeping name: String) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
        for entry in entries where entry.hasPrefix(prefix) && entry != name {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(entry))
        }
    }
}
