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
    /// The downloader's reported file list never included `tokenizer.json`. `WhisperModelStore`
    /// enforces this itself rather than trusting a `WhisperDownloader` to remember it, the same
    /// way it independently re-hashes every file rather than trusting a downloader's claimed oid
    /// -- see `WhisperKitContext`'s doc comment in WhisperRuntime.swift for why a missing
    /// `modelFolder/tokenizer.json` silently reintroduces a live Hugging Face fetch on first
    /// `activate()`.
    case missingTokenizer
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
/// nothing to re-verify against offline. Instead the `.verified` marker's *content* -- a JSON
/// array of every relative path that was verified at promote time -- lets `presence(of:)` confirm
/// the bundle is still intact: the marker's mere existence proves an atomic, fully-verified
/// promote happened once, but a bundle file can still be deleted or corrupted afterwards without
/// touching the marker, so `presence(of:)` also re-checks that every listed path still exists.
struct WhisperModelStore: Sendable {
    private static let verifiedMarkerName = ".verified"
    /// The file WhisperKit's local-first tokenizer search (`ModelUtilities.loadTokenizer`) checks
    /// for directly at the model folder's top level. `download` refuses to promote any model
    /// whose downloader-reported file list doesn't include this, regardless of what the
    /// downloader itself claims succeeded.
    static let requiredTokenizerFileName = "tokenizer.json"

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

