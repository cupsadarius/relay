import Foundation

/// Long-form Kokoro source: sequential model inference feeds a bounded PCM pipe while playback
/// independently consumes earlier frames. No parallel Kokoro inference is ever started.
struct KokoroTTSAudioSource: TTSAudioSource {
    private static let maxAdaptiveSplitDepth = 8

    private let source: TTSAudioPipe.Source
    private let producer: Task<Void, Never>

    init(
        engine: any KokoroEngine,
        chunks: [String],
        voice: String,
        speed: Float,
        framer: PCMFramer = PCMFramer(),
        highWatermark: TimeInterval = 30,
        lowWatermark: TimeInterval = 15
    ) {
        let pipe = TTSAudioPipe.make(highWatermark: highWatermark, lowWatermark: lowWatermark)
        source = pipe.source
        producer = Task {
            do {
                for chunk in chunks {
                    try Task.checkCancellation()
                    try await Self.produce(
                        chunk: chunk,
                        depth: 0,
                        engine: engine,
                        voice: voice,
                        speed: speed,
                        framer: framer,
                        sink: pipe.sink
                    )
                }
                await pipe.sink.finish()
            } catch is CancellationError {
                await pipe.sink.cancel()
            } catch {
                await pipe.sink.fail(error)
            }
        }
    }

    func next() async throws -> TTSAudioFrame? {
        try await source.next()
    }

    func cancel() async {
        producer.cancel()
        await source.cancel()
    }

    private static func produce(
        chunk: String,
        depth: Int,
        engine: any KokoroEngine,
        voice: String,
        speed: Float,
        framer: PCMFramer,
        sink: TTSAudioPipe.Sink
    ) async throws {
        do {
            let pcm = try await engine.synthesize(phonemes: chunk, voice: voice, speed: speed)
            for frame in try framer.frames(samples: pcm.samples, sampleRate: pcm.sampleRate) {
                try Task.checkCancellation()
                try await sink.yield(frame)
            }
        } catch KokoroEngineError.acousticFramesTooLong {
            guard depth < maxAdaptiveSplitDepth, chunk.count > 1 else { throw KokoroEngineError.acousticFramesTooLong }
            let target = max(1, chunk.count / 2)
            let splitter = KokoroPhonemeChunker(
                preferredTarget: target,
                hardMaximum: max(target, chunk.count - 1)
            )
            let parts = splitter.chunks(from: chunk)
            guard parts.count > 1, parts.allSatisfy({ $0.count < chunk.count }) else {
                throw KokoroEngineError.acousticFramesTooLong
            }
            for part in parts {
                try await produce(
                    chunk: part,
                    depth: depth + 1,
                    engine: engine,
                    voice: voice,
                    speed: speed,
                    framer: framer,
                    sink: sink
                )
            }
        }
    }
}
