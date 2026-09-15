import AVFoundation
import Foundation

/// Seam over `StreamingAudioPlayer` so `PocketTTSBackend` can be tested without exercising a real
/// `AVAudioEngine`. Mirrors `SynthesizedAudioPlaying`'s shape, but `play` takes a live frame
/// stream plus the source sample rate instead of a complete WAV `Data` value, since PocketTTS
/// streaming yields raw Float32 frames rather than a finished file.
@MainActor
protocol StreamingAudioPlaying: AnyObject {
    var onEvent: (@MainActor (TTSPlaybackEvent) -> Void)? { get set }
    func play(_ frames: AsyncThrowingStream<[Float], Error>, sampleRate: Double, sessionID: UUID) async throws
    func stop()
    func pause()
    func resume()
}

/// Carries the mutable "already provided input" flag and the source buffer across the boundary
/// into `AVAudioConverter`'s `@Sendable`-imported input block, which `convert(to:error:
/// withInputFrom:)` in fact only ever calls synchronously on the calling thread. `@unchecked`
/// because that synchronous contract is what actually makes it safe, not anything the type system
/// can verify.
private final class ConversionInputState: @unchecked Sendable {
    var providedInput = false
    let sourceBuffer: AVAudioPCMBuffer

    init(sourceBuffer: AVAudioPCMBuffer) {
        self.sourceBuffer = sourceBuffer
    }
}

/// Errors raised by `StreamingAudioPlayer` itself (as opposed to ones AVFoundation raises while
/// building the engine graph or converting a buffer, which are propagated as-is).
enum StreamingAudioPlayerError: Error, Equatable, Sendable {
    /// The source sample rate could not be represented as a valid `AVAudioFormat`.
    case invalidSourceFormat
    /// `AVAudioConverter` could not be constructed for the source -> output format pair.
    case converterCreationFailed
    /// A `AVAudioPCMBuffer` could not be allocated for an incoming or converted frame. Should not
    /// happen in practice; guards a force-unwrap.
    case bufferAllocationFailed
    /// `AVAudioConverter.convert(to:error:withInputFrom:)` reported an error without producing a
    /// more specific one of its own.
    case conversionFailed
}

/// Plays a live stream of raw Float32 audio frames (as `FluidAudioPocketTTSEngine.synthesizeStream`
/// yields) through an `AVAudioEngine` / `AVAudioPlayerNode` graph, emitting the same
/// `TTSPlaybackEvent` lifecycle `SynthesizedAudioPlayer` emits for the whole-WAV Kokoro/Apple
/// path, so `PocketTTSBackend` can start playback within a fraction of a second of the first
/// frame instead of waiting for synthesis of the entire utterance to finish.
///
/// This is a NEW type, not a replacement for `SynthesizedAudioPlayer` (which stays exactly as-is
/// for Kokoro and Apple). It exists because those two hard-won lessons from
/// `SynthesizedAudioPlayer`'s history do not simply carry over to a *streaming* source:
///
/// 1. **No realtime tap.** An earlier `SynthesizedAudioPlayer` drove `.level` off a realtime
///    `AVAudioPlayerNode` tap that allocated a `Task` per callback on the audio render thread,
///    causing periodic pulsing/dropouts. This player never installs a tap; `.level` is computed
///    up front per frame (`level(forFrame:)`) and walked by a `MainActor` timer instead, exactly
///    like `SynthesizedAudioPlayer.startLevelTimer`.
/// 2. **No render-loop resampling.** Playing 24kHz buffers through a player node connected to
///    `mainMixerNode` at 24kHz, letting the engine resample to the hardware rate inside its
///    realtime render loop, garbled playback. Here the player node is connected to the mixer at
///    the mixer's own output format, and every incoming frame is converted from the source rate
///    to that output format up front via `AVAudioConverter`, on the `MainActor`, before it is
///    ever scheduled - the render loop itself does no resampling.
@MainActor
final class StreamingAudioPlayer: StreamingAudioPlaying {
    /// Matches `SynthesizedAudioPlayer.levelGain` so the pill's speaking waveform behaves
    /// identically whichever backend is feeding it.
    private static nonisolated let levelGain: Float = 4
    /// How much audio to buffer before starting playback, trading a little latency for headroom
    /// against synthesis briefly falling behind real time.
    private static let prebufferSeconds: TimeInterval = 0.6
    /// Samples per frame in FluidAudio's PocketTTS streaming contract (80ms at 24kHz). Used only
    /// to derive `frameDurationSeconds` from the caller's `sampleRate`; if a future source frame
    /// happens to carry a different sample count, `.level` timing degrades gracefully (it just
    /// drifts) rather than crashing.
    private static let frameSampleCount = 1_920

    var onEvent: (@MainActor (TTSPlaybackEvent) -> Void)?

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?

