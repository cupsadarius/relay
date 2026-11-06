import AVFoundation
import Foundation
import os

/// Live microphone source. Every capture builds a fresh `AVAudioEngine` and drops it on every
/// teardown path, so no engine outlives its capture and keeps the input device open.
/// Threading rules:
/// - The tap callback only takes the gate briefly and delivers samples with no lock held.
/// - Every engine mutation (installTap, start, removeTap, stop) runs on `engineQueue`, which the
///   tap never runs on, so teardown there can wait for an in-flight callback without deadlocking.
/// - A failure seen on the tap thread (or on a route change) closes the gate and *queues* teardown
///   on `engineQueue`, because removing a tap from inside its own callback can deadlock. A later
///   `start()`/`stop()` goes through the same queue, so that teardown always runs before a newer
///   capture installs its tap.
final class AVAudioEngineSource: AudioCaptureSourcing, @unchecked Sendable {
    private let gate = CaptureCallbackGate()
    private let engineQueue = DispatchQueue(label: "dev.relaymac.Relay.microphone-engine")
    private let notificationCenter: NotificationCenter
    private let preferredMicrophone: @Sendable () -> SelectedMicrophone?
    private let releaseMonitor: MicrophoneReleaseMonitor?
    private let onFallback: @Sendable (String) -> Void

    private let stateLock = NSLock()
    /// The real input device rate captured in `start()`, before resampling to 16 kHz. Metadata
    /// for privacy-safe diagnostics only, and (paired with `installedInputChannelCount`) the
    /// baseline `AudioEngineRouteChangeDecision` compares a route-change notification against.
    private var inputSampleRate: Double = 0
    private var installedInputChannelCount: AVAudioChannelCount = 0
    private var terminalErrorHandler: (@Sendable (Error) async -> Void)?
    private var configurationObserver: AudioEngineConfigurationObserver?
    private let logger = Logger.relay("microphone")

    /// The current capture's engine; `nil` while idle. Only touched on `engineQueue`.
    private var engine: AVAudioEngine?

    /// `onFallback` receives the name of a chosen microphone that Relay could not use.
    init(
        notificationCenter: NotificationCenter = .default,
        preferredMicrophone: @escaping @Sendable () -> SelectedMicrophone? = { nil },
        releaseMonitor: MicrophoneReleaseMonitor? = nil,
        onFallback: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.notificationCenter = notificationCenter
        self.preferredMicrophone = preferredMicrophone
        self.releaseMonitor = releaseMonitor
        self.onFallback = onFallback
    }

    func currentInputSampleRate() -> Double {
        stateLock.withLock { inputSampleRate }
    }

    func start(
        onSamples: @escaping @Sendable ([Float]) -> Void,
        onTerminalError: @escaping @Sendable (Error) async -> Void
    ) async throws {
        let engine: AVAudioEngine = try engineQueue.sync {
            guard self.engine == nil else { throw MicrophoneCaptureError.alreadyRecording }
            releaseMonitor?.captureStarted()
            let engine = AVAudioEngine()
            self.engine = engine
            let input = engine.inputNode
            selectInputDevice(on: input)
            let inputFormat = input.inputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
                let outputFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: AudioInput.sttSampleRate,
                    channels: 1,
                    interleaved: false
                ),
                let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            else {
                tearDownEngine(path: .failure)
                throw MicrophoneCaptureError.unavailable("The current input format is unsupported.")
            }

            stateLock.withLock {
                inputSampleRate = inputFormat.sampleRate
                installedInputChannelCount = inputFormat.channelCount
                terminalErrorHandler = onTerminalError
            }
            gate.open()
            input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { [weak self] buffer, _ in
                self?.handleTap(buffer, converter: converter, outputFormat: outputFormat, onSamples: onSamples)
            }

            do {
                try engine.start()
            } catch {
                _ = gate.close()
                tearDownEngine(path: .failure)
                throw MicrophoneCaptureError.unavailable(error.localizedDescription)
            }
            return engine
        }

