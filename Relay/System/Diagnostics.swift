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
    var entries: [DiagnosticEntry] { buffer.entries }
    init(capacity: Int = 250) { buffer = DiagnosticsBuffer(capacity: capacity) }
    func record(_ event: DiagnosticsEvent) {
        buffer.append(event)
        switch event { case .keyboardEventReceived: counters.received += 1; case .hotkeyMatched: counters.matched += 1; case .actionDispatched: counters.dispatched += 1; default: break }
        logger.info("\(event.message, privacy: .public)")
    }
    func clear() { buffer.clear(); counters = .init() }
    var copyText: String { entries.map { $0.copyLine() }.joined(separator: "\n") }
}

extension HotkeyPhase { var title: String { self == .pressed ? "pressed" : "released" } }
