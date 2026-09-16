import Foundation
import os
import Observation

enum DiagnosticsEvent: Equatable, Sendable {
    case permissionRechecked, permissionRequested, eventTapRegistered, eventTapUnavailable
    case eventTapDisabled, eventTapReenabled, keyboardEventReceived
    case hotkeyMatched(action: HotkeyAction, phase: HotkeyPhase)
    case actionDispatched(action: HotkeyAction, phase: HotkeyPhase)
    case selectionAccessibility, selectionClipboard, selectionUnavailable
    case ttsSubmitted, ttsStopped, ttsReplayed, ttsFailed
    case dictation(DictationDiagnostic)
    case overlayFailed
    case speechModelDownloadStarted(backendID: String)
    case speechModelDownloadFinished(backendID: String)
    case speechModelDownloadFailed(backendID: String)
    /// Settings failed to decode even after per-field resilience (the saved blob wasn't a
    /// decodable settings object at all — e.g. not JSON, or not a JSON object). Carries only the
    /// byte count of the blob that failed: never its contents, never the raw decode error, which
    /// could otherwise echo fragments of the corrupt bytes back into a log.
    case settingsDecodeFailed(byteCount: Int)

    private static func speechBackendDisplayName(_ backendID: String) -> String {
        switch backendID {
        case "parakeet": "Parakeet"
        case "apple-speech": "Apple Speech"
        default: "Speech recognition"
        }
    }

    var message: String {
        switch self {
        case .permissionRechecked: "Permissions rechecked"
        case .permissionRequested: "Permission request opened"
        case .eventTapRegistered: "Event tap registered"
        case .eventTapUnavailable: "Event tap unavailable"
        case .eventTapDisabled: "Event tap disabled"
        case .eventTapReenabled: "Event tap re-enabled"
        case .keyboardEventReceived: "Keyboard event received"
        case let .hotkeyMatched(action, phase): "\(action.title) \(phase.title) matched"
        case let .actionDispatched(action, phase): "\(action.title) \(phase.title) dispatched"
        case .selectionAccessibility: "Selection acquired"
        case .selectionClipboard: "Selection acquired through clipboard fallback"
        case .selectionUnavailable: "Selection unavailable"
        case .ttsSubmitted: "Speech submitted"
        case .ttsStopped: "Speech stopped"
        case .ttsReplayed: "Speech replayed"
        case .ttsFailed: "Speech failed"
        case let .dictation(diagnostic): diagnostic.message
        case .overlayFailed: "Activity overlay failed"
        case let .speechModelDownloadStarted(backendID):
            "\(Self.speechBackendDisplayName(backendID)) model download started"
        case let .speechModelDownloadFinished(backendID):
            "\(Self.speechBackendDisplayName(backendID)) model download finished"
        case let .speechModelDownloadFailed(backendID):
            "\(Self.speechBackendDisplayName(backendID)) model download failed"
        case let .settingsDecodeFailed(byteCount):
            "Settings failed to decode (\(byteCount) bytes); restored defaults, blob preserved for recovery"
        }
    }
}

enum DictationFailureStage: Equatable, Sendable {
    case microphoneCapture, transcription, insertion

    var message: String {
        switch self {
        case .microphoneCapture: "microphone capture"
        case .transcription: "transcription"
        case .insertion: "insertion"
        }
    }
}

enum DictationDiagnostic: Equatable, Sendable {
    case listening, processing
    case inserted(TextInsertionMechanism)
    case failed(DictationFailureStage)

    var message: String {
        switch self {
        case .listening: "Dictation listening"
        case .processing: "Dictation processing"
        case let .inserted(mechanism):
            switch mechanism {
            case .accessibility: "Dictation inserted via accessibility"
            case .paste: "Dictation inserted via paste"
            }
        case let .failed(stage): "Dictation failed during \(stage.message)"
        }
    }
}

struct DiagnosticsBuffer: Sendable {
    private(set) var entries: [DiagnosticEntry] = []
    private let capacity: Int
    init(capacity: Int = 250) { self.capacity = max(1, capacity) }
    mutating func append(_ event: DiagnosticsEvent) {
        entries.append(.init(event: event))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }
    mutating func clear() { entries.removeAll() }
    var copyText: String { entries.map { $0.event.message }.joined(separator: "\n") }
}

struct DiagnosticEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let event: DiagnosticsEvent
    init(id: UUID = UUID(), timestamp: Date = Date(), event: DiagnosticsEvent) { self.id = id; self.timestamp = timestamp; self.event = event }
    func copyLine(formatter: DateFormatter = DiagnosticTimestampFormatter.local) -> String { "\(formatter.string(from: timestamp)) \(event.message)" }
}

enum DiagnosticTimestampFormatter {
    static let local: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
    static let fixed: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "HH:mm:ss"; return f }()
}

struct DiagnosticsCounters: Equatable, Sendable { var received = 0; var matched = 0; var dispatched = 0 }

@MainActor @Observable
final class DiagnosticsRecorder {
    private let logger = Logger(subsystem: "dev.relaymac.Relay", category: "diagnostics")
    private(set) var buffer: DiagnosticsBuffer
    private(set) var counters = DiagnosticsCounters()
    /// The most recent microphone capture's privacy-safe metadata (input sample rate, frame
    /// count, timestamp) — never audio samples, transcript text, or file paths. `nil` until the
    /// first dictation capture attempt completes (successfully or with `noUsableAudio`).
    private(set) var lastMicrophoneCaptureDiagnostics: MicrophoneCaptureDiagnostics?
    var entries: [DiagnosticEntry] { buffer.entries }
    init(capacity: Int = 250) { buffer = DiagnosticsBuffer(capacity: capacity) }
    func record(_ event: DiagnosticsEvent) {
        buffer.append(event)
        switch event { case .keyboardEventReceived: counters.received += 1; case .hotkeyMatched: counters.matched += 1; case .actionDispatched: counters.dispatched += 1; default: break }
        logger.info("\(event.message, privacy: .public)")
    }
    func clear() { buffer.clear(); counters = .init() }
    var copyText: String { entries.map { $0.copyLine() }.joined(separator: "\n") }
    /// Records the metadata-only diagnostics from one `MicrophoneCapture.stop()` attempt. Never
    /// logs it verbatim (unlike `record(_:)` above) — it's counts/rate/timestamp only, which is
    /// fine to hold for display, but there's no need to also duplicate it into `os_log`.
    func recordMicrophoneCapture(_ diagnostics: MicrophoneCaptureDiagnostics) {
        lastMicrophoneCaptureDiagnostics = diagnostics
    }
}

extension HotkeyPhase { var title: String { self == .pressed ? "pressed" : "released" } }