    private var currentSessionID: UUID?
    /// Set by `stop()` before tearing playback down, so a buffer-completion callback that fires
    /// after an explicit stop (harmless, racy) knows not to also emit `.finished`.
    private var didStopExplicitly = false
    /// Resumed once playback reaches a terminal state (finished or stopped), so `play` does not
    /// return until then - matching `SynthesizedAudioPlayer`, which keeps the router's
    /// `activeBackend` handoff and `.finished` ordering correct.
    private var completionContinuation: CheckedContinuation<Void, Never>?

    /// Buffers accumulated before the prebuffer threshold is reached and playback actually starts.
    private var pendingBuffers: [AVAudioPCMBuffer] = []
    private var bufferedSeconds: TimeInterval = 0
    private var started = false
    /// True once the frame stream has yielded its last element (successfully). Playback is only
    /// ever considered `.finished` once this is true AND every scheduled buffer has finished
    /// playing back.
    private var sourceFinished = false
    private var scheduledCount = 0
    private var playedCount = 0

    /// One entry per frame, in arrival order, computed by `level(forFrame:)`. Walked by
    /// `levelTask` against elapsed playback time to emit `.level` events.
    private var levels: [Float] = []
    private var frameDurationSeconds: TimeInterval = Double(frameSampleCount) / 24_000
    private var levelTask: Task<Void, Never>?
    private var levelClockStart: Date?
    private var levelPausedElapsed: TimeInterval = 0
    private var levelPausedAt: Date?

    func play(_ frames: AsyncThrowingStream<[Float], Error>, sampleRate: Double, sessionID: UUID) async throws {
        tearDownPlayback()
        try setUpEngine(sampleRate: sampleRate)

        currentSessionID = sessionID
        didStopExplicitly = false
        sourceFinished = false
        scheduledCount = 0
        playedCount = 0
        levels = []
        pendingBuffers = []
        bufferedSeconds = 0
        started = false
        frameDurationSeconds = Double(Self.frameSampleCount) / sampleRate

        onEvent?(.scheduled(sessionID: sessionID))

        do {
            for try await samples in frames {
                guard currentSessionID == sessionID else { return }
                guard !samples.isEmpty else { continue }

                let convertedBuffer = try convert(samples)
                levels.append(Self.level(forFrame: samples))

                if started {
                    schedule(convertedBuffer, sessionID: sessionID)
                } else {
                    pendingBuffers.append(convertedBuffer)
                    bufferedSeconds += Double(convertedBuffer.frameLength) / (outputFormat?.sampleRate ?? sampleRate)
                    if bufferedSeconds >= Self.prebufferSeconds {
                        try startPlayback(sessionID: sessionID)
                    }
                }
            }
        } catch is CancellationError {
            tearDownPlayback()
            currentSessionID = nil
            throw CancellationError()
        } catch {
            tearDownPlayback()
            currentSessionID = nil
            throw error
        }

        guard currentSessionID == sessionID else { return }

        sourceFinished = true
        if !started {
            do {
                try startPlayback(sessionID: sessionID)
            } catch {
                tearDownPlayback()
                currentSessionID = nil
                throw error
            }
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            completionContinuation = continuation
            checkForCompletion(sessionID: sessionID)
        }
    }

    func stop() {
        guard let sessionID = currentSessionID else { return }
        didStopExplicitly = true
        tearDownPlayback()
        currentSessionID = nil
        onEvent?(.cancelled(sessionID: sessionID))
        resumeCompletionIfNeeded()
    }

    func pause() {
        playerNode?.pause()
        pauseLevelClock()
    }

    func resume() {
        playerNode?.play()
        resumeLevelClock()
    }

    // MARK: - Engine setup

    private func setUpEngine(sampleRate: Double) throws {
        guard
            let sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            )
        else {
            throw StreamingAudioPlayerError.invalidSourceFormat
        }

        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        let outputFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.connect(playerNode, to: engine.mainMixerNode, format: outputFormat)

        guard let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else {
            throw StreamingAudioPlayerError.converterCreationFailed
        }

