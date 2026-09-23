@preconcurrency import AVFoundation
import Foundation
import Speech

final class AppleSpeechBackend: SpeechToTextBackend {
    let id = "apple-speech"
    let displayName = "Apple Speech"

    private let isMacOS26OrLater: @Sendable () -> Bool
    private let isSpeechTranscriberAvailable: @Sendable () async -> Bool
    private let prepareAssets: @Sendable (Locale) async throws -> Void
    private let transcribeAudio: @Sendable (AudioInput, Locale) async throws -> String

    init(
        isMacOS26OrLater: @escaping @Sendable () -> Bool = AppleSpeechBackend.defaultOSSupport,
        isSpeechTranscriberAvailable: @escaping @Sendable () async -> Bool = AppleSpeechBackend.defaultTranscriberAvailability,
        prepareAssets: @escaping @Sendable (Locale) async throws -> Void = AppleSpeechBackend.defaultAssetPreparation,
        transcribeAudio: @escaping @Sendable (AudioInput, Locale) async throws -> String = AppleSpeechBackend.defaultTranscription
    ) {
        self.isMacOS26OrLater = isMacOS26OrLater
        self.isSpeechTranscriberAvailable = isSpeechTranscriberAvailable
        self.prepareAssets = prepareAssets
        self.transcribeAudio = transcribeAudio
    }

    func availability() async -> BackendAvailability {
        guard isMacOS26OrLater() else {
            return .unsupportedOS
        }
        return await isSpeechTranscriberAvailable() ? .available : .unsupportedHardware
    }

    func transcribe(audio: AudioInput, options: STTOptions) async throws -> Transcript {
        guard isMacOS26OrLater() else {
            throw SpeechBackendError.unsupportedOS
        }
        guard await isSpeechTranscriberAvailable() else {
            throw SpeechBackendError.unsupportedHardware
        }
        guard #available(macOS 26.0, *) else {
            throw SpeechBackendError.unsupportedOS
        }

        let locale = Locale(identifier: options.localeIdentifier)
        do {
            try await prepareAssets(locale)
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SpeechBackendError {
            throw error
        } catch {
            throw SpeechBackendError.initializationFailed("Apple Speech preparation failed")
        }

        do {
            let text = try await transcribeAudio(audio, locale)
            try Task.checkCancellation()
            return Transcript(text: text, backendID: id)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SpeechBackendError {
            throw error
        } catch {
            throw SpeechBackendError.inferenceFailed("Apple Speech analysis failed")
        }
    }

    private static func defaultOSSupport() -> Bool {
        if #available(macOS 26.0, *) {
            true
        } else {
            false
        }
    }

    private static func defaultTranscriberAvailability() async -> Bool {
        guard #available(macOS 26.0, *) else {
            return false
        }
        return AppleSpeechRuntime.isTranscriberAvailable
    }

    private static func defaultAssetPreparation(locale: Locale) async throws {
        guard #available(macOS 26.0, *) else {
            throw SpeechBackendError.unsupportedOS
        }
        try await AppleSpeechRuntime.prepare(locale: locale)
        try Task.checkCancellation()
    }

    private static func defaultTranscription(audio: AudioInput, locale: Locale) async throws -> String {
        guard #available(macOS 26.0, *) else {
            throw SpeechBackendError.unsupportedOS
        }
        let text = try await AppleSpeechRuntime.transcribe(audio: audio, locale: locale)
        try Task.checkCancellation()
        return text
    }
}

@available(macOS 26.0, *)
private enum AppleSpeechRuntime {
    static var isTranscriberAvailable: Bool {
        SpeechTranscriber.isAvailable
    }

    static func prepare(locale: Locale) async throws {
        let transcriber = try await makeTranscriber(locale: locale)
        let modules: [any SpeechModule] = [transcriber]

        switch await AssetInventory.status(forModules: modules) {
        case .installed:
            return
        case .unsupported:
            throw SpeechBackendError.unsupportedHardware
        case .supported, .downloading:
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else {
                throw SpeechBackendError.initializationFailed("Apple Speech assets could not be installed")
            }
            try await request.downloadAndInstall()
        @unknown default:
            throw SpeechBackendError.initializationFailed("Unknown Apple Speech asset status")
        }
    }

