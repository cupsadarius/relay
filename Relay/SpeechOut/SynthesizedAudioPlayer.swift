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
/// `AVSpeechSynthesizer`, plus `.level` from an output tap - the first backend to do so, since
/// Apple's backend has no equivalent signal to tap.
@MainActor
final class SynthesizedAudioPlayer: SynthesizedAudioPlaying {
    /// Matches `MicrophoneLevelMeter`'s RMS-to-level scaling so the pill's speaking waveform
    /// behaves identically whichever backend is feeding it.
    private static nonisolated let levelGain: Float = 4
    private static let tapBufferSize: AVAudioFrameCount = 1_024

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

    func play(_ wav: Data, sessionID: UUID) async throws {
        let buffer = try Self.decode(wav)

        tearDownGraph()

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
        installLevelTap(on: player, sessionID: sessionID)

        self.engine = engine
        playerNode = player
        currentSessionID = sessionID
        didStopExplicitly = false

        onEvent?(.scheduled(sessionID: sessionID))

        do {
            try engine.start()
        } catch {
            tearDownGraph()
            currentSessionID = nil
            throw error
        }

        onEvent?(.started(sessionID: sessionID))

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
        if let playerNode {
            playerNode.removeTap(onBus: 0)
        }
        engine?.stop()
        engine = nil
        playerNode = nil
    }

    private func installLevelTap(on node: AVAudioPlayerNode, sessionID: UUID) {
        let format = node.outputFormat(forBus: 0)
        node.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: format) { @Sendable buffer, _ in
            let level = Self.rmsLevel(of: buffer)
            Task { @MainActor [weak self] in
                self?.onEvent?(.level(sessionID: sessionID, level: level))
            }
        }
    }

    private static nonisolated func rmsLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameLength > 0, channelCount > 0 else { return 0 }

        var sumOfSquares: Float = 0
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameLength {
                let sample = samples[frame]
                sumOfSquares += sample * sample
            }
        }
        let meanSquare = sumOfSquares / Float(frameLength * channelCount)
        let rms = sqrt(meanSquare)
        return min(max(rms * levelGain, 0), 1)
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
