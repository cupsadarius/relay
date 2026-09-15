import Foundation

enum FocusState: String, Sendable, Equatable {
    case focused
    case notFocused
    case unknown
}

enum FocusConfidence: Int, Sendable, Comparable {
    case low = 0
    case medium = 1
    case high = 2
    static func < (lhs: FocusConfidence, rhs: FocusConfidence) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct FocusDecision: Sendable, Equatable {
    let state: FocusState
    let confidence: FocusConfidence
    let resolverID: String
    let reason: String

    static func focused(resolverID: String, reason: String) -> Self {
        .init(state: .focused, confidence: .high, resolverID: resolverID, reason: reason)
    }

    static func notFocused(resolverID: String, reason: String) -> Self {
        .init(state: .notFocused, confidence: .high, resolverID: resolverID, reason: reason)
    }

    static func unknown(resolverID: String, reason: String) -> Self {
        .init(state: .unknown, confidence: .low, resolverID: resolverID, reason: reason)
    }
}

struct FocusContext: Sendable {
    let frontmostApplication: FrontmostApplication?
    let sessions: [AgentSession]
    let now: Date
}

protocol FocusResolver: Sendable {
    var id: String { get }
    func supports(_ session: AgentSession) -> Bool
    func resolve(session: AgentSession, context: FocusContext) async -> FocusDecision
}

protocol SessionFocusResolving: Sendable {
    func resolve(session: AgentSession) async -> FocusDecision
}
