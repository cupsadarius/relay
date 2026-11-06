import AVFoundation
import CoreMedia
import Foundation
import os

/// Reads 16 kHz mono Float32 samples out of a capture buffer. The capture output is asked for
/// that format, so any other format means the request was not honoured.
enum CaptureSamples {
    static func floats(from buffer: CMSampleBuffer) throws -> [Float] {
        guard let description = buffer.formatDescription,
            let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
            format.mFormatID == kAudioFormatLinearPCM,
            format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            format.mBitsPerChannel == 32,
            format.mChannelsPerFrame == 1,
            format.mSampleRate == AudioInput.sttSampleRate
        else {
            throw MicrophoneCaptureError.unavailable("The microphone sent audio in an unsupported format.")
        }
        guard let block = buffer.dataBuffer else { return [] }
        let length = CMBlockBufferGetDataLength(block)
        var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
        let status = samples.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
        }
        guard status == noErr else {
            throw MicrophoneCaptureError.unavailable("Could not read the microphone audio (status \(status)).")
        }
        return samples
    }
}

/// Live microphone source on `AVCaptureSession`. A capture session records from the chosen input
/// device only, and leaves the output device alone. Every capture builds a fresh session and drops
/// it on every teardown path, so no session outlives its capture and keeps the device open.
/// Threading rules:
/// - The sample callback only takes the gate briefly and delivers samples with no lock held.
/// - Every session mutation runs on `sessionQueue`. The callback runs on `sampleQueue`, so a
///   teardown on `sessionQueue` can wait out an in-flight callback without a deadlock.
/// - A failure seen on the callback or notification thread closes the gate and queues teardown on
///   `sessionQueue`, so it always runs before a newer capture starts.
final class CaptureSessionSource: AudioCaptureSourcing, @unchecked Sendable {
    private let gate = CaptureCallbackGate()
    private let sessionQueue = DispatchQueue(label: "dev.relaymac.Relay.microphone-session")
    private let sampleQueue = DispatchQueue(label: "dev.relaymac.Relay.microphone-samples", qos: .userInitiated)
    private let notificationCenter: NotificationCenter
    private let preferredMicrophone: @Sendable () -> SelectedMicrophone?
    private let releaseMonitor: MicrophoneReleaseMonitor?
    private let onFallback: @Sendable (String) -> Void
    private let logger = Logger.relay("microphone")

    private let stateLock = NSLock()
    /// The device rate before the output converts it to 16 kHz. Diagnostics only.
    private var inputSampleRate: Double = 0
    private var terminalErrorHandler: (@Sendable (Error) async -> Void)?
    private var observers: [NSObjectProtocol] = []
    /// Set before `start`; guarded by `stateLock`.
    private var nextTracer: PipelineTracer?

    /// The current capture; `nil` while idle. Only touched on `sessionQueue`.
    private var capture: Capture?

    private struct Capture {
        let session: AVCaptureSession
        let output: AVCaptureAudioDataOutput
        let receiver: SampleReceiver
        let tracer: PipelineTracer?
        let firstAudio: FirstAudioWatch?
    }

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

    func setTracer(_ tracer: PipelineTracer?) {
        stateLock.withLock { nextTracer = tracer }
    }

    func start(
        onSamples: @escaping @Sendable ([Float]) -> Void,
        onTerminalError: @escaping @Sendable (Error) async -> Void
    ) async throws {
        let (session, device): (AVCaptureSession, AVCaptureDevice) = try sessionQueue.sync {
            guard capture == nil else { throw MicrophoneCaptureError.alreadyRecording }
            let tracer = stateLock.withLock { nextTracer }
            let (device, label) = try selectDevice(tracer: tracer)
            releaseMonitor?.captureStarted()
            tracer?.start(.micOpen, "Opening \(label)")

            let session = AVCaptureSession()
            let output = AVCaptureAudioDataOutput()
            output.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: AudioInput.sttSampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input), session.canAddOutput(output) else {
                    throw MicrophoneCaptureError.unavailable("\(device.localizedName) cannot record.")
                }
                session.addInput(input)
                session.addOutput(output)
            } catch {
                tracer?.fail(.micOpen, "Could not open \(device.localizedName)")
                releaseMonitor?.captureReleased(.failure, tracer: tracer)
                throw MicrophoneCaptureError.unavailable(error.localizedDescription)
            }

