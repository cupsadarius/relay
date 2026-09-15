import AVFoundation
import Foundation

/// Seam over `SynthesizedAudioPlayer` so `KokoroTTSBackend` can be tested without exercising a
/// real `AVAudioEngine`.
@MainActor
protocol SynthesizedAudioPlaying: AnyObject {
    var onEvent: (@MainActor (TTSPlaybackEvent) -> Void)? { get set }
    func play(_ wav: Data, sessionID: UUID) async throws
    func stop()
    func pause()
    func resume()
}

/// Errors raised by `SynthesizedAudioPlayer` itself (as opposed to ones AVFoundation raises
/// while decoding or starting the engine, which are propagated as-is).
enum SynthesizedAudioPlayerError: Error, Equatable, Sendable {
    /// The WAV data decoded to a valid `AVAudioFile` but a playback buffer could not be
    /// allocated for it. Should not happen in practice; guards a force-unwrap.
    case bufferAllocationFailed
}

/// Plays a complete WAV `Data` value (as returned by Kokoro's `synthesize`) through
/// `AVAudioEngine` and emits the same `TTSPlaybackEvent` lifecycle `AppleTTSBackend` emits via
/// `AVSpeechSynthesizer`, plus `.level` from a precomputed envelope walked by a `MainActor` timer
/// - the first backend to emit `.level` at all, since Apple's backend has no equivalent signal.
/// (An earlier version drove `.level` from a realtime `AVAudioPlayerNode` tap; allocating a
/// `Task` on every tap callback - on the realtime audio render thread - caused periodic playback
/// dropouts, so `.level` is now driven entirely off that thread.)
@MainActor
final class SynthesizedAudioPlayer: SynthesizedAudioPlaying {
    /// Matches `MicrophoneLevelMeter`'s RMS-to-level scaling so the pill's speaking waveform
    /// behaves identically whichever backend is feeding it.
    private static nonisolated let levelGain: Float = 4
    /// Window size used to precompute the `.level` envelope and to pace the timer that walks it.
    /// ~40ms matches the cadence the old realtime tap emitted at (1024 samples / 24kHz).
    private static let levelWindowSeconds: TimeInterval = 0.04

    var onEvent: (@MainActor (TTSPlaybackEvent) -> Void)?

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var currentSessionID: UUID?
    /// Set by `stop()` before tearing the graph down, so the `scheduleBuffer` completion handler
    /// (which fires both on natural completion and on an explicit stop) knows not to also emit
    /// `.finished` for a session `stop()` already emitted `.cancelled` for.
    private var didStopExplicitly = false
    /// Resumed once playback reaches a terminal state (finished or stopped), so `play(_:sessionID:)`
    /// does not return until then - matching `AppleTTSBackend`, whose `speak` only returns once
    /// the utterance finishes, which keeps the router's `activeBackend` handoff and `.finished`
    /// ordering correct.
    private var completionContinuation: CheckedContinuation<Void, Never>?
    /// Drives `.level` events for the in-flight session. Walks `levelEnvelope(from:windowSeconds:)`
    /// on a `MainActor` timer instead of a realtime audio tap - allocating (the `Task { @MainActor
    /// ... }` the old tap made per callback) on the audio render thread caused periodic dropouts
    /// ("pulsing", noise breaks between words).
    private var levelTask: Task<Void, Never>?

    func play(_ wav: Data, sessionID: UUID) async throws {
        let buffer = try Self.decode(wav)

        tearDownGraph()

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: buffer.format)

        self.engine = engine
        playerNode = player
        currentSessionID = sessionID
        didStopExplicitly = false
        let envelope = Self.levelEnvelope(from: buffer, windowSeconds: Self.levelWindowSeconds)

        onEvent?(.scheduled(sessionID: sessionID))

        do {
            try engine.start()
        } catch {
            tearDownGraph()
            currentSessionID = nil
            throw error
        }

        onEvent?(.started(sessionID: sessionID))
        startLevelTimer(envelope: envelope, sessionID: sessionID)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            completionContinuation = continuation
            player.scheduleBuffer(buffer, at: nil, options: []) { @Sendable [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleCompletion(sessionID: sessionID)
                }
            }
            player.play()
        }
    }

    func stop() {
        guard let sessionID = currentSessionID else { return }
        didStopExplicitly = true
        playerNode?.stop()
        tearDownGraph()
        currentSessionID = nil
        onEvent?(.cancelled(sessionID: sessionID))
        resumeCompletionIfNeeded()
    }

    func pause() {
        playerNode?.pause()
    }

    func resume() {
        playerNode?.play()
    }

    private func handleCompletion(sessionID: UUID) {
        defer { resumeCompletionIfNeeded() }
        guard currentSessionID == sessionID, !didStopExplicitly else { return }
        tearDownGraph()
        currentSessionID = nil
        onEvent?(.finished(sessionID: sessionID))
    }

    private func resumeCompletionIfNeeded() {
        completionContinuation?.resume()
        completionContinuation = nil
    }

    private func tearDownGraph() {
        stopLevelTimer()
        engine?.stop()
        engine = nil
        playerNode = nil
    }

    /// Starts a `MainActor` loop that walks `envelope` at `levelWindowSeconds` cadence, emitting
    /// `.level` events roughly in sync with playback. No realtime audio thread involved, so
    /// nothing here can glitch the render callback.
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
    /// (not private) so it can be unit tested directly, without a working `AVAudioEngine`.
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
    /// logged) and decodes it at its own processing format via `AVAudioFile`/`AVAudioPCMBuffer`.
    /// Internal (not private) so decode failures can be exercised directly in tests without
    /// requiring a working `AVAudioEngine` output device.
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
