import Foundation

/// One entry from Hugging Face's `tree` API response.
struct HFTreeEntry: Decodable, Sendable {
    let type: String
    let path: String
    let size: Int64
    /// Git blob sha1 for a non-LFS file. Hugging Face also reports it for LFS pointer files, so
    /// `lfs` (when present) always wins for the content oid.
    let oid: String
    let lfs: HFLFSInfo?
}

/// The `lfs` sub-object on LFS-tracked entries: the sha256 of the real file content.
struct HFLFSInfo: Decodable, Sendable {
    let oid: String
}

enum HuggingFaceTree {
    static func oid(for entry: HFTreeEntry) -> ModelFileOID {
        entry.lfs.map { .sha256($0.oid) } ?? .gitBlobSHA1(entry.oid)
    }

    /// Hugging Face paginates list endpoints with an RFC 5988-shaped `Link` header, e.g.
    /// `<https://huggingface.co/...&cursor=...>; rel="next"`. `nil` once there is no `rel="next"`.
    static func nextPageURL(from response: HTTPURLResponse) -> URL? {
        guard let linkHeader = response.value(forHTTPHeaderField: "Link") else { return nil }
        for part in linkHeader.split(separator: ",") {
            let segments = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard segments.count >= 2, segments[1] == "rel=\"next\"" else { continue }
            return URL(string: segments[0].trimmingCharacters(in: CharacterSet(charactersIn: "<>")))
        }
        return nil
    }
}
