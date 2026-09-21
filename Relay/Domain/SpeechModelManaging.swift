import Foundation

struct SpeechModelDescriptor: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let detail: String?
    let approximateDownloadBytes: Int64?
}

enum SpeechModelInstallState: Equatable, Sendable {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
    case downloadFailed
}

struct SpeechModelCapabilities: OptionSet, Equatable, Sendable {
    let rawValue: UInt8

    static let download = Self(rawValue: 1 << 0)
    static let select = Self(rawValue: 1 << 1)
    static let remove = Self(rawValue: 1 << 2)
}

struct SpeechModelStatus: Identifiable, Equatable, Sendable {
    let descriptor: SpeechModelDescriptor
    let capabilities: SpeechModelCapabilities
    var installState: SpeechModelInstallState
    var isSelected: Bool
    var isLoaded: Bool
    var id: String { descriptor.id }
}

protocol SpeechModelManaging: Sendable {
    var backendID: String { get }
    func models() async -> [SpeechModelStatus]
    func downloadModel(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws
    func removeModel(_ id: String) async throws
    func selectModel(_ id: String) async throws
}