    /// Network-free: reads the `.verified` marker's JSON file-manifest and re-checks that every
    /// listed path still exists under the model directory. Does not re-hash file contents (no
    /// expected checksums are available offline) -- only existence is re-checked. Returns `false`
    /// if the marker is missing, unreadable, or malformed, or if any listed file is gone.
    func presence(of id: WhisperModelID) -> Bool {
        let directory = modelDirectory(for: id)
        let markerURL = directory.appendingPathComponent(Self.verifiedMarkerName)
        guard let markerData = try? Data(contentsOf: markerURL) else {
            return false
        }
        guard let manifest = try? JSONDecoder().decode([String].self, from: markerData) else {
            return false
        }
        return manifest.allSatisfy { relativePath in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(relativePath).path)
        }
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
                guard try Self.verifyFile(at: fileURL, against: file.oid) else {
                    throw WhisperModelStoreError.checksumMismatch
                }
            }

            guard files.contains(where: { $0.relativePath == Self.requiredTokenizerFileName }) else {
                throw WhisperModelStoreError.missingTokenizer
            }

            let manifest = files.map(\.relativePath)
            let markerURL = stagingDirectory.appendingPathComponent(Self.verifiedMarkerName)
            try JSONEncoder().encode(manifest).write(to: markerURL)

            let readyDirectory = modelDirectory(for: id)
            try? FileManager.default.removeItem(at: readyDirectory)
            try FileManager.default.moveItem(at: stagingDirectory, to: readyDirectory)
        } catch {
            try? FileManager.default.removeItem(at: stagingDirectory)
            logger.debug("Whisper model download failed")
            throw error
        }
    }

    /// Deletes just the `.verified` marker, so `presence(of:)` reports `false` immediately --
    /// before the rest of a removal (unloading the runtime, then deleting the remaining files,
    /// both of which can take a moment) even starts. A no-op if the marker is already gone.
    ///
    /// Exists for `WhisperModelManager.removeModel` to call first: once this returns, no new
    /// caller that checks `presence(of:)` (e.g. `WhisperBackend.availability()`) can start a fresh
    /// activation of `id` and race the rest of the removal for its files.
    func invalidatePresence(of id: WhisperModelID) {
        let markerURL = modelDirectory(for: id).appendingPathComponent(Self.verifiedMarkerName)
        try? FileManager.default.removeItem(at: markerURL)
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

    /// Read size for `verifyFile`. Weight files are about 1 GB, so they are hashed in 1 MiB
    /// slices rather than loaded whole.
    static let verificationChunkSize = 1 << 20

    /// Streams the file at `url` through an incremental hasher and compares the digest with
    /// `oid`. Memory stays at about `chunkSize` whatever the file size. `.gitBlobSHA1` hashes the
    /// git blob header `"blob <size>\0"` before the content, exactly like `git hash-object`.
    /// Internal (not private) so tests can compare it against whole-file digests.
    static func verifyFile(
        at url: URL,
        against oid: WhisperFileOID,
        chunkSize: Int = verificationChunkSize
    ) throws -> Bool {
        precondition(chunkSize > 0)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        switch oid {
        case .sha256(let expected):
            var hasher = SHA256()
            try forEachChunk(of: handle, chunkSize: chunkSize) { hasher.update(data: $0) }
            return hexDigest(hasher.finalize()) == expected.lowercased()
        case .gitBlobSHA1(let expected):
            let size = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
            var hasher = Insecure.SHA1()
            hasher.update(data: Data("blob \(size)\0".utf8))
            try forEachChunk(of: handle, chunkSize: chunkSize) { hasher.update(data: $0) }
            return hexDigest(hasher.finalize()) == expected.lowercased()
        }
    }

    /// Calls `body` with successive reads of up to `chunkSize` bytes until EOF. Each read is
    /// wrapped in its own autorelease pool so bridged buffers are freed per chunk instead of
    /// piling up until the calling thread's pool drains.
    private static func forEachChunk(
        of handle: FileHandle,
        chunkSize: Int,
        _ body: (Data) -> Void
    ) throws {
        while true {
            let hasMore: Bool = try autoreleasepool {
                guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                    return false
                }
                body(chunk)
                return true
            }
            if !hasMore { return }
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

/// Live `WhisperDownloader` backed directly by Hugging Face's REST API against two repos per
/// model: `argmaxinc/whisperkit-coreml` -- the CoreML mirror of the OpenAI Whisper checkpoints
/// WhisperKit loads (see docs/superpowers/spikes/2026-09-18-openai-whisper-models-feasibility-results.md
/// section 1-2) -- for the `.mlmodelc` bundle, and each model's `WhisperModelDescriptor
/// .tokenizerRepo` (an `openai/whisper-*` repo) for `tokenizer.json`/`tokenizer_config.json`. No
/// WhisperKit API is used here: Relay owns download/verify itself and only ever hands WhisperKit
/// an already-verified local folder with `download: false`.
///
/// Two-step fetch per repo, mirroring the spike's own `HFCatalog`/`WhisperModelStore` split:
/// 1. `GET /api/models/{repo}/tree/main/{subfolder}?recursive=true` to enumerate every file under
///    a folder, with each entry's `oid` (git blob sha1) or, for LFS-tracked files, a nested
///    `lfs.oid` (sha256). Paginated via the `Link: <url>; rel="next"` response header, per
///    Hugging Face's API convention.
/// 2. For each file, `GET /{repo}/resolve/main/{path}` to fetch its bytes directly into the
///    staging directory `WhisperModelStore` provided.
///
/// `.mlpackage/` source-copy files are filtered out of the model tree before downloading anything
/// -- WhisperKit only ever loads the compiled `.mlmodelc` bundle, and naively including the
/// `.mlpackage` copies roughly doubles the download for models that publish both (results doc
/// section 2, data quality note 1).
///
/// The tokenizer repo's tree is filtered down to exactly `tokenizerFileNames` before downloading
/// anything -- that repo root also carries multi-hundred-MB PyTorch/Flax/TF checkpoint files
/// (`pytorch_model.bin`, `model.safetensors`, `flax_model.msgpack`, `tf_model.h5`) Relay has no
/// use for; naively fetching the whole tree would download those too. `tokenizer.json` and
/// `tokenizer_config.json` are the only two files
/// `ArgmaxCore.LanguageModelConfigurationFromHub.loadConfig(modelFolder:)` reads from a local
/// folder (`tokenizer.json` required, throws `Hub.HubClientError.configurationMissing` if
/// missing; `tokenizer_config.json` required by the one call site that matters here,
/// `AutoTokenizer.from(modelFolder:)`, which throws `TokenizerError.missingConfig` if it comes
/// back nil) -- verified directly against argmax-oss-swift 1.1.0's
/// Sources/ArgmaxCore/External/Hub/Hub.swift and Sources/ArgmaxCore/External/Tokenizers/Tokenizer.swift.
/// `config.json` is deliberately NOT re-fetched from the tokenizer repo: the model's own
/// `argmaxinc/whisperkit-coreml` `config.json` (already fetched as part of the runtime artifact)
/// is byte-for-byte the same transformers `WhisperConfig` JSON as the tokenizer repo's
/// `config.json` (confirmed by diffing both for `openai_whisper-tiny.en` / `openai/whisper-tiny.en`),
/// so fetching it again would be redundant, not a fix for a real gap.
///
/// Both fetched files land directly at the model directory's top level (not under a
/// `tokenizerRepo`-named subfolder), because `WhisperKitEngine.load`'s `tokenizerFolder:
/// modelFolder` makes `ModelUtilities.loadTokenizer`'s local-first search check
/// `modelFolder/tokenizer.json` directly (the `tokenizerFolder` search path, second in priority
/// order after the -- here always-missing -- hub-cache-shaped path) -- see WhisperRuntime.swift's
/// `WhisperKitEngine` doc comment.
///
/// This type has not been exercised against the live network from inside an XCTest in this
/// environment (the TDD tests in WhisperModelStoreTests.swift use a network-free fake); it
/// mirrors the spike's proven `HFCatalog`/`WhisperModelStore` mechanics
/// (docs/superpowers/spikes/2026-09-18-openai-whisper-models-feasibility-results.md sections 2
/// and 4), and the tokenizer repo's tree shape/file set was independently confirmed live against
/// Hugging Face's API while implementing this (see this task's report), but its HTTP/JSON
/// handling itself is untested beyond compiling and that manual `curl` verification.
struct HuggingFaceWhisperDownloader: WhisperDownloader {
    private static let modelRepoID = "argmaxinc/whisperkit-coreml"
    private static let apiBase = URL(string: "https://huggingface.co/api/models")!
    private static let resolveBase = URL(string: "https://huggingface.co")!
    /// The only files `WhisperModelStore` needs from a model's tokenizer repo -- see this type's
    /// doc comment for exactly which WhisperKit/ArgmaxCore code paths read each one.
    private static let tokenizerFileNames: Set<String> = ["tokenizer.json", "tokenizer_config.json"]

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func download(
        _ descriptor: WhisperModelDescriptor,
        into directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [WhisperModelFile] {
        let modelEntries = try await fetchTree(repoID: Self.modelRepoID, subfolder: descriptor.runtimeArtifact)
        let tokenizerEntries = try await fetchTree(repoID: descriptor.tokenizerRepo, subfolder: nil)
            .filter { Self.tokenizerFileNames.contains($0.path) }

        let totalBytes = (modelEntries + tokenizerEntries).reduce(Int64(0)) { $0 + $1.size }
        var completedBytes: Int64 = 0
        var manifest: [WhisperModelFile] = []

        for entry in modelEntries {
            guard let relativePath = Self.relativePath(of: entry.path, under: descriptor.runtimeArtifact) else {
                continue
            }
            try await downloadFile(repoID: Self.modelRepoID, remotePath: entry.path, to: directory.appendingPathComponent(relativePath))
            manifest.append(WhisperModelFile(relativePath: relativePath, oid: Self.oid(for: entry)))
            completedBytes += entry.size
            progress(totalBytes > 0 ? Double(completedBytes) / Double(totalBytes) : 1.0)
        }

        // Tokenizer repo entries are already relative (fetched at the repo root, no subfolder
        // prefix to strip) and land directly at the model directory's top level.
        for entry in tokenizerEntries {
            try await downloadFile(
                repoID: descriptor.tokenizerRepo,
                remotePath: entry.path,
                to: directory.appendingPathComponent(entry.path)
            )
            manifest.append(WhisperModelFile(relativePath: entry.path, oid: Self.oid(for: entry)))
            completedBytes += entry.size
            progress(totalBytes > 0 ? Double(completedBytes) / Double(totalBytes) : 1.0)
        }

        return manifest
    }

    private static func oid(for entry: HFTreeEntry) -> WhisperFileOID {
        entry.lfs.map { .sha256($0.oid) } ?? .gitBlobSHA1(entry.oid)
    }

    /// Downloads `repoID`'s `remotePath` to `destination`, creating any needed intermediate
    /// directories first. Throws `WhisperDownloaderError.httpError` on a non-2xx response.
    private func downloadFile(repoID: String, remotePath: String, to destination: URL) async throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let remoteURL = Self.resolveBase
            .appendingPathComponent(repoID)
            .appendingPathComponent("resolve/main")
            .appendingPathComponent(remotePath)
        let (temporaryURL, response) = try await session.download(from: remoteURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WhisperDownloaderError.httpError
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
    }

    /// Fetches and flattens every file (never directory) entry under `subfolder` (the repo root,
    /// if `nil`) in `repoID`, following Hugging Face's `Link` pagination header, filtering out
    /// `.mlpackage/` source copies.
    private func fetchTree(repoID: String, subfolder: String?) async throws -> [HFTreeEntry] {
        var entries: [HFTreeEntry] = []
        var nextURL: URL? = Self.treeURL(repoID: repoID, subfolder: subfolder)

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

    private static func treeURL(repoID: String, subfolder: String?) -> URL {
        var url = apiBase
            .appendingPathComponent(repoID)
            .appendingPathComponent("tree/main")
        if let subfolder {
            url = url.appendingPathComponent(subfolder)
        }
        return url.appending(queryItems: [URLQueryItem(name: "recursive", value: "true")])
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
