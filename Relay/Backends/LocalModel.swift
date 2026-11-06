import Foundation

/// One on-device model: a network-free presence check, a single-flight load that returns the
/// session, and removal. Each backend builds one from its `XModelLoading` test seam.
struct LocalModel<Session: Sendable>: Sendable {
    typealias Progress = @Sendable (Double) -> Void

    struct Removal: Sendable {
        let deleteFiles: @Sendable () async throws -> Void
        /// Thrown when the files are still present after `deleteFiles`.
        let filesRemain: any Error
    }

    private let isPresent: @Sendable () async -> Bool
    private let loader: ModelSessionLoader<Session>
    private let removal: Removal?

    init(isPresent: @escaping @Sendable () async -> Bool, loader: ModelSessionLoader<Session>, removal: Removal?) {
        self.isPresent = isPresent
        self.loader = loader
        self.removal = removal
    }

    /// Whether the model files are on disk. Never loads or downloads.
    func modelsArePresent() async -> Bool {
        await isPresent()
    }

    /// Returns the loaded session, loading it first. Reaches the network only when
    /// `allowDownload` is true; see `ModelSessionLoader` for the rules.
    @discardableResult
    func load(allowDownload: Bool = false, progress: @escaping Progress = { _ in }) async throws -> Session {
        try await loader.load(allowDownload: allowDownload, progress: progress)
    }

    /// Cancels any load, drops the session, then deletes the files.
    func remove() async throws {
        guard let removal else { throw SpeechModelManagerError.removeNotSupported }
        await loader.reset()
        try await removal.deleteFiles()
        guard await !isPresent() else { throw removal.filesRemain }
    }
}
