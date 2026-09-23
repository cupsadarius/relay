import Foundation

/// Splits a byte stream into newline-terminated UTF-8 lines in O(n): every byte is scanned once
/// (`scannedCount` remembers how far a partial line has been searched), and consumed lines are
/// compacted out of the buffer once per `append`, not once per line.
///
/// Value type, confined to `UnixSocketServer`'s serial queue through its owning connection.
struct NewlineFramer {
    let maxLineBytes: Int
    private var buffer: [UInt8] = []
    private var scannedCount = 0

    init(maxLineBytes: Int) {
        self.maxLineBytes = maxLineBytes
    }

    var bufferedByteCount: Int { buffer.count }

    /// Appends `bytes` and calls `onLine` once per complete line (without its newline).
    /// Newline-terminated lines longer than `maxLineBytes` are skipped and reported via
    /// `onOversizedLine` with their byte count, and the lines after them still arrive. Lines
    /// that are not valid UTF-8 are skipped silently. Returns `true` when the pending partial
    /// line already exceeds `maxLineBytes`: that is reported via `onOversizedUnterminated` with
    /// the buffered byte count, the buffer is discarded, and the caller must close the
    /// connection, bounding memory.
    mutating func append(
        _ bytes: ArraySlice<UInt8>,
        onLine: (String) -> Void,
        onOversizedLine: (Int) -> Void,
        onOversizedUnterminated: (Int) -> Void
    ) -> Bool {
        buffer.append(contentsOf: bytes)

        var lineStart = 0
        var searchStart = scannedCount
        while let newlineIndex = buffer[searchStart...].firstIndex(of: UInt8(ascii: "\n")) {
            if newlineIndex - lineStart > maxLineBytes {
                onOversizedLine(newlineIndex - lineStart)
            } else if let line = String(bytes: buffer[lineStart..<newlineIndex], encoding: .utf8) {
                onLine(line)
            }
            lineStart = newlineIndex + 1
            searchStart = lineStart
        }
        if lineStart > 0 {
            buffer.removeFirst(lineStart)
        }
        scannedCount = buffer.count

        if buffer.count > maxLineBytes {
            onOversizedUnterminated(buffer.count)
            buffer.removeAll(keepingCapacity: false)
            scannedCount = 0
            return true
        }
        return false
    }
}
