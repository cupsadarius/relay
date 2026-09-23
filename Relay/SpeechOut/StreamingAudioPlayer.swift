import AVFoundation
import Foundation

/// The single production playback seam. `TTSRouter` drives one shared player for every provider:
/// a backend produces a provider-neutral `TTSAudioSource`, the player pulls PCM frames from it,
/// converts them to the output device format, and schedules them - emitting the standard
/// `TTSPlaybackEvent` lifecycle (`started -> level* -> finished|cancelled|failed`).
///
/// `startPlayback(_:sessionID:)` returns as soon as playback has actually started (after
/// prebuffering, or immediately once an empty/short source ends before reaching the prebuffer
/// threshold) - never waiting for the terminal event, which is delivered later through `onEvent`.
/// It THROWS (emitting no terminal event) only when playback never started, so `TTSRouter` can
/// fall back to the next backend. Once `.started` has fired the router is committed: a later
/// source failure drains already-scheduled audio and ends the session as `.failed` rather than
/// restarting it elsewhere.
@MainActor
protocol StreamingAudioPlaying: AnyObject {
    var onEvent: (@MainActor (TTSPlaybackEvent) -> Void)? { get set }
    func startPlayback(_ source: any TTSAudioSource, sessionID: UUID) async throws
    func stop()
}

/// The audio-output device seam. Production wraps `AVAudioEngine`/`AVAudioPlayerNode`; tests inject
/// a fake that reports a real `AVAudioFormat` (so conversion runs) and lets the test fire
/// buffer-played callbacks deterministically (so demand-bounded scheduling can be verified without
/// a real audio device).
@MainActor
protocol AudioOutputNode: AnyObject {
    var outputFormat: AVAudioFormat { get }
    /// Set by the player. Called on the main actor when the device configuration changes under the
    /// node (a route change); nothing already scheduled will ever play.
    var onConfigurationChange: (@MainActor () -> Void)? { get set }
    func start() throws
    func play()
    func stop()
    func schedule(_ buffer: AVAudioPCMBuffer, onPlayed: @escaping @Sendable @MainActor () -> Void)
}

/// Production `AudioOutputNode`: one `AVAudioPlayerNode` connected to the main mixer at the mixer's
/// own output format, so the realtime render loop never resamples (every incoming frame is
/// converted to `outputFormat` up front, off the render thread).
@MainActor
final class AVEngineOutputNode: AudioOutputNode {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    let outputFormat: AVAudioFormat
    var onConfigurationChange: (@MainActor () -> Void)?
    private var configurationObserver: AudioEngineConfigurationObserver?

    init(notificationCenter: NotificationCenter = .default) {
        engine.attach(playerNode)
        outputFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.connect(playerNode, to: engine.mainMixerNode, format: outputFormat)
        configurationObserver = AudioEngineConfigurationObserver(engine: engine, center: notificationCenter) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let current = self.engine.mainMixerNode.outputFormat(forBus: 0)
                guard AudioEngineRouteChangeDecision.isDisruptive(
                    isEngineRunning: self.engine.isRunning,
                    installedSampleRate: self.outputFormat.sampleRate,
                    installedChannelCount: self.outputFormat.channelCount,
                    currentSampleRate: current.sampleRate,
                    currentChannelCount: current.channelCount
                ) else {
                    // Ignore spurious posts where the engine keeps running with the same format:
                    // AVFoundation stops the engine on a real route change, so `outputFormat`
                    // (fixed at connect time) still matches what the mixer actually produces, and
                    // already-scheduled and future buffers remain valid. Failing here would end
                    // healthy playback on every such spurious post.
                    return
                }
                self.onConfigurationChange?()
            }
        }
    }

    func start() throws { try engine.start() }
    func play() { playerNode.play() }

    func stop() {
        playerNode.stop()
        engine.stop()
    }

    func schedule(_ buffer: AVAudioPCMBuffer, onPlayed: @escaping @Sendable @MainActor () -> Void) {
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            Task { @MainActor in onPlayed() }
        }
    }
}

/// Errors raised by `StreamingAudioPlayer` itself (as opposed to ones AVFoundation raises while
/// building the engine graph or converting a buffer, which are propagated as-is).
enum StreamingAudioPlayerError: Error, Equatable, Sendable {
    case invalidSourceFormat
    case unsupportedChannelCount(Int)
    case converterCreationFailed
    case bufferAllocationFailed
    case conversionFailed
    case outputConfigurationChanged
}

