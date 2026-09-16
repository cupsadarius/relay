import AVFoundation
import Foundation

/// Seam over `SynthesizedAudioPlayer` so `KokoroTTSBackend` can be tested without exercising a
/// real `AVAudioPlayer`.
@MainActor
protocol SynthesizedAudioPlaying: AnyObject {
    var onEvent: (@MainActor (TTSPlaybackEvent) -> Void)? { get set }
    /// Decodes and starts playing `wav`, then RETURNS as soon as playback has started - never
    /// waiting for it to finish. `.scheduled` and `.started` are emitted synchronously before
    /// this returns; the terminal event (`.finished`/`.cancelled`) is always reported later,
    /// asynchronously, through `onEvent`. Throws (emitting no event at all) only if playback
    /// could not be started in the first place, e.g. malformed `wav` data.
    func startPlayback(_ wav: Data, sessionID: UUID) async throws
    func stop()
    func pause()
    func resume()
}

/// Errors raised by `SynthesizedAudioPlayer` itself (as opposed to ones AVFoundation raises
/// while decoding or constructing the player, which are propagated as-is).
enum SynthesizedAudioPlayerError: Error, Equatable, Sendable {
    /// The WAV data decoded to a valid `AVAudioFile` but a playback buffer could not be
    /// allocated for it. Should not happen in practice; guards a force-unwrap.
    case bufferAllocationFailed
}

/// The three terminal outcomes `complete(_:sessionID:)` can fold a session into. Exists purely to
/// give `complete(_:sessionID:)` a single typed entry point for every terminal path.
private enum TerminalOutcome: Equatable {
    case finished
    case cancelled
    case failed
}

/// Seam over the subset of `AVAudioPlayer`'s surface `SynthesizedAudioPlayer` needs, so `play()`'s
/// `Bool` result and the finish delegate's `successfully` flag can be exercised in tests without a
/// real audio output device. `RealAudioPlayer` below is the only production implementation.
@MainActor
protocol AVAudioPlayerLike: AnyObject {
    /// Invoked once playback finishes, is interrupted, or fails to decode/play further - mirrors
    /// `AVAudioPlayerDelegate.audioPlayerDidFinishPlaying(_:successfully:)`'s `successfully` flag.
    /// Always invoked on the main actor.
    var onFinish: (@MainActor (_ successfully: Bool) -> Void)? { get set }
    /// Starts playback; returns `false` if it could not be started (mirrors
    /// `AVAudioPlayer.play()`).
    @discardableResult
    func play() -> Bool
    func stop()
    func pause()
}

/// Wraps a real `AVAudioPlayer`, bridging its `AVAudioPlayerDelegate` finish callback (which
/// AVFoundation may invoke off the main actor) onto `onFinish`, on the main actor - the only
/// production `AVAudioPlayerLike`. `SynthesizedAudioPlayer` itself never touches `AVAudioPlayer`
/// or `AVAudioPlayerDelegate` directly.
@MainActor
private final class RealAudioPlayer: NSObject, AVAudioPlayerLike {
    var onFinish: (@MainActor (Bool) -> Void)?

    private let player: AVAudioPlayer
    /// Bridges `AVAudioPlayerDelegate`'s completion callback back onto the main actor, without
    /// making `RealAudioPlayer` itself nonisolated. Held for the player's lifetime since
    /// `AVAudioPlayer.delegate` is weak.
    private var delegateShim: PlayerDelegateShim?

    init(data: Data) throws {
        player = try AVAudioPlayer(data: data)
        super.init()
        let shim = PlayerDelegateShim { [weak self] successfully in
            Task { @MainActor [weak self] in
                self?.onFinish?(successfully)
            }
        }
        player.delegate = shim
        delegateShim = shim
        player.prepareToPlay()
    }

    func play() -> Bool { player.play() }
    func stop() { player.stop() }
    func pause() { player.pause() }
}

