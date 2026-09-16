import Foundation

#if canImport(Darwin)
import Darwin
#endif

// MARK: - Wire-only types
//
// RelayHook is a standalone executable and cannot import the Relay app
// target, so the wire format is intentionally duplicated here. Keep these in
// sync with `Relay/Integrations/Domain/HookEnvelope.swift` and
// `AgentProvider.swift`. Wire schema version is `1`.

private enum WireAgentProvider: String, Codable {
    case claudeCode = "claude-code"
    case codex = "codex"
}

private struct WireHookEnvelope: Codable {
    let schemaVersion: Int
    let provider: WireAgentProvider
    let rawPayload: String
    let parentPID: Int32
    let environment: [String: String]
    let capturedAt: Date
}

// MARK: - Constants

/// Reject stdin larger than this before building an envelope at all.
private let maxInputBytes = 1_500 * 1_024 // 1.5 MiB

private let environmentAllowlist = [
    "TERM_PROGRAM", "TERM", "TMUX", "TMUX_PANE",
    "HERDR_SOCKET_PATH", "HERDR_ACTIVE_WORKSPACE_ID",
    "HERDR_ACTIVE_TAB_ID", "HERDR_ACTIVE_PANE_ID",
    "HERDR_PANE_ID", "GHOSTTY_RESOURCES_DIR",
]

// MARK: - Debug logging
//
// Debug output is opt-in via RELAY_HOOK_DEBUG=1 and must never contain
// payload text (assistant message content, cwd, raw hook JSON). Only
// structural facts (byte counts, provider name, success/failure) are
// permitted, on stderr only.

private let debugEnabled = ProcessInfo.processInfo.environment["RELAY_HOOK_DEBUG"] == "1"

private func debugLog(_ message: @autoclosure () -> String) {
    guard debugEnabled else { return }
    let line = "[RelayHook] \(message())\n"
    FileHandle.standardError.write(Data(line.utf8))
}

// MARK: - Argument parsing

private func parseProvider(from arguments: [String]) -> WireAgentProvider? {
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        if argument == "--provider" {
            let valueIndex = index + 1
            guard valueIndex < arguments.count else { return nil }
            return WireAgentProvider(rawValue: arguments[valueIndex])
        }
        if argument.hasPrefix("--provider=") {
            let value = String(argument.dropFirst("--provider=".count))
            return WireAgentProvider(rawValue: value)
        }
        index += 1
    }
    return nil
}

// MARK: - stdin

// MARK: - main

func runRelayHook() {
    let provider = parseProvider(from: Array(CommandLine.arguments.dropFirst()))
    debugLog("provider=\(provider?.rawValue ?? "unknown")")

    // Bounded chunked read: never buffers more than `maxInputBytes + 1`
    // bytes, so an oversized or endless stdin stream cannot exhaust memory
    // before the size check below runs.
    let inputData = BoundedStdinReader.read(from: .standardInput, maxBytes: maxInputBytes)
    debugLog("stdinBytes=\(inputData.count)")

    guard let provider else {
        debugLog("skip=missing-or-invalid-provider")
        finish()
    }

    guard inputData.count <= maxInputBytes else {
        debugLog("skip=oversized-input")
        finish()
    }

    guard let rawPayload = String(data: inputData, encoding: .utf8) else {
        debugLog("skip=invalid-utf8")
        finish()
    }

    var environment: [String: String] = [:]
    let processEnvironment = ProcessInfo.processInfo.environment
    for key in environmentAllowlist {
        if let value = processEnvironment[key] {
            environment[key] = value
        }
    }

    let envelope = WireHookEnvelope(
        schemaVersion: 1,
        provider: provider,
        rawPayload: rawPayload,
        parentPID: getppid(),
        environment: environment,
        capturedAt: Date()
    )

    do {
        let data = try JSONEncoder().encode(envelope)
        let client = HookTransportClient(socketPath: HookTransportClient.defaultSocketPath)
        // Delivery is best-effort and bounded by a short total deadline
        // (connect + write). Relay may not be running, the socket may not
        // exist, or the peer may be hung — none of that may ever block or
        // steer the calling coding agent.
        let delivered = client.send(data)
        debugLog(delivered ? "send=success" : "send=failed")
    } catch {
        debugLog("skip=envelope-encoding-failed")
    }

    finish()
}

/// Always writes the harmless success payload and exits 0, on every path.
private func finish() -> Never {
    FileHandle.standardOutput.write(Data("{}\n".utf8))
    exit(EXIT_SUCCESS)
}

runRelayHook()
