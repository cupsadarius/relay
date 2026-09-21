import Foundation

/// Bounded producer/consumer PCM pipe with duration-based hysteresis. The producer suspends once
/// queued audio reaches the high watermark and is released only after the consumer drains below
/// the low watermark. Failure preserves already-produced PCM; cancellation discards it.
enum TTSAudioPipe {
    struct Sink: Sendable {
        fileprivate let state: State

        func yield(_ frame: TTSAudioFrame) async throws {
            try await state.yield(frame)
        }

        func finish() async {
            await state.finish()
        }

        func fail(_ error: any Error) async {
            await state.fail(error)
        }

        func cancel() async {
            await state.cancel()
        }
    }

    struct Source: TTSAudioSource {
        fileprivate let state: State

        func next() async throws -> TTSAudioFrame? {
            try await state.next()
        }

        func cancel() async {
            await state.cancel()
        }
    }

    static func make(
        highWatermark: TimeInterval = 30,
        lowWatermark: TimeInterval = 15
    ) -> (sink: Sink, source: Source) {
        precondition(highWatermark > 0)
        precondition(lowWatermark >= 0 && lowWatermark < highWatermark)
        let state = State(highWatermark: highWatermark, lowWatermark: lowWatermark)
        return (Sink(state: state), Source(state: state))
    }

    fileprivate actor State {
        private enum Terminal {
            case open
            case finished
            case failed(any Error)
            case cancelled
        }

        private let highWatermark: TimeInterval
        private let lowWatermark: TimeInterval
        private var queue: [TTSAudioFrame] = []
        private var bufferedDuration: TimeInterval = 0
        private var terminal: Terminal = .open
        private var consumerWaiters: [CheckedContinuation<Void, Never>] = []
        private var producerWaiters: [CheckedContinuation<Void, Never>] = []

        init(highWatermark: TimeInterval, lowWatermark: TimeInterval) {
            self.highWatermark = highWatermark
            self.lowWatermark = lowWatermark
        }

        func yield(_ frame: TTSAudioFrame) async throws {
            while case .open = terminal, bufferedDuration >= highWatermark {
                await withCheckedContinuation { continuation in
                    producerWaiters.append(continuation)
                }
            }

            switch terminal {
            case .open:
                queue.append(frame)
                bufferedDuration += frame.durationSeconds
                resumeConsumers()
            case .cancelled:
                throw CancellationError()
            case .finished, .failed:
                throw CancellationError()
            }
        }

        func next() async throws -> TTSAudioFrame? {
            while queue.isEmpty {
                switch terminal {
                case .open:
                    await withCheckedContinuation { continuation in
                        consumerWaiters.append(continuation)
                    }
                case .finished:
                    return nil
                case let .failed(error):
                    throw error
                case .cancelled:
                    throw CancellationError()
                }
            }

            let frame = queue.removeFirst()
            bufferedDuration = max(0, bufferedDuration - frame.durationSeconds)
            if bufferedDuration < lowWatermark {
                resumeProducers()
            }
            return frame
        }

        func finish() {
            guard case .open = terminal else { return }
            terminal = .finished
            resumeConsumers()
            resumeProducers()
        }

        func fail(_ error: any Error) {
            guard case .open = terminal else { return }
            terminal = .failed(error)
            resumeConsumers()
            resumeProducers()
        }

        func cancel() {
            guard case .cancelled = terminal else {
                terminal = .cancelled
                queue.removeAll(keepingCapacity: false)
                bufferedDuration = 0
                resumeConsumers()
                resumeProducers()
                return
            }
        }

        private func resumeConsumers() {
            let waiters = consumerWaiters
            consumerWaiters.removeAll(keepingCapacity: false)
            for waiter in waiters { waiter.resume() }
        }

        private func resumeProducers() {
            let waiters = producerWaiters
            producerWaiters.removeAll(keepingCapacity: false)
            for waiter in waiters { waiter.resume() }
        }
    }
}