@MainActor
final class StreamingAudioPlayer: StreamingAudioPlaying {
    private struct PendingBuffer {
        let buffer: AVAudioPCMBuffer
        let duration: TimeInterval
        let level: Float
    }

    /// How much audio to buffer before starting playback, trading a little latency for headroom
    /// against synthesis briefly falling behind real time.
    private static let prebufferSeconds: TimeInterval = 0.6
    /// The scheduled-ahead ceiling. The player stops pulling the source once this much converted
    /// audio is scheduled but not yet played, so upstream backpressure reflects real audio ahead of
    /// playback instead of letting the whole response accumulate inside `AVAudioPlayerNode`.
    private static let maxScheduledAheadSeconds: TimeInterval = 1.5

    var onEvent: (@MainActor (TTSPlaybackEvent) -> Void)?

    private let makeOutputNode: @MainActor () -> any AudioOutputNode

    private var outputNode: (any AudioOutputNode)?
    private var converter: AVAudioConverter?
    private var converterInputFormat: TTSAudioFormat?

    private var currentSessionID: UUID?
    private var activeSource: (any TTSAudioSource)?
    private var pumpTask: Task<Void, Never>?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var capacityWaiters: [CheckedContinuation<Void, Never>] = []

    private var pending: [PendingBuffer] = []
    private var pendingDuration: TimeInterval = 0
    private var scheduledDuration: TimeInterval = 0
    private var playedDuration: TimeInterval = 0
    private var scheduledCount = 0
    private var playedCount = 0
    private var sourceFinished = false
    private var sourceFailure: (any Error)?
    private var started = false
    private var explicitlyStopped = false

    init(makeOutputNode: @escaping @MainActor () -> any AudioOutputNode = { AVEngineOutputNode() }) {
        self.makeOutputNode = makeOutputNode
    }