    static func transcribe(audio: AudioInput, locale: Locale) async throws -> String {
        guard !audio.samples.isEmpty, audio.sampleRate > 0 else {
            throw SpeechBackendError.invalidInput
        }

        let transcriber = try await makeTranscriber(locale: locale)
        let modules: [any SpeechModule] = [transcriber]
        let naturalFormat = try makeAudioFormat(sampleRate: audio.sampleRate)
        guard let compatibleFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: modules,
            considering: naturalFormat
        ) else {
            throw SpeechBackendError.inferenceFailed("No compatible Apple Speech audio format")
        }
        let buffer = try makeBuffer(audio: audio, inputFormat: naturalFormat, outputFormat: compatibleFormat)
        let analyzer = SpeechAnalyzer(modules: modules)
        try await analyzer.prepareToAnalyze(in: compatibleFormat)

        let resultsTask = Task { () throws -> [SpeechTranscriber.Result] in
            var results: [SpeechTranscriber.Result] = []
            for try await result in transcriber.results where result.isFinal {
                results.append(result)
            }
            return results
        }

        func cancelAnalysisAndFinishResults() async {
            await analyzer.cancelAndFinishNow()
            resultsTask.cancel()
            _ = try? await resultsTask.value
        }

        do {
            return try await withTaskCancellationHandler {
                let input = AsyncStream<AnalyzerInput> { continuation in
                    continuation.yield(AnalyzerInput(buffer: buffer))
                    continuation.finish()
                }
                if let finalizationTime = try await analyzer.analyzeSequence(input) {
                    try await analyzer.finalizeAndFinish(through: finalizationTime)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
                let results = try await resultsTask.value
                try Task.checkCancellation()
                return results.map { String($0.text.characters) }.joined()
            } onCancel: {
                resultsTask.cancel()
                Task {
                    await analyzer.cancelAndFinishNow()
                }
            }
        } catch is CancellationError {
            await cancelAnalysisAndFinishResults()
            throw CancellationError()
        } catch let error as SpeechBackendError {
            await cancelAnalysisAndFinishResults()
            throw error
        } catch {
            await cancelAnalysisAndFinishResults()
            throw SpeechBackendError.inferenceFailed(error.localizedDescription)
        }
    }

    private static func makeTranscriber(locale: Locale) async throws -> SpeechTranscriber {
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw SpeechBackendError.unsupportedHardware
        }
        return SpeechTranscriber(locale: supportedLocale, preset: .transcription)
    }

    private static func makeAudioFormat(sampleRate: Double) throws -> AVAudioFormat {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw SpeechBackendError.invalidInput
        }
        return format
    }

    private static func makeBuffer(
        audio: AudioInput,
        inputFormat: AVAudioFormat,
        outputFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(audio.samples.count)
        ), let channelData = inputBuffer.floatChannelData else {
            throw SpeechBackendError.inferenceFailed("Unable to create Apple Speech input buffer")
        }
        audio.samples.withUnsafeBufferPointer { samples in
            channelData[0].update(from: samples.baseAddress!, count: samples.count)
        }
        inputBuffer.frameLength = AVAudioFrameCount(audio.samples.count)

        guard inputFormat.isEqual(outputFormat) else {
            return try convert(inputBuffer, to: outputFormat)
        }
        return inputBuffer
    }

    private static func convert(_ inputBuffer: AVAudioPCMBuffer, to outputFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let converter = AVAudioConverter(from: inputBuffer.format, to: outputFormat) else {
            throw SpeechBackendError.inferenceFailed("Unable to convert Apple Speech input")
        }
        let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let frameCapacity = AVAudioFrameCount((Double(inputBuffer.frameLength) * ratio).rounded(.up))
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else {
            throw SpeechBackendError.inferenceFailed("Unable to allocate converted Apple Speech input")
        }

        let result = AudioBufferUtilities.convert(inputBuffer, into: outputBuffer, using: converter, exhaustedStatus: .endOfStream)
        guard result.status != .error, result.error == nil, outputBuffer.frameLength > 0 else {
            throw SpeechBackendError.inferenceFailed("Unable to convert Apple Speech input")
        }
        return outputBuffer
    }
}
