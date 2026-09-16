import Foundation
import os

/// Why a line received on the hook socket was ignored. Never carries the
/// line's content — only the structural reason.
enum HookEnvelopeDropReason: Sendable {
    case invalidUTF8
    case malformedJSON
    case unsupportedSchemaVersion

    /// Structural label recorded in `IntegrationDiagnosticsLog` entries. Never the underlying
    /// parser error text — only this fixed, privacy-safe case name.
    var diagnosticsLabel: String {
        switch self {
        case .invalidUTF8: "invalid-utf8"
        case .malformedJSON: "malformed-json"
        case .unsupportedSchemaVersion: "unsupported-schema-version"
        }
    }
}

/// Receives newline-delimited `HookEnvelope` JSON from a `UnixSocketServer`,
/// validates and decodes each line, and republishes well-formed envelopes as
/// an `AsyncStream`.
///
/// Malformed input never crashes the listener: it is dropped and reported
/// only as a structural fact (a reason and a byte count) via the unified
/// logging system. Line contents, decoded text, working directories, and
/// environment variables are never logged.
final class HookEnvelopeReceiver: @unchecked Sendable {
    let events: AsyncStream<HookEnvelope>

    /// Whether the underlying `UnixSocketServer` currently holds an open
    /// listening socket.
    var isListening: Bool { server.isListening }

    private let server: UnixSocketServer
    private let decoder = JSONDecoder()
    private let logger = Logger(subsystem: "dev.relaymac.Relay", category: "integrations")
    private let continuation: AsyncStream<HookEnvelope>.Continuation
    private let diagnostics: IntegrationDiagnosticsLog

    init(
        server: UnixSocketServer = UnixSocketServer(),
        diagnostics: IntegrationDiagnosticsLog = IntegrationDiagnosticsLog()
    ) {
        self.server = server
        self.diagnostics = diagnostics

        var capturedContinuation: AsyncStream<HookEnvelope>.Continuation?
        events = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        // The AsyncStream body above runs synchronously, so this is always set.
        continuation = capturedContinuation!
    }

    /// Starts the underlying socket server at `path`. See
    /// `UnixSocketServer.start(path:onLine:)` for the socket safety rules.
    func start(path: String) throws {
        try server.start(path: path) { [weak self] line in
            self?.handle(line: line)
        }
    }

    /// Stops the underlying socket server and finishes `events`.
    func stop() {
        server.stop()
        continuation.finish()
    }

    private func handle(line: String) {
        let byteCount = line.utf8.count
        diagnostics.append(stage: "receiver", outcome: "line-received", detail: "\(byteCount) bytes")

        guard let data = line.data(using: .utf8) else {
            drop(.invalidUTF8, byteCount: byteCount)
            return
        }

        let envelope: HookEnvelope
        do {
            envelope = try decoder.decode(HookEnvelope.self, from: data)
        } catch {
            drop(.malformedJSON, byteCount: data.count)
            return
        }

        guard envelope.schemaVersion == 1 else {
            drop(.unsupportedSchemaVersion, byteCount: data.count)
            return
        }

        diagnostics.append(stage: "receiver", outcome: "envelope-decoded", detail: "provider=\(envelope.provider.rawValue)")
        continuation.yield(envelope)
    }

    private func drop(_ reason: HookEnvelopeDropReason, byteCount: Int) {
        switch reason {
        case .invalidUTF8:
            logger.log("malformed hook line dropped: invalid UTF-8 (\(byteCount, privacy: .public) bytes)")
        case .malformedJSON:
            logger.log("malformed hook line dropped: JSON decode failed (\(byteCount, privacy: .public) bytes)")
        case .unsupportedSchemaVersion:
            logger.log("hook line dropped: unsupported schema version (\(byteCount, privacy: .public) bytes)")
        }
        diagnostics.append(
            stage: "receiver",
            outcome: "dropped",
            detail: "\(reason.diagnosticsLabel) (\(byteCount) bytes)"
        )
    }
}
