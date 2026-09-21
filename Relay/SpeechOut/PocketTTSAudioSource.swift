import Foundation

/// Pull adapter over PocketTTS's existing native Float32 stream.
actor PocketTTSAudioSource: TTSAudioSource {
    private nonisolated(unsafe) var iterator: AsyncThrowingStream<[Float], Error>.AsyncIterator?
    private let format: TTSAudioFormat
    private var cancelled = false

    init(stream: AsyncThrowingStream<[Float], Error>, sampleRate: Double) {
        iterator = stream.makeAsyncIterator()
        format = TTSAudioFormat(sampleRate: sampleRate, channelCount: 1)
    }

    func next() async throws -> TTSAudioFrame? {
        guard !cancelled, var iterator else { return nil }
        do {
            guard let samples = try await iterator.next() else {
                self.iterator = nil
                return nil
            }
            self.iterator = iterator
            return TTSAudioFrame(samples: samples, format: format)
        } catch {
            self.iterator = nil
            throw error
        }
    }

    func cancel() {
        cancelled = true
        iterator = nil
    }
}