/// Plays a complete WAV `Data` value (as returned by Kokoro's `synthesize`) through
/// `AVAudioPlayer` and emits the same `TTSPlaybackEvent` lifecycle `AppleTTSBackend` emits via
/// `AVSpeechSynthesizer`, plus `.level` from a precomputed envelope walked by a `MainActor` timer
/// - the first backend to emit `.level` at all, since Apple's backend has no equivalent signal.
///
/// This used to play back through a hand-built `AVAudioEngine` graph (`AVAudioPlayerNode` ->
/// `mainMixerNode`). The engine resamples Kokoro's 24kHz buffer to the hardware's output rate
/// inside its realtime render loop, and that resampling periodically underran, dropping or
/// garbling words. `AVAudioPlayer(data:)` decodes and resamples the whole file up front via
/// AVFoundation's file-based path, which does not have that failure mode, so playback now goes
/// through it instead. (An earlier version drove `.level` from a realtime `AVAudioPlayerNode`
/// tap; allocating a `Task` on every tap callback - on the realtime audio render thread - caused
/// its own periodic playback dropouts, so `.level` is driven entirely off that thread via a
/// precomputed envelope regardless of which player does the actual playback.)
@MainActor
final class SynthesizedAudioPlayer: SynthesizedAudioPlaying {
    /// Matches `MicrophoneLevelMeter`'s RMS-to-level scaling so the pill's speaking waveform
    /// behaves identically whichever backend is feeding it.
    private static nonisolated let levelGain: Float = 4
    /// Window size used to precompute the `.level` envelope and to pace the timer that walks it.
    /// ~40ms matches the cadence the old realtime tap emitted at (1024 samples / 24kHz).
    private static let levelWindowSeconds: TimeInterval = 0.04

    var onEvent: (@MainActor (TTSPlaybackEvent) -> Void)?

    /// Builds the player for a `startPlayback` call. Defaults to wrapping a real `AVAudioPlayer`
    /// via `RealAudioPlayer`; overridden in tests with a fake `AVAudioPlayerLike` so `play()`'s
    /// `Bool` result and the finish delegate's `successfully` flag can be exercised deterministically,
    /// without a real audio output device.
    private let makePlayer: @MainActor (Data) throws -> AVAudioPlayerLike

    private var audioPlayer: AVAudioPlayerLike?
    private var currentSessionID: UUID?
    /// Set by `stop()` before tearing playback down, so a finish callback that fires both on
    /// natural completion and, harmlessly, after an explicit stop (or any other stale late
    /// callback) knows not to also emit a terminal event for a session `stop()` already emitted
    /// `.cancelled` for. Consulted by `complete(_:sessionID:)` for every non-`.cancelled` outcome.
    private var didStopExplicitly = false
    /// Drives `.level` events for the in-flight session. Walks `levelEnvelope(from:windowSeconds:)`
    /// on a `MainActor` timer instead of a realtime audio tap - allocating (the `Task { @MainActor
    /// ... }` the old tap made per callback) on the audio render thread caused periodic dropouts
    /// ("pulsing", noise breaks between words).
    private var levelTask: Task<Void, Never>?

    init(makePlayer: @escaping @MainActor (Data) throws -> AVAudioPlayerLike = { try RealAudioPlayer(data: $0) }) {
        self.makePlayer = makePlayer
    }

    func startPlayback(_ wav: Data, sessionID: UUID) async throws {
        // Still decode to PCM - not for playback, only so `levelEnvelope` has samples to walk.
        // A decode failure (or a failure constructing the player itself, below) throws here,
        // before any state is set and before `.scheduled` is emitted - this session was never
        // accepted, so no terminal event applies, mirroring `StreamingAudioPlayer`'s pre-start
        // throw contract for a source that fails before playback ever starts.
        let buffer = try Self.decode(wav)

        tearDownPlayback()

        let envelope = Self.levelEnvelope(from: buffer, windowSeconds: Self.levelWindowSeconds)

        let player = try makePlayer(wav)
        player.onFinish = { [weak self] successfully in
            self?.handleCompletion(sessionID: sessionID, successfully: successfully)
        }

        audioPlayer = player
        currentSessionID = sessionID
        didStopExplicitly = false

        onEvent?(.scheduled(sessionID: sessionID))

        // `AVAudioPlayer.play()` itself starts playback and returns immediately - there is no
        // further async step to wait on. If it reports it could not start, the session is
        // complete (as a failure) right here - `.started` must never be emitted for it. Otherwise
        // `.started` is emitted right here and this function returns; the terminal event
        // (`.finished`/`.cancelled`/`.failed`) always arrives later, either through
        // `handleCompletion` (the finish callback) or `stop()`.
        guard player.play() else {
            complete(.failed, sessionID: sessionID)
            return
        }
        onEvent?(.started(sessionID: sessionID))
        startLevelTimer(envelope: envelope, sessionID: sessionID)
    }

    func stop() {
        guard let sessionID = currentSessionID else { return }
        didStopExplicitly = true
        complete(.cancelled, sessionID: sessionID)
    }

    func pause() {
        audioPlayer?.pause()
    }

    func resume() {
        _ = audioPlayer?.play()
    }

    private func handleCompletion(sessionID: UUID, successfully: Bool) {
        complete(successfully ? .finished : .failed, sessionID: sessionID)
    }

