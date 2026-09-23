import Foundation

/// Single-flight, download-aware loader for one heavyweight on-device model session. Shared by
/// the FluidAudio engines (Parakeet, Kokoro, PocketTTS), which each used to carry an identical
/// copy of this state machine. Error types stay engine-specific through the injected closures.
///
/// Rules (pinned by `ModelSessionLoaderTests`):
/// - Once a session is loaded, `load` is a no-op.
/// - Concurrent loads of the same kind share one underlying load.
/// - A download caller that finds a local-only load running waits for it (ignoring its outcome),
///   then starts its own download unless that local load produced a session.
/// - A local-only caller that finds a download running joins it only when local presence is
///   already validated; otherwise it fails fast with `modelsNotDownloaded()` rather than block on
///   a transfer it never asked for.
/// - `allowDownload: false` never calls `downloadAndLoad`, and calls `loadLocal` only after
///   `validateLocal` returned `true`. A positive validation is cached; a negative one never is.
///   Any non-cancellation failure clears the cache, because a failed FluidAudio load may have
///   deleted or replaced files on disk.
/// - `validateLocal` errors propagate as thrown (the engine maps them); `loadLocal` and
///   `downloadAndLoad` errors go through `mapLoadFailure`, except `CancellationError`.
actor ModelSessionLoader<Session: Sendable> {
    typealias Progress = @Sendable (Double) -> Void

    private enum LoadKind: Equatable {
        case localOnly
        case download
    }

    private let modelsNotDownloaded: @Sendable () -> any Error
    private let mapLoadFailure: @Sendable (any Error) -> any Error
    private let validateLocal: @Sendable () async throws -> Bool
    private let loadLocal: @Sendable () async throws -> Session
    private let downloadAndLoad: @Sendable (@escaping Progress) async throws -> Session

    /// The loaded session, or `nil` before a successful load and after `reset()`/`unload()`.
    private(set) var session: Session?
    private var inFlightLoad: (task: Task<Void, Error>, kind: LoadKind)?
    private var validatedModelsPresent: Bool

    init(
        validatedModelsPresent: Bool = false,
        modelsNotDownloaded: @escaping @Sendable () -> any Error,
        mapLoadFailure: @escaping @Sendable (any Error) -> any Error,
        validateLocal: @escaping @Sendable () async throws -> Bool,
        loadLocal: @escaping @Sendable () async throws -> Session,
        downloadAndLoad: @escaping @Sendable (@escaping Progress) async throws -> Session
    ) {
        self.validatedModelsPresent = validatedModelsPresent
        self.modelsNotDownloaded = modelsNotDownloaded
        self.mapLoadFailure = mapLoadFailure
        self.validateLocal = validateLocal
        self.loadLocal = loadLocal
        self.downloadAndLoad = downloadAndLoad
    }

    func load(allowDownload: Bool, progress: @escaping Progress) async throws {
        while true {
            if session != nil {
                return
            }
            guard let inFlightLoad else { break }

            switch (inFlightLoad.kind, allowDownload) {
            case (.localOnly, false), (.download, true):
                try await awaitAndClear(inFlightLoad.task)
                return

            case (.localOnly, true):
                // Let the local load get out of the way (ignoring its outcome), then re-evaluate
                // from the top. It may have produced a session, or another download caller that
                // waited on the same local load may already have started the download. Joining
                // that download avoids fetching the model twice.
                _ = try? await inFlightLoad.task.value
                clearIfCurrent(inFlightLoad.task)

            case (.download, false):
                guard validatedModelsPresent else {
                    throw modelsNotDownloaded()
                }
                try await awaitAndClear(inFlightLoad.task)
                return
            }
        }

        try await startLoad(allowDownload: allowDownload, progress: progress)
    }

    /// Cancels and awaits any in-flight load, then drops the session and forgets the cached
    /// validation. Call before deleting model files.
    func reset() async {
        if let inFlightLoad {
            inFlightLoad.task.cancel()
            _ = try? await inFlightLoad.task.value
            clearIfCurrent(inFlightLoad.task)
        }
        session = nil
        validatedModelsPresent = false
    }

    /// Awaits any in-flight load, then drops the session to free its memory. Keeps the cached
    /// validation: the files are still on disk, so the next local load can skip the check.
    func unload() async {
        if let inFlightLoad {
            _ = try? await inFlightLoad.task.value
            clearIfCurrent(inFlightLoad.task)
        }
        session = nil
    }

    private func startLoad(allowDownload: Bool, progress: @escaping Progress) async throws {
        let kind: LoadKind = allowDownload ? .download : .localOnly
        let task = Task { try await self.performLoad(allowDownload: allowDownload, progress: progress) }
        inFlightLoad = (task, kind)
        try await awaitAndClear(task)
    }

    /// Clears `inFlightLoad` only if it still refers to `task`, so a newer load started while
    /// this caller was suspended is never clobbered.
    private func awaitAndClear(_ task: Task<Void, Error>) async throws {
        do {
            try await task.value
            clearIfCurrent(task)
        } catch is CancellationError {
            clearIfCurrent(task)
            throw CancellationError()
        } catch {
            clearIfCurrent(task)
            validatedModelsPresent = false
            throw error
        }
    }

    private func clearIfCurrent(_ task: Task<Void, Error>) {
        if inFlightLoad?.task == task {
            inFlightLoad = nil
        }
    }

    private func performLoad(allowDownload: Bool, progress: @escaping Progress) async throws {
        if !allowDownload {
            guard try await modelsAreValidatedLocally() else {
                throw modelsNotDownloaded()
            }
        }

        let loaded: Session
        do {
            loaded = allowDownload ? try await downloadAndLoad(progress) : try await loadLocal()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw mapLoadFailure(error)
        }
        session = loaded
    }

    private func modelsAreValidatedLocally() async throws -> Bool {
        if validatedModelsPresent {
            return true
        }
        let valid = try await validateLocal()
        if valid {
            validatedModelsPresent = true
        }
        return valid
    }
}
