import CryptoKit
import Foundation

/// The Hugging Face-reported identity of one model file: the LFS sha256 (large weight files) or
/// the git blob sha1 (`sha1("blob " + size + "\0" + content)`, small non-LFS files).
enum ModelFileOID: Equatable, Sendable {
    case sha256(String)
    case gitBlobSHA1(String)
}

enum ModelFileVerifier {
    /// Weight files are up to about 1 GB, so they are hashed in 1 MiB slices, not loaded whole.
    static let defaultChunkSize = 1 << 20

    /// Streams the file at `url` through an incremental hasher and compares the digest with `oid`
    /// (case-insensitively). Memory stays at about `chunkSize`. `.gitBlobSHA1` hashes the git blob
    /// header `"blob <size>\0"` before the content, exactly like `git hash-object`.
    static func verify(at url: URL, against oid: ModelFileOID, chunkSize: Int = defaultChunkSize) throws -> Bool {
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

    /// Calls `body` with successive reads of up to `chunkSize` bytes until EOF, each in its own
    /// autorelease pool so bridged buffers are freed per chunk.
    private static func forEachChunk(of handle: FileHandle, chunkSize: Int, _ body: (Data) -> Void) throws {
        while true {
            let hasMore: Bool = try autoreleasepool {
                guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { return false }
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