    /// Single funnel for every terminal path (`stop()`'s cancellation, the finish callback's
    /// success/failure, and a failed `play()`): applies the stale-callback guard, tears down
    /// playback, and emits the terminal event exactly once. `currentSessionID` is cleared as part
    /// of that teardown, so a second call for the same session - e.g. a duplicate or late finish
    /// callback racing a `stop()` - fails the first guard and is a no-op.
    private func complete(_ outcome: TerminalOutcome, sessionID: UUID) {
        guard currentSessionID == sessionID else { return }
        guard outcome == .cancelled || !didStopExplicitly else { return }
        tearDownPlayback()
        currentSessionID = nil
        switch outcome {
        case .finished: onEvent?(.finished(sessionID: sessionID))
        case .cancelled: onEvent?(.cancelled(sessionID: sessionID))
        case .failed: onEvent?(.failed(sessionID: sessionID))
        }
    }

    private func tearDownPlayback() {
        stopLevelTimer()
        audioPlayer?.onFinish = nil
        audioPlayer?.stop()
        audioPlayer = nil
    }

    /// Starts a `MainActor` loop that walks `envelope` at `levelWindowSeconds` cadence, emitting
    /// `.level` events roughly in sync with playback. No realtime audio thread involved, so
    /// nothing here can glitch AVAudioPlayer's internal render path.
    private func startLevelTimer(envelope: [Float], sessionID: UUID) {
        stopLevelTimer()
        guard !envelope.isEmpty else { return }
        let intervalNanoseconds = UInt64(Self.levelWindowSeconds * 1_000_000_000)
        levelTask = Task { @MainActor [weak self] in
            for level in envelope {
                guard let self, !Task.isCancelled, self.currentSessionID == sessionID else { return }
                self.onEvent?(.level(sessionID: sessionID, level: level))
                try? await Task.sleep(nanoseconds: intervalNanoseconds)
            }
        }
    }

    private func stopLevelTimer() {
        levelTask?.cancel()
        levelTask = nil
    }

    /// Splits `buffer`'s samples into fixed `windowSeconds` windows and computes an RMS-based
    /// level (matching `MicrophoneLevelMeter`'s scaling) for each, so `.level` events can be
    /// driven from data precomputed on the main actor instead of a realtime audio tap. Internal
    /// (not private) so it can be unit tested directly, without a working audio output device.
    static func levelEnvelope(from buffer: AVAudioPCMBuffer, windowSeconds: TimeInterval) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameLength > 0, channelCount > 0 else { return [] }

        let windowFrames = max(1, Int(buffer.format.sampleRate * windowSeconds))
        var envelope: [Float] = []
        envelope.reserveCapacity((frameLength + windowFrames - 1) / windowFrames)

        var start = 0
        while start < frameLength {
            let end = min(start + windowFrames, frameLength)
            var sumOfSquares: Float = 0
            for channel in 0..<channelCount {
                let samples = channelData[channel]
                for frame in start..<end {
                    let sample = samples[frame]
                    sumOfSquares += sample * sample
                }
            }
            let meanSquare = sumOfSquares / Float((end - start) * channelCount)
            let rms = sqrt(meanSquare)
            envelope.append(min(max(rms * levelGain, 0), 1))
            start = end
        }
        return envelope
    }

    /// Writes `wav` to a temporary file (deleted before returning - never a user path, never
    /// logged) and decodes it at its own processing format via `AVAudioFile`/`AVAudioPCMBuffer`,
    /// purely so `levelEnvelope(from:windowSeconds:)` has PCM samples to walk. Playback itself
    /// goes through `AVAudioPlayer(data:)`, not this buffer. Internal (not private) so decode
    /// failures can be exercised directly in tests without requiring a working audio output
    /// device.
    static func decode(_ wav: Data) throws -> AVAudioPCMBuffer {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try wav.write(to: temporaryURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let file = try AVAudioFile(forReading: temporaryURL)
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            )
        else {
            throw SynthesizedAudioPlayerError.bufferAllocationFailed
        }
        try file.read(into: buffer)
        return buffer
    }
}

/// Bridges `AVAudioPlayerDelegate`'s completion callback onto the main actor. `AVAudioPlayer`'s
/// delegate is a plain `NSObjectProtocol` callback that AVFoundation does not guarantee arrives
/// on the main actor, so this is its own `nonisolated` object rather than a method directly on
/// `RealAudioPlayer` (which is `@MainActor`-isolated and could not conform to the nonisolated
/// delegate protocol otherwise). It carries only a `Sendable` closure - passed the delegate
/// callback's `successfully` flag unchanged - that hops back to `RealAudioPlayer` via
/// `Task { @MainActor ... }`, so no audio work happens here.
private final class PlayerDelegateShim: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private let onFinish: @Sendable (Bool) -> Void

    init(onFinish: @escaping @Sendable (Bool) -> Void) {
        self.onFinish = onFinish
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish(flag)
    }
}