        let observer = AudioEngineConfigurationObserver(engine: engine, center: notificationCenter) {
            [weak self, weak engine] in
            guard let self, let engine else { return }
            // Bracket with the same gate the tap uses: if the gate is already closed (a `stop()`
            // in flight, or a previous failure already reported), this notification is stale for
            // the current -- or a since-superseded -- session and must not fail it.
            guard self.gate.enter() else { return }
            defer { self.gate.leave() }

            // Reads `engine` directly on whatever thread posted this notification, not on
            // `engineQueue`. Safe here because it is bracketed by the same gate the tap uses
            // (above): the gate is only open while a capture is actually running, and `stop()`
            // closes it and waits out any in-flight callback before tearing the engine down, so
            // this read cannot race a `tearDownEngine()` that has already started.
            let current = engine.inputNode.inputFormat(forBus: 0)
            let installed = self.stateLock.withLock { (self.inputSampleRate, self.installedInputChannelCount) }
            guard
                AudioEngineRouteChangeDecision.isDisruptive(
                    isEngineRunning: engine.isRunning,
                    installedSampleRate: installed.0,
                    installedChannelCount: installed.1,
                    currentSampleRate: current.sampleRate,
                    currentChannelCount: current.channelCount
                )
            else {
                // Ignore spurious posts where the engine keeps running with the same format:
                // AVFoundation stops the engine on a real route change, so this combination means
                // nothing downstream is actually broken. Failing here would end perfectly healthy
                // dictation sessions on every such spurious post.
                self.logger.debug("Ignoring a non-disruptive audio route change")
                return
            }
            self.fail(MicrophoneCaptureError.unavailable("The audio input device changed."))
        }
        stateLock.withLock { configurationObserver = observer }
    }

    /// Blocks its calling thread briefly, two ways: `gate.close()` waits out at most one
    /// in-flight tap callback (one 4096-frame conversion), and `engineQueue.sync` waits for
    /// `removeTap`/`engine.stop()`. Both are bounded and short. That is acceptable on the
    /// `MicrophoneCapture` actor's executor, and it is what upholds the `AudioCaptureSourcing.stop`
    /// contract that no samples arrive after it returns.
    func stop(path: MicrophoneStopPath) async throws {
        let error = gate.close()
        let observer: AudioEngineConfigurationObserver? = stateLock.withLock {
            defer {
                configurationObserver = nil
                terminalErrorHandler = nil
            }
            return configurationObserver
        }
        withExtendedLifetime(observer) {} // released here, outside the lock
        engineQueue.sync { tearDownEngine(path: path) }
        if let error { throw error }
    }

    /// `engineQueue` only. A no-op when the capture is already torn down.
    private func tearDownEngine(path: MicrophoneStopPath) {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        releaseMonitor?.captureReleased(path)
    }

    /// `engineQueue` only. Must run before the input format is read. Falls back to the system
    /// default input, never fails the capture.
    private func selectInputDevice(on input: AVAudioInputNode) {
        let resolution = MicrophoneSelection.resolve(preferredMicrophone(), connected: AudioInputDevices.connected())
        if let missing = resolution.missing {
            onFallback(missing.name)
        }
        guard let device = resolution.device else { return }
        var deviceID = device.id
        let status: OSStatus =
            if let unit = input.audioUnit {
                AudioUnitSetProperty(
                    unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                    &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
                )
            } else {
                kAudioUnitErr_Uninitialized
            }
        if status != noErr {
            logger.error("Could not select the chosen microphone (status \(status)); using the system default")
            onFallback(device.name)
        }
    }

    /// Tap thread.
    private func handleTap(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        outputFormat: AVAudioFormat,
        onSamples: @Sendable ([Float]) -> Void
    ) {
        guard gate.enter() else { return }
        defer { gate.leave() }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            fail(MicrophoneCaptureError.unavailable("Unable to allocate an audio conversion buffer."))
            return
        }

        let result = AudioBufferUtilities.convert(buffer, into: output, using: converter)
        switch AudioConversionDisposition.resolve(
            status: result.status,
            hasConversionError: result.error != nil,
            frameLength: output.frameLength
        ) {
        case .appendOutput:
            break
        case .awaitNextCallback:
            return
        case .fail:
            fail(result.error ?? MicrophoneCaptureError.unavailable("Audio conversion failed with status \(result.status.rawValue)."))
            return
        }
        guard let channel = output.floatChannelData?[0] else {
            fail(MicrophoneCaptureError.unavailable("Converted audio has no float samples."))
            return
        }
        onSamples(Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength))))
    }

    /// Tap thread or notification thread. Reports the first failure once and queues teardown.
    /// Also drops `configurationObserver`/`terminalErrorHandler` right away: `stop()` is the only
    /// other place that clears them, and a failed recording's `MicrophoneCapture.stop()` never
    /// calls into this source (it reads the recorded error and returns without touching it), so
    /// without this they would linger -- the observer still watching for further route changes,
    /// the handler closure still retained -- until whatever `start()` eventually replaces them.
    private func fail(_ error: Error) {
        guard gate.fail(error) else { return }
        let (handler, observer) = stateLock.withLock {
            defer {
                configurationObserver = nil
                terminalErrorHandler = nil
            }
            return (terminalErrorHandler, configurationObserver)
        }
        withExtendedLifetime(observer) {} // released here, outside the lock -- matches stop()
        engineQueue.async { [weak self] in self?.tearDownEngine(path: .failure) }
        if let handler {
            Task { await handler(error) }
        }
    }
}
