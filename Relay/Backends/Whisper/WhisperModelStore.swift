import CryptoKit
import Foundation
import os

/// The Hugging Face-reported identity for one file inside a Whisper model's `.mlmodelc` bundle:
/// either the LFS-recorded sha256 (large weight files) or the git blob sha1
/// (`sha1("blob " + size + "\0" + content)`, small non-LFS sidecar files like `config.json`).
/// See docs/superpowers/spikes/2026-09-18-openai-whisper-models-feasibility-results.md section 2.
enum WhisperFileOID: Equatable, Sendable {
    case sha256(String)
    case gitBlobSHA1(String)
}

/// One file belonging to a Whisper model's runtime artifact, as reported by a `WhisperDownloader`
/// after it has been written to disk. `WhisperModelStore` verifies the file at `relativePath`
/// (resolved against the staging directory it gave the downloader) against `oid` before
/// promoting the model.
struct WhisperModelFile: Equatable, Sendable {
    /// Path relative to the model's directory, e.g. "config.json" or
    /// "AudioEncoder.mlmodelc/weights/weight.bin".
    let relativePath: String
    let oid: WhisperFileOID
}

/// The seam between `WhisperModelStore` and however model files actually get fetched (a live
/// Hugging Face downloader in production, a fake in tests). A `WhisperDownloader` is trusted only
/// to fetch bytes and report what checksum each one is *supposed* to have -- it does not itself
/// decide whether a download is trustworthy. `WhisperModelStore` independently hashes every file
/// once it lands and rejects the whole download if any file's actual content doesn't match the
/// oid reported here, so a downloader cannot promote an unverified file merely by claiming it
/// verified fine.
protocol WhisperDownloader: Sendable {
    /// Fetches every file belonging to `descriptor`'s runtime artifact into `directory` (a
    /// private, per-attempt staging directory `WhisperModelStore` owns and will discard on any
    /// failure), returning each file's path (relative to `directory`) and expected oid. `progress`
    /// may be called with a fraction in [0, 1] any number of times while the transfer is in
    /// flight; it may be called from any queue. Throws on any failure (network, HTTP error, an
    /// aborted transfer) -- files already written before the throw are the caller's
    /// responsibility to discard, not this method's.
    func download(
        _ descriptor: WhisperModelDescriptor,
        into directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [WhisperModelFile]
}

/// Errors `WhisperModelStore` itself throws (as opposed to a `WhisperDownloader`'s own errors,
/// which propagate unchanged).
enum WhisperModelStoreError: Error, Equatable, Sendable {
    /// A downloaded file's actual content did not hash to the oid the downloader reported for it.
    case checksumMismatch
}

/// Owns the on-disk lifecycle of Whisper model bundles: presence, download+verify, and removal.
/// Mirrors `FluidAudioParakeetEngine`/`FluidAudioKokoroEngine`'s presence-gate + atomic-promote
/// shape, generalized to a bundle of many files instead of one model.
///
/// Model files live at `<cacheDirectory>/<id>/`. A download first lands in a private staging
/// directory, `<cacheDirectory>/<id>.incomplete/`, that is never visible to `presence(of:)`.
/// Every file returned by the `WhisperDownloader` is hashed and compared against its reported
/// oid; only once *every* file verifies does `download` write a `.verified` marker into the
/// staging directory and atomically rename it to the ready directory (`<id>/`). Any failure --
/// download error, checksum mismatch, cancellation -- discards the staging directory and leaves
/// the ready directory (if any existed before this call) untouched, so a half-finished download
/// can never become selectable.
///
/// `presence(of:)` is deliberately network-free and does not re-hash anything: the expected oids
/// are only known at download time (fetched from Hugging Face's tree metadata), so there is
/// nothing to re-verify against offline. Instead it trusts the `.verified` marker as proof that
/// the atomic, fully-verified promote already happened -- the marker only ever exists inside a
/// directory that reached its final path via that one atomic rename.
struct WhisperModelStore: Sendable {
    private static let verifiedMarkerName = ".verified"

    let cacheDirectory: URL
    private let downloader: any WhisperDownloader
    private let logger = Logger(subsystem: "dev.relaymac.Relay", category: "whisper-model-store")

    init(cacheDirectory: URL, downloader: any WhisperDownloader) {
        self.cacheDirectory = cacheDirectory
        self.downloader = downloader
    }

    /// The directory a fully-downloaded model's files live in. Only meaningful (i.e. actually
    /// populated) once `presence(of:)` reports `true`.
    func modelDirectory(for id: WhisperModelID) -> URL {
        cacheDirectory.appendingPathComponent(id.rawValue, isDirectory: true)
    }