    func startPlayback(_ source: any TTSAudioSource, sessionID: UUID) async throws {
        // Guards against leaking a previous call's continuation if this player is (unexpectedly)
        // asked to start a new session while a prior `startPlayback` is still awaiting its start.
        resumeStart(throwing: CancellationError())
        tearDownPlayback(cancelSource: true)

        currentSessionID = sessionID
        activeSource = source
        sourceFinished = false
        sourceFailure = nil
        pending = []
        pendingDuration = 0
        scheduledDuration = 0
        playedDuration = 0
        scheduledCount = 0
        playedCount = 0
        started = false
        explicitlyStopped = false

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            startContinuation = continuation
            pumpTask = Task { @MainActor [weak self] in
                await self?.pump(source, sessionID: sessionID)
            }
        }
    }

    func stop() {
        guard let sessionID = currentSessionID else { return }
        explicitlyStopped = true
        let source = activeSource
        tearDownPlayback(cancelSource: false)
        currentSessionID = nil
        activeSource = nil
        resumeStart()
        onEvent?(.cancelled(sessionID: sessionID))
        if let source {
            Task { await source.cancel() }
        }
    }

    // MARK: - Pump

    private func pump(_ source: any TTSAudioSource, sessionID: UUID) async {
        do {
            while let frame = try await source.next() {
                guard currentSessionID == sessionID, !explicitlyStopped else { return }
                guard !frame.samples.isEmpty else { continue }

                let converted = try convert(frame)
                let pendingBuffer = PendingBuffer(
                    buffer: converted,
                    duration: Double(converted.frameLength) / converted.format.sampleRate,
                    level: AudioBufferUtilities.level(of: frame.samples)
                )

                if started {
                    await waitForSchedulingCapacity(sessionID: sessionID)
                    guard currentSessionID == sessionID, !explicitlyStopped else { return }
                    schedule(pendingBuffer, sessionID: sessionID)
                } else {
                    pending.append(pendingBuffer)
                    pendingDuration += pendingBuffer.duration
                    if pendingDuration >= Self.prebufferSeconds {
                        try beginPlayback(sessionID: sessionID)
                    }
                }
            }
        } catch is CancellationError {
            guard currentSessionID == sessionID, !explicitlyStopped else { return }
            if started {
                endCancelled(sessionID: sessionID)
            } else {
                // Pre-start: `startPlayback` throws `CancellationError`, which `TTSRouter`
                // rethrows as cancellation rather than falling back to another backend.
                handleSourceFailure(CancellationError(), sessionID: sessionID)
            }
            return
        } catch {
            guard currentSessionID == sessionID, !explicitlyStopped else { return }
            handleSourceFailure(error, sessionID: sessionID)
            return
        }

        guard currentSessionID == sessionID else { return }
        sourceFinished = true
        if !started {
            do {
                try beginPlayback(sessionID: sessionID)
            } catch {
                handleSourceFailure(error, sessionID: sessionID)
                return
            }
        }
        checkForCompletion(sessionID: sessionID)
    }

    /// A source failure (including a pre-start `CancellationError`; a post-start one goes through
    /// `endCancelled`) or an engine-start failure. Before playback
    /// started, resolves the still-pending `startContinuation` by throwing (no terminal event) - the
    /// shape `TTSRouter` maps to a fallback-worthy error. Once playback has started there is no one
    /// awaiting a throw, so the failure is remembered and reported as `.failed` only after already
    /// scheduled valid audio has drained.
    private func handleSourceFailure(_ error: any Error, sessionID: UUID) {
        guard currentSessionID == sessionID, !explicitlyStopped else { return }

        if !started {
            tearDownPlayback(cancelSource: false)
            currentSessionID = nil
            activeSource = nil
            resumeStart(throwing: error)
            return
        }

        sourceFailure = error
        sourceFinished = true
        resumeCapacityWaiters()
        checkForCompletion(sessionID: sessionID)
    }

    /// The output device changed under the node. Nothing scheduled will play and no played-back
    /// callback will arrive, so waiting would stall until the speech watchdog fires. End now:
    /// - Before `.started`, `startPlayback` throws, so the router may fall back.
    /// - After it, the session ends `.failed`.
    /// Either way the healthy source is cancelled.
    private func handleOutputConfigurationChange() {
        guard let sessionID = currentSessionID, !explicitlyStopped else { return }
        let wasStarted = started
        tearDownPlayback(cancelSource: true)
        currentSessionID = nil
        activeSource = nil
        if wasStarted {
            onEvent?(.failed(sessionID: sessionID))
        } else {
            resumeStart(throwing: StreamingAudioPlayerError.outputConfigurationChanged)
        }
    }

    /// The source reported cancellation after playback started, without `stop()` being called
    /// on this player (e.g. its producer was cancelled). Per the `TTSAudioSource` contract that
    /// is a cancellation, not a failure: stop output now, without draining, and end the session
    /// as `.cancelled`, the same terminal event `stop()` emits.
    private func endCancelled(sessionID: UUID) {
        tearDownPlayback(cancelSource: false)
        currentSessionID = nil
        activeSource = nil
        onEvent?(.cancelled(sessionID: sessionID))
    }

    /// Flushes buffers accumulated during the prebuffer window, starts the output node, and emits
    /// `.started` exactly once - the one moment `startPlayback`'s pending continuation resolves.
    private func beginPlayback(sessionID: UUID) throws {
        guard currentSessionID == sessionID else { return }

        // An empty-but-successful source completes without ever building an audio graph.
        if pending.isEmpty {
            started = true
            onEvent?(.started(sessionID: sessionID))
            resumeStart()
            return
        }

        guard let outputNode else { throw StreamingAudioPlayerError.invalidSourceFormat }
        for item in pending {
            schedule(item, sessionID: sessionID)
        }
        pending.removeAll(keepingCapacity: false)
        pendingDuration = 0

        try outputNode.start()
        outputNode.play()
        started = true
        onEvent?(.started(sessionID: sessionID))
        resumeStart()
    }

    private func waitForSchedulingCapacity(sessionID: UUID) async {
        while
            currentSessionID == sessionID,
            started,
            scheduledDuration - playedDuration >= Self.maxScheduledAheadSeconds
        {
            await withCheckedContinuation { continuation in
                capacityWaiters.append(continuation)
            }
        }
    }

    private func schedule(_ item: PendingBuffer, sessionID: UUID) {
        guard let outputNode else { return }
        scheduledCount += 1
        scheduledDuration += item.duration
        let duration = item.duration
        let level = item.level
        outputNode.schedule(item.buffer) { [weak self] in
            self?.handlePlayed(duration: duration, level: level, sessionID: sessionID)
        }
    }

    /// Runs when a buffer has actually played back. The level goes out here, not at schedule
    /// time. Otherwise the meter would run up to `maxScheduledAheadSeconds` ahead of the audio,
    /// the prebuffer flush would burst ~8 levels at once, and those levels would re-arm the
    /// speech watchdog for audio nobody has heard yet.
    private func handlePlayed(duration: TimeInterval, level: Float, sessionID: UUID) {
        guard currentSessionID == sessionID, !explicitlyStopped else { return }
        playedCount += 1
        playedDuration += duration
        onEvent?(.level(sessionID: sessionID, level: level))
        if scheduledDuration - playedDuration < Self.maxScheduledAheadSeconds {
            resumeCapacityWaiters()
        }
        checkForCompletion(sessionID: sessionID)
    }

    private func checkForCompletion(sessionID: UUID) {
        guard currentSessionID == sessionID, !explicitlyStopped else { return }
        guard sourceFinished, playedCount >= scheduledCount else { return }

        let failed = sourceFailure != nil
        tearDownPlayback(cancelSource: false)
        currentSessionID = nil
        activeSource = nil
        if failed {
            onEvent?(.failed(sessionID: sessionID))
        } else {
            onEvent?(.finished(sessionID: sessionID))
        }
    }

    // MARK: - Conversion

    /// Converts one incoming frame to the output device format up front - never inside the realtime
    /// render loop. Handles per-frame sample rate and channel count, rebuilding the `AVAudioConverter`
    /// only when the source format actually changes.
    private func convert(_ frame: TTSAudioFrame) throws -> AVAudioPCMBuffer {
        guard frame.format.sampleRate > 0 else { throw StreamingAudioPlayerError.invalidSourceFormat }
        let channelCount = frame.format.channelCount
        guard channelCount > 0 else { throw StreamingAudioPlayerError.unsupportedChannelCount(channelCount) }
        guard frame.samples.count % channelCount == 0 else {
            throw StreamingAudioPlayerError.invalidSourceFormat
        }

        if outputNode == nil {
            let node = makeOutputNode()
            node.onConfigurationChange = { [weak self, weak node] in
                guard let self, let node, self.outputNode === node else { return }
                self.handleOutputConfigurationChange()
            }
            outputNode = node
        }
        guard let outputFormat = outputNode?.outputFormat else {
            throw StreamingAudioPlayerError.invalidSourceFormat
        }

        let sourceFormat: AVAudioFormat
        if converterInputFormat != frame.format || converter == nil {
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: frame.format.sampleRate,
                channels: AVAudioChannelCount(channelCount),
                interleaved: false
            ) else { throw StreamingAudioPlayerError.invalidSourceFormat }
            guard let newConverter = AVAudioConverter(from: format, to: outputFormat) else {
                throw StreamingAudioPlayerError.converterCreationFailed
            }
            sourceFormat = format
            converter = newConverter
            converterInputFormat = frame.format
        } else {
            guard let format = converter?.inputFormat else { throw StreamingAudioPlayerError.converterCreationFailed }
            sourceFormat = format
        }

        guard let converter else { throw StreamingAudioPlayerError.converterCreationFailed }

        let framesPerChannel = frame.samples.count / channelCount
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(framesPerChannel)
        ) else { throw StreamingAudioPlayerError.bufferAllocationFailed }
        sourceBuffer.frameLength = AVAudioFrameCount(framesPerChannel)

        if let channels = sourceBuffer.floatChannelData {
            AudioBufferUtilities.deinterleave(frame.samples, channelCount: channelCount, into: channels)
        }

        let ratio = outputFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(framesPerChannel) * ratio) + 8
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw StreamingAudioPlayerError.bufferAllocationFailed
        }

        let result = AudioBufferUtilities.convert(sourceBuffer, into: outputBuffer, using: converter)
        guard result.status != .error else {
            throw result.error ?? StreamingAudioPlayerError.conversionFailed
        }
        return outputBuffer
    }

    private func tearDownPlayback(cancelSource: Bool) {
        let source = activeSource
        pumpTask?.cancel()
        pumpTask = nil
        outputNode?.stop()
        outputNode = nil
        converter = nil
        converterInputFormat = nil
        pending.removeAll(keepingCapacity: false)
        pendingDuration = 0
        resumeCapacityWaiters()
        if cancelSource, let source {
            Task { await source.cancel() }
        }
    }

    private func resumeCapacityWaiters() {
        let waiters = capacityWaiters
        capacityWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }

    private func resumeStart() {
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        continuation.resume()
    }

    private func resumeStart(throwing error: any Error) {
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        continuation.resume(throwing: error)
    }
}

