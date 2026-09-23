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

extension FocusDecision {
    var isConfidentlyFocused: Bool { state == .focused && confidence == .high }
}

/// Everything a resolver may consult for ONE focus decision. Built once per decision and shared
/// by every resolver and every candidate session, so the frontmost app is looked up once and the
/// process table is read once.
struct FocusContext: Sendable {
    let frontmostApplication: FrontmostApplication?
    let sessions: [AgentSession]
    /// One `ps` snapshot for this decision; `nil` when it could not be taken (resolvers that
    /// need it answer `.unknown`).
    let processSnapshot: ProcessSnapshot?
}

/// The outcome of resolving focus across candidate sessions: the confidently focused session
/// (if any) plus every per-session decision made on the way, in order, for diagnostics.
struct FocusResolution: Sendable, Equatable {
    let focused: AgentSession?
    let decisions: [FocusDecision]
}

protocol FocusResolver: Sendable {
    var id: String { get }
    func supports(_ session: AgentSession) -> Bool
    func resolve(session: AgentSession, context: FocusContext) async -> FocusDecision
}

protocol SessionFocusResolving: Sendable {
    func resolve(session: AgentSession) async -> FocusDecision

    /// Resolves `sessions` in order and stops at the first confidently focused one. Conformers
    /// that can share one context across sessions (`FocusResolutionService`) use
    /// `processSnapshot` for it; the default below simply calls `resolve(session:)` per session.
    func resolveFocus(among sessions: [AgentSession], processSnapshot: ProcessSnapshot?) async -> FocusResolution
}

extension SessionFocusResolving {
    func resolveFocus(among sessions: [AgentSession], processSnapshot: ProcessSnapshot?) async -> FocusResolution {
        var decisions: [FocusDecision] = []
        for session in sessions {
            let decision = await resolve(session: session)
            decisions.append(decision)
            if decision.isConfidentlyFocused {
                return FocusResolution(focused: session, decisions: decisions)
            }
        }
        return FocusResolution(focused: nil, decisions: decisions)
    }
}