    /// Network-free. `true` only if the model's ready directory carries a `.verified` marker --
    /// see the type-level doc comment for why that alone is sufficient proof.
    func presence(of id: WhisperModelID) -> Bool {
        let markerURL = modelDirectory(for: id).appendingPathComponent(Self.verifiedMarkerName)
        return FileManager.default.fileExists(atPath: markerURL.path)
    }

    /// Downloads and verifies every file in `id`'s runtime artifact, promoting it atomically once
    /// every file checks out. Throws (and leaves `presence(of: id)` false) if the downloader
    /// fails or any file's checksum doesn't match; a previously-downloaded model at `id` is left
    /// untouched by a failed re-download attempt.
    func download(_ id: WhisperModelID, progress: @escaping @Sendable (Double) -> Void) async throws {
        let descriptor = WhisperModelCatalog.descriptor(for: id)
        let stagingDirectory = incompleteDirectory(for: id)

        try? FileManager.default.removeItem(at: stagingDirectory)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        do {
            let files = try await downloader.download(descriptor, into: stagingDirectory, progress: progress)
            for file in files {
                let fileURL = stagingDirectory.appendingPathComponent(file.relativePath)
                let data = try Data(contentsOf: fileURL)
                guard Self.verify(data: data, against: file.oid) else {
                    throw WhisperModelStoreError.checksumMismatch
                }
            }

            let markerURL = stagingDirectory.appendingPathComponent(Self.verifiedMarkerName)
            FileManager.default.createFile(atPath: markerURL.path, contents: Data())

            let readyDirectory = modelDirectory(for: id)
            try? FileManager.default.removeItem(at: readyDirectory)
            try FileManager.default.moveItem(at: stagingDirectory, to: readyDirectory)
        } catch {
            try? FileManager.default.removeItem(at: stagingDirectory)
            logger.debug("Whisper model download failed")
            throw error
        }
    }

    /// Deletes a downloaded model's files. A no-op (not an error) if the model wasn't present.
    func remove(_ id: WhisperModelID) async throws {
        let directory = modelDirectory(for: id)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return
        }
        try FileManager.default.removeItem(at: directory)
    }

    private func incompleteDirectory(for id: WhisperModelID) -> URL {
        cacheDirectory.appendingPathComponent("\(id.rawValue).incomplete", isDirectory: true)
    }

    private static func verify(data: Data, against oid: WhisperFileOID) -> Bool {
        switch oid {
        case .sha256(let expected):
            return hexDigest(SHA256.hash(data: data)) == expected.lowercased()
        case .gitBlobSHA1(let expected):
            var content = Data("blob \(data.count)\0".utf8)
            content.append(data)
            return hexDigest(Insecure.SHA1.hash(data: content)) == expected.lowercased()
        }
    }

    private static func hexDigest(_ digest: some Sequence<UInt8>) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Errors specific to `HuggingFaceWhisperDownloader`'s network/HTTP layer, kept separate from
/// `WhisperModelStoreError` (which covers only the store's own post-download verification).
enum WhisperDownloaderError: Error, Equatable, Sendable {
    /// The Hugging Face tree API (or a file fetch) returned a non-2xx HTTP status.
    case httpError
    /// The tree API response could not be decoded into the expected shape.
    case malformedResponse
}

/// Live `WhisperDownloader` backed directly by Hugging Face's REST API against
/// `argmaxinc/whisperkit-coreml` -- the CoreML mirror of the OpenAI Whisper checkpoints
/// WhisperKit loads (see docs/superpowers/spikes/2026-09-18-openai-whisper-models-feasibility-results.md
/// section 1-2). No WhisperKit API is used here: Relay owns download/verify itself and only ever
/// hands WhisperKit an already-verified local folder with `download: false`.
///
/// Two-step fetch per model, mirroring the spike's own `HFCatalog`/`WhisperModelStore` split:
/// 1. `GET /api/models/{repo}/tree/main/{subfolder}?recursive=true` to enumerate every file under
///    the model's runtime artifact folder, with each entry's `oid` (git blob sha1) or, for
///    LFS-tracked files, a nested `lfs.oid` (sha256). Paginated via the `Link: <url>; rel="next"`
///    response header, per Hugging Face's API convention.
/// 2. For each file, `GET /{repo}/resolve/main/{path}` to fetch its bytes directly into the
///    staging directory `WhisperModelStore` provided.
///
/// `.mlpackage/` source-copy files are filtered out of the tree before downloading anything --
/// WhisperKit only ever loads the compiled `.mlmodelc` bundle, and naively including the
/// `.mlpackage` copies roughly doubles the download for models that publish both (results doc
/// section 2, data quality note 1).
///
/// This type has not been exercised against the live network in this environment (no network
/// access here); it mirrors the spike's proven `HFCatalog`/`WhisperModelStore` mechanics
/// (docs/superpowers/spikes/2026-09-18-openai-whisper-models-feasibility-results.md sections 2
/// and 4) but its HTTP/JSON handling itself is untested beyond compiling.
struct HuggingFaceWhisperDownloader: WhisperDownloader {
    private static let repoID = "argmaxinc/whisperkit-coreml"
    private static let apiBase = URL(string: "https://huggingface.co/api/models")!
    private static let resolveBase = URL(string: "https://huggingface.co")!

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func download(
        _ descriptor: WhisperModelDescriptor,
        into directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [WhisperModelFile] {
        let entries = try await fetchTree(subfolder: descriptor.runtimeArtifact)
        let totalBytes = entries.reduce(Int64(0)) { $0 + $1.size }
        var completedBytes: Int64 = 0
        var manifest: [WhisperModelFile] = []

        for entry in entries {
            guard let relativePath = Self.relativePath(of: entry.path, under: descriptor.runtimeArtifact) else {
                continue
            }

            let destination = directory.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let remoteURL = Self.resolveBase
                .appendingPathComponent(Self.repoID)
                .appendingPathComponent("resolve/main")
                .appendingPathComponent(entry.path)
            let (temporaryURL, response) = try await session.download(from: remoteURL)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw WhisperDownloaderError.httpError
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporaryURL, to: destination)

            let oid: WhisperFileOID = entry.lfs.map { .sha256($0.oid) } ?? .gitBlobSHA1(entry.oid)
            manifest.append(WhisperModelFile(relativePath: relativePath, oid: oid))

            completedBytes += entry.size
            progress(totalBytes > 0 ? Double(completedBytes) / Double(totalBytes) : 1.0)
        }

        return manifest
    }