            let rate = Self.sampleRate(of: device)
            stateLock.withLock {
                inputSampleRate = rate
                terminalErrorHandler = onTerminalError
            }
            let firstAudio = tracer.map {
                FirstAudioWatch(tracer: $0, label: rate > 0 ? "\(label) · \(Int(rate / 1_000)) kHz" : label)
            }
            let receiver = SampleReceiver(gate: gate, firstAudio: firstAudio, onSamples: onSamples) { [weak self] error in
                self?.fail(error)
            }
            output.setSampleBufferDelegate(receiver, queue: sampleQueue)
            capture = Capture(session: session, output: output, receiver: receiver, tracer: tracer, firstAudio: firstAudio)
            gate.open()

            session.startRunning()
            guard session.isRunning else {
                _ = gate.close()
                firstAudio?.abandon()
                tracer?.fail(.micOpen, "Could not start \(device.localizedName)")
                tearDown(path: .failure)
                throw MicrophoneCaptureError.unavailable("\(device.localizedName) did not start.")
            }
            return (session, device)
        }

        let runtimeError = notificationCenter.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
        ) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.fail(MicrophoneCaptureError.unavailable(error?.localizedDescription ?? "The microphone stopped."))
        }
        let disconnected = notificationCenter.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil
        ) { [weak self] _ in
            self?.fail(MicrophoneCaptureError.unavailable("\(device.localizedName) was disconnected."))
        }
        stateLock.withLock { observers = [runtimeError, disconnected] }
    }

    /// Blocks its calling thread briefly: `gate.close()` waits out at most one in-flight sample
    /// callback, and `sessionQueue.sync` waits for `stopRunning()`. That upholds the
    /// `AudioCaptureSourcing.stop` contract that no samples arrive after it returns.
    func stop(path: MicrophoneStopPath) async throws {
        let error = gate.close()
        removeObservers()
        sessionQueue.sync { tearDown(path: path) }
        if let error { throw error }
    }

    /// `sessionQueue` only. A no-op when the capture is already torn down.
    private func tearDown(path: MicrophoneStopPath) {
        guard let capture else { return }
        capture.output.setSampleBufferDelegate(nil, queue: nil)
        capture.session.stopRunning()
        self.capture = nil
        capture.firstAudio?.captureEnded()
        releaseMonitor?.captureReleased(path, tracer: capture.tracer)
    }

    /// `sessionQueue` only. Falls back to the system default input when the chosen one is gone.
    private func selectDevice(tracer: PipelineTracer?) throws -> (AVCaptureDevice, String) {
        let resolution = MicrophoneSelection.resolve(preferredMicrophone(), connected: AudioInputDevices.connected())
        if let missing = resolution.missing {
            onFallback(missing.name)
        }
        if let chosen = resolution.device {
            if let device = AVCaptureDevice(uniqueID: chosen.uid) {
                return (device, chosen.name)
            }
            logger.error("Could not find the chosen microphone for capture; using the system default")
            onFallback(chosen.name)
        }
        guard let device = AVCaptureDevice.default(for: .audio) else {
            tracer?.fail(.micOpen, "No microphone found")
            throw MicrophoneCaptureError.unavailable("No microphone is connected.")
        }
        return (device, "system default (\(device.localizedName))")
    }

    private static func sampleRate(of device: AVCaptureDevice) -> Double {
        CMAudioFormatDescriptionGetStreamBasicDescription(device.activeFormat.formatDescription)?.pointee.mSampleRate ?? 0
    }

    private func removeObservers() {
        let current = stateLock.withLock {
            defer { observers = [] }
            return observers
        }
        current.forEach(notificationCenter.removeObserver)
    }

    /// Callback or notification thread. Reports the first failure once and queues teardown.
    private func fail(_ error: Error) {
        guard gate.fail(error) else { return }
        removeObservers()
        let handler = stateLock.withLock {
            defer { terminalErrorHandler = nil }
            return terminalErrorHandler
        }
        sessionQueue.async { [weak self] in self?.tearDown(path: .failure) }
        if let handler {
            Task { await handler(error) }
        }
    }
}

/// The capture output's delegate for one capture.
private final class SampleReceiver: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let gate: CaptureCallbackGate
    private let firstAudio: FirstAudioWatch?
    private let onSamples: @Sendable ([Float]) -> Void
    private let onFailure: @Sendable (Error) -> Void

    init(
        gate: CaptureCallbackGate, firstAudio: FirstAudioWatch?, onSamples: @escaping @Sendable ([Float]) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) {
        self.gate = gate
        self.firstAudio = firstAudio
        self.onSamples = onSamples
        self.onFailure = onFailure
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard gate.enter() else { return }
        let samples: [Float]
        do {
            samples = try CaptureSamples.floats(from: sampleBuffer)
        } catch {
            gate.leave()
            onFailure(error)
            return
        }
        defer { gate.leave() }
        firstAudio?.audioArrived()
        onSamples(samples)
    }
}
