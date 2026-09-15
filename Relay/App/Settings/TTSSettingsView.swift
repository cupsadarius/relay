import AVFoundation
import FluidAudio
import SwiftUI

struct TTSSettingsView: View {
    @Bindable var model: AppModel
    private let appleVoices = AVSpeechSynthesisVoice.speechVoices().sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
    /// American-English Kokoro voices only, per the plan: the rest of `TtsConstants.availableVoices`
    /// covers other languages that aren't tested/supported yet.
    private static let kokoroVoices = TtsConstants.availableVoices.filter {
        $0.hasPrefix("af_") || $0.hasPrefix("am_")
    }
    /// FluidAudio's `PocketTtsConstants` exposes no voice list - only `defaultVoice` ("alba") is
    /// a documented built-in voice; cloning support is out of scope here.
    private static let pocketVoices = [PocketTtsConstants.defaultVoice]

    var body: some View {
        Form {
            Section("Backends") {
                ForEach(model.ttsBackends) { backend in
                    ttsBackendRow(backend)
                }

                if let message = model.ttsBackendMessage {
                    Text(message)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("tts-backend-message")
                }

                Text("Relay speaks through enabled backends in order and falls back to the next one. Neural backends run fully on-device after a one-time model download.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Apple Voice") {
                Picker("Voice", selection: appleVoiceBinding) {
                    Text("System Default").tag(nil as String?)
                    ForEach(appleVoices, id: \.identifier) { voice in
                        Text("\(voice.name) — \(voice.language)")
                            .tag(voice.identifier as String?)
                    }
                }
            }

            Section("Kokoro Voice") {
                Picker("Voice", selection: kokoroVoiceBinding) {
                    Text("Recommended — \(TtsConstants.recommendedVoice)").tag(nil as String?)
                    ForEach(Self.kokoroVoices, id: \.self) { voice in
                        Text(voice).tag(voice as String?)
                    }
                }
            }

            Section("PocketTTS Voice") {
                Picker("Voice", selection: pocketVoiceBinding) {
                    Text("Recommended — \(PocketTtsConstants.defaultVoice)").tag(nil as String?)
                    ForEach(Self.pocketVoices, id: \.self) { voice in
                        Text(voice).tag(voice as String?)
                    }
                }
            }

            Section("Speech") {
                HStack {
                    Slider(value: rateBinding, in: 0.1...1.0, step: 0.05)
                    Text(model.settings.ttsRate, format: .number.precision(.fractionLength(2)))
                        .monospacedDigit()
                        .frame(width: 38, alignment: .trailing)
                }
                .accessibilityLabel("Speech rate")

                Button("Test Voice") {
                    Task { await model.testVoice() }
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.refreshTTSBackendStatuses() }
    }

    private func ttsBackendRow(_ backend: TTSBackendStatus) -> some View {
        let enabledCount = model.ttsBackends.filter(\.isEnabled).count
        let isEnabledBinding = Binding(
            get: { backend.isEnabled },
            set: { model.setTTSBackendEnabled(backend.id, $0) }
        )
        return HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(backend.displayName)
                Text(ttsBackendStatusLabel(backend.state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            ttsBackendActionView(backend)

            Toggle("", isOn: isEnabledBinding)
                .labelsHidden()

            if backend.isEnabled {
                VStack(spacing: 2) {
                    Button {
                        model.moveTTSBackend(backend.id, up: true)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(backend.position == 0)

                    Button {
                        model.moveTTSBackend(backend.id, up: false)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(backend.position == enabledCount - 1)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder
    private func ttsBackendActionView(_ backend: TTSBackendStatus) -> some View {
        switch backend.state {
        case let .downloading(progress):
            ProgressView(value: progress)
                .frame(width: 80)
        case .modelNotDownloaded, .downloadFailed:
            if model.canDownloadTTSModel(backend.id) {
                Button("Download") {
                    Task { await model.downloadTTSModel(backend.id) }
                }
                .controlSize(.small)
            }
        case .ready, .unsupported, .unavailable:
            EmptyView()
        }
    }

    private func ttsBackendStatusLabel(_ state: TTSBackendStatus.State) -> String {
        switch state {
        case .ready: "Ready"
        case .modelNotDownloaded: "Model not downloaded"
        case let .downloading(progress): "Downloading \(Int((progress * 100).rounded()))%"
        case .downloadFailed: "Download failed"
        case .unsupported: "Unsupported on this Mac"
        case .unavailable: "Unavailable"
        }
    }

    private var appleVoiceBinding: Binding<String?> {
        Binding(
            get: { model.settings.ttsVoiceIdentifier },
            set: { model.setVoiceIdentifier($0) }
        )
    }

    private var kokoroVoiceBinding: Binding<String?> {
        Binding(
            get: { model.settings.kokoroVoice },
            set: { model.setKokoroVoice($0) }
        )
    }

    private var pocketVoiceBinding: Binding<String?> {
        Binding(
            get: { model.settings.pocketVoice },
            set: { model.setPocketVoice($0) }
        )
    }

    private var rateBinding: Binding<Double> {
        Binding(
            get: { Double(model.settings.ttsRate) },
            set: { model.setSpeechRate(Float($0)) }
        )
    }
}
