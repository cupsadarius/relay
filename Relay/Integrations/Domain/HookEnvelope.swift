import Foundation

struct HookEnvelope: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let provider: AgentProvider
    let rawPayload: String
    let parentPID: Int32
    let environment: [String: String]
    let capturedAt: Date
}

extension HookEnvelope {
    /// Largest encoded envelope, in bytes, excluding the trailing newline, that Relay's hook
    /// socket accepts as one line. `RelayHook` checks it before sending and `UnixSocketServer`
    /// enforces it on receipt. This file is compiled into both targets, so they cannot disagree.
    static let maxWireBytes = 2 * 1024 * 1024

    /// The exact bytes `RelayHook` writes for this envelope, or `nil` when they would exceed
    /// `maxWireBytes`. Slashes stay unescaped (`/`, not `\/`) so paths in `rawPayload` do not
    /// grow on the wire. Quotes, backslashes, and control characters still escape and can
    /// roughly double a payload, which is why the size is checked after encoding, not on the
    /// raw stdin byte count.
    func wireData() throws -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(self)
        return data.count <= Self.maxWireBytes ? data : nil
    }
}
