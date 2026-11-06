import Foundation
import os

/// Live interim text for the dictation pill. Every tick it re-runs the batch transcriber on the
/// audio so far, capped to the last `maxWindowSamples`. Display-only: the inserted transcript
/// comes from a separate final call.
actor StreamingTranscriber {
    static let defaultTickInterval: Duration = .milliseconds(450)

    private let logger = Logger(subsystem: "dev.relaymac.Relay", category: "streaming-transcriber")
    private let tickInterval: Duration
    /// Bounds the cost of re-transcribing a growing buffer every tick.
    private let maxWindowSamples: Int

    private let transcribe: @MainActor (AudioInput) async throws -> Transcript
    private let onInterimText: @Sendable (String) -> Void

    private var samples: [Float] = []
    private var isTranscribing = false
    private var tickTask: Task<Void, Never>?

    init(
        tickInterval: Duration = StreamingTranscriber.defaultTickInterval,
        maxWindowSamples: Int = 15 * 16_000,
        transcribe: @escaping @MainActor (AudioInput) async throws -> Transcript,
        onInterimText: @escaping @Sendable (String) -> Void
    ) {
        self.tickInterval = tickInterval
        self.maxWindowSamples = maxWindowSamples
        self.transcribe = transcribe
        self.onInterimText = onInterimText
    }

    /// Starts a fresh interim session and its tick loop.
    func start() {
        samples.removeAll(keepingCapacity: true)
        isTranscribing = false
        tickTask?.cancel()
        let interval = tickInterval
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.tick()
            }
        }
    }

    /// Accumulates 16 kHz mono samples; the tick loop transcribes them.
    func appendSamples(_ newSamples: [Float]) {
        samples.append(contentsOf: newSamples)
        if samples.count > maxWindowSamples {
            samples.removeFirst(samples.count - maxWindowSamples)
        }
    }

    /// Stops the tick loop and waits for an in-flight `transcribe` call, which cancellation
    /// cannot interrupt, so the shared model is free when this returns.
    func stop() async {
        tickTask?.cancel()
        await tickTask?.value
        tickTask = nil
        samples.removeAll(keepingCapacity: true)
        isTranscribing = false
    }

    /// Cancels the tick loop without waiting. An in-flight call keeps running, but `tick()`
    /// drops its result.
    func abandon() {
        tickTask?.cancel()
        tickTask = nil
        samples.removeAll(keepingCapacity: true)
        isTranscribing = false
    }

    /// Skips the tick while a previous transcription is still in flight.
    private func tick() async {
        guard !isTranscribing, !samples.isEmpty else { return }
        isTranscribing = true
        defer { isTranscribing = false }

        let snapshot = samples
        do {
            let result = try await transcribe(AudioInput(samples: snapshot, sampleRate: 16_000))
            guard !Task.isCancelled else { return }
            onInterimText(result.text)
        } catch is CancellationError {
        } catch {
            logger.debug("Streaming transcriber tick failed: \(error.localizedDescription, privacy: .private)")
        }
    }
}
