import Foundation

/// Pull adapter over PocketTTS's native Float32 stream. A producer task drains the engine stream
/// into a bounded pipe; playback pulls frames back out independently.
enum PocketTTSAudioSource {
    static func make(stream: AsyncThrowingStream<[Float], Error>, sampleRate: Double) -> PipedTTSAudioSource {
        let format = TTSAudioFormat(sampleRate: sampleRate, channelCount: 1)
        return PipedTTSAudioSource { sink in
            for try await samples in stream {
                try Task.checkCancellation()
                try await sink.yield(TTSAudioFrame(samples: samples, format: format))
            }
        }
    }
}