    /// Fetches and flattens every file (never directory) entry under `subfolder`, following
    /// Hugging Face's `Link` pagination header, filtering out `.mlpackage/` source copies.
    private func fetchTree(subfolder: String) async throws -> [HFTreeEntry] {
        var entries: [HFTreeEntry] = []
        var nextURL: URL? = Self.treeURL(subfolder: subfolder)

        while let url = nextURL {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw WhisperDownloaderError.httpError
            }
            guard let page = try? JSONDecoder().decode([HFTreeEntry].self, from: data) else {
                throw WhisperDownloaderError.malformedResponse
            }
            entries.append(contentsOf: page)
            nextURL = Self.nextPageURL(from: http)
        }

        return entries
            .filter { $0.type == "file" }
            .filter { !$0.path.contains(".mlpackage/") }
    }

    private static func treeURL(subfolder: String) -> URL {
        apiBase
            .appendingPathComponent(repoID)
            .appendingPathComponent("tree/main")
            .appendingPathComponent(subfolder)
            .appending(queryItems: [URLQueryItem(name: "recursive", value: "true")])
    }

    /// Hugging Face paginates list endpoints via an RFC 5988-shaped `Link` response header, e.g.
    /// `<https://huggingface.co/...&cursor=...>; rel="next"`. Returns `nil` once there is no
    /// `rel="next"` entry.
    private static func nextPageURL(from response: HTTPURLResponse) -> URL? {
        guard let linkHeader = response.value(forHTTPHeaderField: "Link") else {
            return nil
        }
        for part in linkHeader.split(separator: ",") {
            let segments = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard segments.count >= 2, segments[1] == "rel=\"next\"" else {
                continue
            }
            let urlSegment = segments[0].trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            return URL(string: urlSegment)
        }
        return nil
    }

    /// `entry.path` is the full repo path (e.g. "openai_whisper-tiny.en/config.json"); this
    /// strips the `subfolder/` prefix so the result is relative to the model's own directory.
    private static func relativePath(of path: String, under subfolder: String) -> String? {
        let prefix = subfolder + "/"
        guard path.hasPrefix(prefix) else {
            return nil
        }
        return String(path.dropFirst(prefix.count))
    }
}

/// One entry from Hugging Face's `tree` API response.
private struct HFTreeEntry: Decodable {
    let type: String
    let path: String
    let size: Int64
    /// Git blob sha1 for a non-LFS file; Hugging Face still reports this for LFS pointer files
    /// themselves, so `lfs` (when present) always takes precedence for the *content* oid.
    let oid: String
    let lfs: HFLFSInfo?
}

/// The `lfs` sub-object Hugging Face's tree API nests on LFS-tracked entries, carrying the
/// sha256 of the actual (non-pointer) file content.
private struct HFLFSInfo: Decodable {
    let oid: String
}
