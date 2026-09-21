import AVFoundation
import Foundation

/// Shared player for provider-neutral `TTSAudioSource`s. It intentionally coexists with the
/// legacy `StreamingAudioPlayer` during the Apple compatibility window; production PocketTTS and
/// Kokoro route through this type, while Apple keeps native AVSpeechSynthesizer playback until
/// its generated-audio path is owner-Mac verified.
@MainActor
final class UnifiedStreamingAudioPlayer: TTSAudioPlaying {
    private struct PendingBuffer {
        let buffer: AVAudioPCMBuffer
        let duration: TimeInterval
        let level: Float
    }

    private final class ConversionInputState: @unchecked Sendable {
        var providedInput = false
        let sourceBuffer: AVAudioPCMBuffer

        init(sourceBuffer: AVAudioPCMBuffer) {
            self.sourceBuffer = sourceBuffer
        }
    }

    enum PlayerError: Error, Equatable, Sendable {
        case invalidSourceFormat
        case unsupportedChannelCount(Int)
        case converterCreationFailed
        case bufferAllocationFailed
        case conversionFailed
    }

    private static nonisolated let levelGain: Float = 4
    private static let prebufferSeconds: TimeInterval = 0.6
    private static let maxScheduledAheadSeconds: TimeInterval = 1.5

    var onEvent: (@MainActor (TTSPlaybackEvent) -> Void)?

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var outputFormat: AVAudioFormat?
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

    func startPlayback(_ source: any TTSAudioSource, sessionID: UUID) async throws {
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

        // TTSRouter owns the externally-visible scheduled event during the migration, but keeping
        // the player event preserves a self-contained player contract. The router filters it.
        onEvent?(.scheduled(sessionID: sessionID))

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

    func pause() {
        playerNode?.pause()
    }

    func resume() {
        playerNode?.play()
    }

    private func pump(_ source: any TTSAudioSource, sessionID: UUID) async {
        do {
            while let frame = try await source.next() {
                guard currentSessionID == sessionID, !explicitlyStopped else { return }
                guard !frame.samples.isEmpty else { continue }

                let converted = try convert(frame)
                let pendingBuffer = PendingBuffer(
                    buffer: converted,
                    duration: Double(converted.frameLength) / converted.format.sampleRate,
                    level: Self.level(for: frame.samples)
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
            handleSourceFailure(CancellationError(), sessionID: sessionID)
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

    private func handleSourceFailure(_ error: any Error, sessionID: UUID) {
        guard currentSessionID == sessionID, !explicitlyStopped else { return }

        if !started {
            tearDownPlayback(cancelSource: false)
            currentSessionID = nil
            activeSource = nil
            resumeStart(throwing: error)
            return
        }

        // Commitment already happened. Preserve valid scheduled PCM and report failure only after
        // it drains; the router must not restart the response through another voice.
        sourceFailure = error
        sourceFinished = true
        resumeCapacityWaiters()
        checkForCompletion(sessionID: sessionID)
    }

    private func beginPlayback(sessionID: UUID) throws {
        guard currentSessionID == sessionID else { return }

        // Empty-but-successful sources complete without building an audio graph.
        if pending.isEmpty {
            started = true
            onEvent?(.started(sessionID: sessionID))
            resumeStart()
            return
        }

        guard let engine, let playerNode else {
            throw PlayerError.invalidSourceFormat
        }
        for item in pending {
            schedule(item, sessionID: sessionID)
        }
        pending.removeAll(keepingCapacity: false)
        pendingDuration = 0

        try engine.start()
        playerNode.play()
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
        guard let playerNode else { return }
        scheduledCount += 1
        scheduledDuration += item.duration
        onEvent?(.level(sessionID: sessionID, level: item.level))
        let playedDuration = item.duration
        playerNode.scheduleBuffer(item.buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                self?.handlePlayed(duration: playedDuration, sessionID: sessionID)
            }
        }
    }

    private func handlePlayed(duration: TimeInterval, sessionID: UUID) {
        guard currentSessionID == sessionID, !explicitlyStopped else { return }
        playedCount += 1
        playedDuration += duration
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

    private func convert(_ frame: TTSAudioFrame) throws -> AVAudioPCMBuffer {
        guard frame.format.sampleRate > 0 else { throw PlayerError.invalidSourceFormat }
        guard frame.format.channelCount == 1 else {
            throw PlayerError.unsupportedChannelCount(frame.format.channelCount)
        }

        if engine == nil {
            let engine = AVAudioEngine()
            let playerNode = AVAudioPlayerNode()
            engine.attach(playerNode)
            let outputFormat = engine.mainMixerNode.outputFormat(forBus: 0)
            engine.connect(playerNode, to: engine.mainMixerNode, format: outputFormat)
            self.engine = engine
            self.playerNode = playerNode
            self.outputFormat = outputFormat
        }

        guard let outputFormat else { throw PlayerError.invalidSourceFormat }
        let sourceFormat: AVAudioFormat
        if converterInputFormat != frame.format || converter == nil {
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: frame.format.sampleRate,
                channels: AVAudioChannelCount(frame.format.channelCount),
                interleaved: false
            ) else { throw PlayerError.invalidSourceFormat }
            guard let converter = AVAudioConverter(from: format, to: outputFormat) else {
                throw PlayerError.converterCreationFailed
            }
            sourceFormat = format
            self.converter = converter
            converterInputFormat = frame.format
        } else {
            guard let format = converter?.inputFormat else { throw PlayerError.converterCreationFailed }
            sourceFormat = format
        }

        guard let converter else { throw PlayerError.converterCreationFailed }
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(frame.samples.count)
        ) else { throw PlayerError.bufferAllocationFailed }
        sourceBuffer.frameLength = AVAudioFrameCount(frame.samples.count)
        frame.samples.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            sourceBuffer.floatChannelData?[0].update(from: baseAddress, count: frame.samples.count)
        }

        let ratio = outputFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(frame.samples.count) * ratio) + 8
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw PlayerError.bufferAllocationFailed
        }

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
            throw conversionError ?? PlayerError.conversionFailed
        }
        return outputBuffer
    }

    private func tearDownPlayback(cancelSource: Bool) {
        let source = activeSource
        pumpTask?.cancel()
        pumpTask = nil
        playerNode?.stop()
        engine?.stop()
        engine = nil
        playerNode = nil
        outputFormat = nil
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

    nonisolated static func level(for samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return min(max(sqrt(sum / Float(samples.count)) * levelGain, 0), 1)
    }
}
