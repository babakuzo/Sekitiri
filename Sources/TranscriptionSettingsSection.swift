import SwiftUI

/// Every transcription control lives here so the transcription pipeline can
/// evolve independently of the rest of Settings. Use inside a `Form`.
///
/// Keys: `localTranscriptionEngine`, `echoCancellation`,
/// `transcriptionVocabulary`, `localSpeakerDiarization`.
struct TranscriptionSettingsSection: View {
    @AppStorage("localSpeakerDiarization") private var localSpeakerDiarization = false
    @AppStorage("echoCancellation") private var echoCancellation = Config.echoCancellation().rawValue
    @AppStorage("transcriptionVocabulary") private var vocabulary = ""
    @State private var engine = Config.transcriptionEngine()
    @State private var download: DownloadState = .idle
    /// Checked when the model changes or a download ends, not on every render
    /// (download progress and vocabulary typing re-render this section).
    @State private var modelCached = true

    private enum DownloadState: Equatable {
        case idle
        case downloading(Double)
        case failed(String)
    }

    var body: some View {
        Section {
            Picker("Model", selection: engineBinding) {
                ForEach(TranscriptionEngineOption.allCases) { option in
                    Text(option.label).tag(option.rawValue)
                }
            }
            if !modelCached {
                modelDownloadRow
            }
            LabeledContent("Language", value: "Detected automatically")
        } header: {
            Text("Transcription")
        } footer: {
            Text("\(selectedOption.detail) Mixed English and French is handled without changing settings. Changes apply to the next recording, and everything runs on this Mac.")
        }

        Section {
            Picker("Echo cancellation", selection: $echoCancellation) {
                Text("Automatic").tag(Config.EchoCancellation.automatic.rawValue)
                Text("Always on").tag(Config.EchoCancellation.on.rawValue)
                Text("Off").tag(Config.EchoCancellation.off.rawValue)
            }
        } footer: {
            Text("Stops meeting audio from your speakers being transcribed as you. Automatic turns it on unless you’re using headphones. Lines repeated from your speakers are also removed from the transcript.")
        }

        Section {
            TextEditor(text: $vocabulary)
                .font(.body)
                .frame(minHeight: 72)
                .accessibilityLabel("Names and terms")
        } header: {
            Text("Names and terms")
        } footer: {
            Text("One per line: people, products, company jargon. Calendar attendees are added automatically. Helps mainly with English speech and downloads a small extra model (about 100 MB) the first time.")
        }

        Section {
            Toggle("Identify separate speakers", isOn: $localSpeakerDiarization)
        } footer: {
            Text("Labels other participants as Speaker 1, Speaker 2… after the transcript is ready, and lets you rename them. Downloads a separate speech model the first time. Leave off for lighter processing.")
        }
        .onAppear { modelCached = ParakeetEngine.isCached(engine: engine) }
    }

    private var selectedOption: TranscriptionEngineOption {
        TranscriptionEngineOption(rawValue: engine) ?? .v3
    }

    private var engineBinding: Binding<String> {
        Binding(
            get: { engine },
            set: { value in
                engine = value
                download = .idle
                modelCached = ParakeetEngine.isCached(engine: value)
                UserDefaults.standard.set(value, forKey: "localTranscriptionEngine")
            }
        )
    }

    @ViewBuilder private var modelDownloadRow: some View {
        switch download {
        case .idle:
            LabeledContent("Not downloaded yet") {
                Button("Download Now", action: startDownload)
            }
        case .downloading(let fraction):
            ProgressView(value: fraction) {
                Text("Downloading model…")
            }
        case .failed(let message):
            LabeledContent {
                Button("Try Again", action: startDownload)
            } label: {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func startDownload() {
        let name = engine
        download = .downloading(0)
        Task {
            do {
                try await ParakeetEngine.download(engine: name) { fraction in
                    Task { @MainActor in
                        if engine == name, case .downloading = download { download = .downloading(fraction) }
                    }
                }
                await MainActor.run {
                    if engine == name { download = .idle; modelCached = ParakeetEngine.isCached(engine: name) }
                }
            } catch {
                await MainActor.run {
                    if engine == name { download = .failed("Download failed — check your connection.") }
                }
            }
        }
    }
}
