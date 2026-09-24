import Foundation

enum PinnedSnapshotDownloaderError: Error, Equatable, Sendable {
    case httpError
    case malformedResponse
    /// A pinned file is missing from the tree at the pinned SHA, or its tree oid differs from the
    /// pinned hash. Raised before any file is fetched.
    case pinnedHashMismatch
}

/// Live `SnapshotDownloading` against Hugging Face, always at the snapshot's **commit SHA**:
/// `GET /api/models/{repo}/tree/{sha}?recursive=true` (Link-paginated), then
/// `GET /{repo}/resolve/{sha}/{path}` per allowlisted file.
struct PinnedSnapshotDownloader: SnapshotDownloading {
    private static let apiBase = URL(string: "https://huggingface.co/api/models")!
    private static let resolveBase = URL(string: "https://huggingface.co")!

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func download(
        _ snapshot: PinnedSnapshot,
        into directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [VerifiedModelFile] {
        let entries = try await fetchTree(snapshot).filter { $0.type == "file" && snapshot.allowlist.contains($0.path) }
        for (path, pinned) in snapshot.pinnedSHA256 {
            guard let entry = entries.first(where: { $0.path == path }), HuggingFaceTree.oid(for: entry) == .sha256(pinned) else {
                throw PinnedSnapshotDownloaderError.pinnedHashMismatch
            }
        }

        let totalBytes = entries.reduce(Int64(0)) { $0 + $1.size }
        var completedBytes: Int64 = 0
        var files: [VerifiedModelFile] = []
        for entry in entries {
            try await fetchFile(snapshot, path: entry.path, to: directory.appendingPathComponent(entry.path))
            files.append(VerifiedModelFile(relativePath: entry.path, oid: HuggingFaceTree.oid(for: entry)))
            completedBytes += entry.size
            progress(totalBytes > 0 ? Double(completedBytes) / Double(totalBytes) : 1)
        }
        return files
    }

    private func fetchTree(_ snapshot: PinnedSnapshot) async throws -> [HFTreeEntry] {
        var entries: [HFTreeEntry] = []
        var nextURL: URL? = Self.apiBase
            .appendingPathComponent(snapshot.repo)
            .appendingPathComponent("tree")
            .appendingPathComponent(snapshot.revision)
            .appending(queryItems: [URLQueryItem(name: "recursive", value: "true")])
        while let url = nextURL {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw PinnedSnapshotDownloaderError.httpError
            }
            guard let page = try? JSONDecoder().decode([HFTreeEntry].self, from: data) else {
                throw PinnedSnapshotDownloaderError.malformedResponse
            }
            entries.append(contentsOf: page)
            nextURL = HuggingFaceTree.nextPageURL(from: http)
        }
        return entries
    }

    private func fetchFile(_ snapshot: PinnedSnapshot, path: String, to destination: URL) async throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let url = Self.resolveBase
            .appendingPathComponent(snapshot.repo)
            .appendingPathComponent("resolve")
            .appendingPathComponent(snapshot.revision)
            .appendingPathComponent(path)
        let (temporaryURL, response) = try await session.download(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PinnedSnapshotDownloaderError.httpError
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
    }
}