        self.engine = engine
        self.playerNode = playerNode
        self.sourceFormat = sourceFormat
        self.outputFormat = outputFormat
        self.converter = converter
    }

    /// Converts one incoming frame to the engine's output format up front - never inside the
    /// realtime render loop. See the type-level doc comment's second lesson from
    /// `SynthesizedAudioPlayer`'s history.
    private func convert(_ samples: [Float]) throws -> AVAudioPCMBuffer {
        guard let sourceFormat, let outputFormat, let converter else {
            throw StreamingAudioPlayerError.converterCreationFailed
        }

        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw StreamingAudioPlayerError.bufferAllocationFailed
        }
        sourceBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            sourceBuffer.floatChannelData?[0].update(from: baseAddress, count: samples.count)
        }

        let ratio = outputFormat.sampleRate / sourceFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(samples.count) * ratio) + 8
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else {
            throw StreamingAudioPlayerError.bufferAllocationFailed
        }

        // `AVAudioConverterInputBlock` is imported as `@Sendable`, even though `convert(to:error:
        // withInputFrom:)` calls it synchronously on the current thread. Boxing the mutable
        // "already provided input" flag and the non-Sendable `AVAudioPCMBuffer` in a reference
        // type sidesteps the resulting (spurious, given the synchronous contract) Sendable
        // diagnostics without reaching for `nonisolated(unsafe)`.
        let inputState = ConversionInputState(sourceBuffer: sourceBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if inputState.providedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputState.providedInput = true
            inputStatus.pointee = .haveData
            return inputState.sourceBuffer
        }

        guard status != .error else {
            throw conversionError ?? StreamingAudioPlayerError.conversionFailed
        }

        return outputBuffer
    }

    /// Flushes any buffers accumulated during the prebuffer window, starts the engine and player
    /// node, and emits `.started` exactly once.
    private func startPlayback(sessionID: UUID) throws {
        guard let engine, let playerNode else { return }

        for buffer in pendingBuffers {
            schedule(buffer, sessionID: sessionID)
        }
        pendingBuffers = []

        try engine.start()
        playerNode.play()
        started = true
        onEvent?(.started(sessionID: sessionID))
        startLevelTimer(sessionID: sessionID)
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, sessionID: UUID) {
        guard let playerNode else { return }
        scheduledCount += 1
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleBufferPlayed(sessionID: sessionID)
            }
        }
    }

    private func handleBufferPlayed(sessionID: UUID) {
        guard currentSessionID == sessionID, !didStopExplicitly else { return }
        playedCount += 1
        checkForCompletion(sessionID: sessionID)
    }

    private func checkForCompletion(sessionID: UUID) {
        guard currentSessionID == sessionID, !didStopExplicitly else { return }
        guard sourceFinished, playedCount >= scheduledCount else { return }
        tearDownPlayback()
        currentSessionID = nil
        onEvent?(.finished(sessionID: sessionID))
        resumeCompletionIfNeeded()
    }

    private func resumeCompletionIfNeeded() {
        completionContinuation?.resume()
        completionContinuation = nil
    }

    private func tearDownPlayback() {
        stopLevelTimer()
        playerNode?.stop()
        engine?.stop()
        engine = nil
        playerNode = nil
        converter = nil
        sourceFormat = nil
        outputFormat = nil
        pendingBuffers = []
    }

    // MARK: - Levels

    /// Computes a single frame's `.level` value: RMS scaled by `levelGain`, clamped to `0...1` -
    /// the same scaling `SynthesizedAudioPlayer.levelEnvelope` uses, so the pill's waveform reads
    /// identically regardless of which player is driving it. Pure and `nonisolated` so it can be
    /// unit tested without a working audio output device.
    nonisolated static func level(forFrame samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumOfSquares: Float = 0
        for sample in samples {
            sumOfSquares += sample * sample
        }
        let meanSquare = sumOfSquares / Float(samples.count)
        let rms = sqrt(meanSquare)
        return min(max(rms * levelGain, 0), 1)
    }

    /// Starts a `MainActor` loop that maps elapsed playback time to a frame index into `levels`
    /// and emits `.level` for it, at `frameDurationSeconds` cadence (80ms for PocketTTS's 24kHz
    /// frames). No realtime audio thread involved - nothing here can glitch the render path.
    private func startLevelTimer(sessionID: UUID) {
        stopLevelTimer()
        levelClockStart = Date()
        levelPausedElapsed = 0
        levelPausedAt = nil

        let intervalNanoseconds = UInt64(max(frameDurationSeconds, 0.01) * 1_000_000_000)
        levelTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.currentSessionID == sessionID {
                let frameIndex = Int(self.elapsedLevelClock() / self.frameDurationSeconds)
                if frameIndex >= 0, frameIndex < self.levels.count {
                    self.onEvent?(.level(sessionID: sessionID, level: self.levels[frameIndex]))
                } else if self.sourceFinished, frameIndex >= self.levels.count {
                    return
                }
                try? await Task.sleep(nanoseconds: intervalNanoseconds)
            }
        }
    }

    private func stopLevelTimer() {
        levelTask?.cancel()
        levelTask = nil
        levelClockStart = nil
        levelPausedElapsed = 0
        levelPausedAt = nil
    }

    private func pauseLevelClock() {
        guard levelPausedAt == nil, levelClockStart != nil else { return }
        levelPausedAt = Date()
    }

    private func resumeLevelClock() {
        guard let pausedAt = levelPausedAt else { return }
        levelPausedElapsed += Date().timeIntervalSince(pausedAt)
        levelPausedAt = nil
    }

    private func elapsedLevelClock() -> TimeInterval {
        guard let levelClockStart else { return 0 }
        let pausedExtra = levelPausedAt.map { Date().timeIntervalSince($0) } ?? 0
        return Date().timeIntervalSince(levelClockStart) - levelPausedElapsed - pausedExtra
    }
}
