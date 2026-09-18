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

struct SpeechModelStatus: Identifiable, Equatable, Sendable {
    let descriptor: SpeechModelDescriptor
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
