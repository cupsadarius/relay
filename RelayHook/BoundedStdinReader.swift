import Foundation

/// Reads from a `FileHandle` in fixed-size chunks, stopping as soon as
/// `maxBytes + 1` bytes have been buffered rather than reading the source to
/// EOF first. This bounds worst-case memory to roughly `maxBytes` regardless
/// of how much data the peer actually sends.
///
/// - Important: this file is compiled into both the `RelayHook` executable
///   target and the `Relay` app target (see `project.yml`) so it can be
///   unit tested via `@testable import Relay`. Keep it self-contained
///   (Foundation only).
enum BoundedStdinReader {
    /// Reads at most `maxBytes + 1` bytes from `handle`. The `+ 1` sentinel
    /// byte lets a caller distinguish "exactly at the cap" from "over the
    /// cap" without ever buffering a second full copy of an oversized input.
    static func read(from handle: FileHandle, maxBytes: Int, chunkSize: Int = 64 * 1024) -> Data {
        var buffer = Data()
        buffer.reserveCapacity(min(maxBytes + 1, chunkSize))

        while buffer.count <= maxBytes {
            let remaining = maxBytes + 1 - buffer.count
            let toRead = min(chunkSize, remaining)
            let chunk = handle.readData(ofLength: toRead)
            if chunk.isEmpty { break } // EOF
            buffer.append(chunk)
        }

        return buffer
    }
}
