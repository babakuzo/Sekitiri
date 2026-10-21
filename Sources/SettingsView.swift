import SwiftUI

// ============================================================================
// Screen D — Settings. Recording, Vault Sync, Privacy banner.
// ============================================================================

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("meetingReminders") private var meetingReminders = true
    @AppStorage("browserCallDetection") private var browserCallDetection = true
    @AppStorage("teamsDesktopDetection") private var teamsDesktopDetection = true
    @AppStorage("recordingSafetyTimeoutMinutes") private var recordingSafetyTimeoutMinutes = 0
    @AppStorage("systemAudio") private var systemAudio = true
    @AppStorage("inputDeviceID") private var inputDeviceID = ""
    @State private var inputDevices = AudioInputDevice.available()
    @AppStorage("vaultPath") private var vaultPath = "~/Meetings"
    @AppStorage("summaryTone") private var summaryTone = "Concise"
    @AppStorage("summaryPrompt.concise") private var concisePrompt = ""
    @AppStorage("summaryPrompt.detailed") private var detailedPrompt = ""
    @AppStorage("summaryPrompt.executive") private var executivePrompt = ""
    @AppStorage("localTranscriptionEngine") private var localTranscriptionEngine = "parakeet-v3"
    @AppStorage("transcriptionLanguage") private var transcriptionLanguage = "auto"
    @AppStorage("localSpeakerDiarization") private var localSpeakerDiarization = false
    @State private var isLoadingPrompt = false
    @State private var isSavingPrompt = false
    @State private var promptMessage = ""
    @State private var confirmingModelRemoval = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                Text("Settings")
                    .font(SekitiriType.display(38))
                    .foregroundStyle(SekitiriColor.ink)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Local notes engine")
                        .font(SekitiriType.display(25))
                    SettingsRow(label: "Model") {
                        Picker("Model", selection: $model.selectedModel) {
                            ForEach(ModelItem.builtIns) { item in
                                Text(item.name).tag(item)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 280)
                        .disabled(model.isSummarizing || model.localSummaryModelState.isBusy)
                    }
                    HStack(spacing: 12) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(SekitiriColor.terracotta)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.selectedModel.name)
                                .font(SekitiriType.body(14, weight: .medium))
                            Text(model.selectedModel.id == "source-notes"
                                 ? "Extractive notes · no language model or download"
                                 : model.selectedModel.id == "afm"
                                    ? "Apple on-device model · no model download"
                                    : "\(model.selectedModel.name) · explicit local download")
                                .font(SekitiriType.body(11))
                                .foregroundStyle(SekitiriColor.muted)
                        }
                    }
                    .padding(15)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(SekitiriColor.line))
                    if model.selectedModel.requiresDownload {
                        qwenModelControls
                    } else if model.selectedModel.id == "source-notes" {
                        Text("Ready · keeps explicit transcript statements without loading a summary model. Implicit commitments may need review; use the linked passages for context.")
                            .font(SekitiriType.body(11))
                            .foregroundStyle(SekitiriColor.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(LocalSummaryRuntime.appleFoundationModelAvailable
                             ? "Ready · built into macOS. Meeting content never leaves this Mac."
                             : "Apple Intelligence is unavailable on this Mac. Choose Qwen3.5 to use local summaries.")
                            .font(SekitiriType.body(11))
                            .foregroundStyle(LocalSummaryRuntime.appleFoundationModelAvailable ? SekitiriColor.muted : .red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    Text("Summary tone")
                        .font(SekitiriType.display(25))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], alignment: .leading, spacing: 10) {
                        ForEach(SummaryTonePrompts.tones, id: \.self) { tone in
                            Button(tone) { selectTone(tone) }
                                .font(SekitiriType.body(13, weight: .medium))
                                .buttonStyle(.plain)
                                .foregroundStyle(summaryTone == tone ? .white : SekitiriColor.ink)
                                .padding(.horizontal, 15).padding(.vertical, 10)
                                .background(summaryTone == tone ? SekitiriColor.terracotta : SekitiriColor.blush, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                    }
                    Text("Tone adjusts the short overview. Decisions, tasks and transcript references use the same format for every tone.")
                        .font(SekitiriType.body(11)).foregroundStyle(SekitiriColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsSection(title: "Local transcription") {
                    SettingsRow(label: "Language") {
                        Picker("Language", selection: $transcriptionLanguage) {
                            ForEach(TranscriptionLanguageOption.allCases) { option in
                                Text(option.label).tag(option.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 250)
                    }
                    Text(languageDescription)
                        .font(SekitiriType.body(11))
                        .foregroundStyle(SekitiriColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    SettingsRow(label: "Final transcript") {
                        Picker("", selection: $localTranscriptionEngine) {
                            Text("Parakeet v3 · multilingual").tag("parakeet-v3")
                            Text("Parakeet v2 · English only").tag("parakeet-v2")
                        }
                        .pickerStyle(.menu)
                        .frame(width: 250)
                    }
                    SettingsToggle(
                        label: "Identify separate meeting speakers",
                        isOn: $localSpeakerDiarization
                    )
                    Text("Optional speaker labels run locally after the transcript is ready. Leave this off for lighter processing. Enabling it downloads a separate speech model when needed.")
                        .font(SekitiriType.body(11))
                        .foregroundStyle(SekitiriColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsSection(title: "Summary instructions") {
                    Text("Summaries use a consistent format for decisions, action items, key points and open questions. Each extracted item includes its transcript reference so you can review the source.")
                        .font(SekitiriType.body(12))
                        .foregroundStyle(SekitiriColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Custom instructions are currently paused while we validate this format. Your saved instructions are retained.")
                        .font(SekitiriType.body(11))
                        .foregroundStyle(SekitiriColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if !activePrompt.isEmpty {
                        DisclosureGroup("Saved instructions for \(summaryTone)") {
                            Text(activePrompt)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                        }
                        .font(SekitiriType.body(11))
                    }
                }

                // MARK: Recording
                SettingsSection(title: "Recording") {
                    SettingsToggle(label: "Remind me before calendar meetings",
                                   isOn: $meetingReminders)
                    SettingsToggle(label: "Detect active browser calls (Meet, Zoom, Teams)",
                                   isOn: $browserCallDetection)
                    SettingsToggle(label: "Detect Microsoft Teams desktop calls when permitted",
                                   isOn: $teamsDesktopDetection)
                    Text("Teams desktop detection reads only visible Teams window titles and requires macOS Accessibility permission. If permission is unavailable, Sekitiri cannot reliably tell whether a Teams call is active; it will not record automatically.")
                        .font(SekitiriType.body(11))
                        .foregroundStyle(SekitiriColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    SettingsRow(label: "Recording safety timeout") {
                        Picker("", selection: $recordingSafetyTimeoutMinutes) {
                            Text("Off — I will stop manually").tag(0)
                            Text("5 minutes").tag(5)
                            Text("10 minutes").tag(10)
                            Text("15 minutes").tag(15)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 250)
                    }
                    Text("Calendar and call-end signals only ask whether the meeting is over. The timeout is the only automatic stop, and it is off by default.")
                        .font(SekitiriType.body(11))
                        .foregroundStyle(SekitiriColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    SettingsRow(label: "Calendar") {
                        Button(model.calendarStatusText == "Calendar access is not connected" ? "Connect Calendar & Reminders" : "Refresh") {
                            model.requestCalendarAccess()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    SettingsRow(label: "Primary Microphone") {
                        Picker("", selection: $inputDeviceID) {
                            ForEach(inputDevices) { device in
                                Text(device.name).tag(device.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 240)
                        Button("Refresh") { refreshInputDevices() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    SettingsToggle(label: "Record computer system audio",
                                   isOn: $systemAudio)
                }

                // MARK: Vault Sync
                SettingsSection(title: "Notes") {
                    SettingsRow(label: "Local Notes Directory") {
                        HStack(spacing: 8) {
                            TextField("", text: $vaultPath)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                            Button("Link Vault") { openVault() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        }
                    }
                }

                // MARK: Privacy banner
                PrivacyBanner()
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .background(SekitiriColor.canvas)
        .onAppear {
            // Migrate the previous hour-based choices to the new, short safety limits.
            if ![0, 5, 10, 15].contains(recordingSafetyTimeoutMinutes) {
                recordingSafetyTimeoutMinutes = 15
            }
            refreshInputDevices()
            loadSummaryPrompt()
            Task { await model.refreshLocalSummaryModelState() }
        }
        .confirmationDialog(
            "Remove Qwen3.5 from this Mac?",
            isPresented: $confirmingModelRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove downloaded model", role: .destructive) {
                Task { await model.removeLocalSummaryModel() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes only the local model files. Your meetings and summaries are unchanged.")
        }
    }

    @ViewBuilder
    private var qwenModelControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            switch model.localSummaryModelState {
            case .notDownloaded:
                Text("Not downloaded · about \(ByteCountFormatter.string(fromByteCount: (model.selectedModel.localModel ?? .qwen2B).approximateDownloadBytes, countStyle: .file)) · requires \(ByteCountFormatter.string(fromByteCount: (model.selectedModel.localModel ?? .qwen2B).minimumFreeSpaceBytes, countStyle: .file)) free during download")
                    .foregroundStyle(SekitiriColor.muted)
                Button("Download Qwen3.5") { model.downloadLocalSummaryModel() }
                    .buttonStyle(.borderedProminent)
            case .downloading(let progress):
                ProgressView(value: progress) {
                    Text("Downloading locally · \(Int(progress * 100))%")
                }
                .frame(maxWidth: 360)
                Button("Cancel download", role: .cancel) { model.cancelLocalSummaryModelDownload() }
                    .buttonStyle(.bordered)
            case .ready:
                Text(ProcessInfo.processInfo.physicalMemory <= 8 * 1_073_741_824
                     ? "Ready · unloads immediately after each summary on this Mac"
                     : "Ready · retained briefly after a summary, then unloaded")
                    .foregroundStyle(SekitiriColor.muted)
                Button("Remove download", role: .destructive) { confirmingModelRemoval = true }
                    .buttonStyle(.bordered)
            case .loading:
                ProgressView("Loading Qwen3.5…")
                    .controlSize(.small)
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Retry") { model.downloadLocalSummaryModel() }
                        .buttonStyle(.borderedProminent)
                    Button("Remove partial download", role: .destructive) { confirmingModelRemoval = true }
                        .buttonStyle(.bordered)
                }
            }
            Text("Downloads only when you choose Download. Summarise never starts a model download.")
                .font(SekitiriType.body(11))
                .foregroundStyle(SekitiriColor.muted)
        }
        .font(SekitiriType.body(12))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SekitiriColor.blush.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func refreshInputDevices() {
        inputDevices = AudioInputDevice.available()
        if !inputDevices.contains(where: { $0.id == inputDeviceID }) {
            inputDeviceID = AudioInputDevice.defaultID() ?? inputDevices.first?.id ?? ""
        }
    }

    private var languageDescription: String {
        let option = TranscriptionLanguageOption(rawValue: transcriptionLanguage)
            ?? .auto
        return "\(option.detail). Applies to the next recording."
    }

    private func openVault() {
        let expanded = NSString(string: vaultPath).expandingTildeInPath
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: expanded)
    }

    private func loadSummaryPrompt() {
        guard !isLoadingPrompt, activePrompt.isEmpty else { return }
        isLoadingPrompt = true
        promptMessage = "Loading current instructions…"
        Task {
            do {
                let prompt = try await MeetingNotesService.summaryPrompt()
                await MainActor.run {
                    setActivePrompt(prompt)
                    isLoadingPrompt = false
                    promptMessage = ""
                }
            } catch {
                await MainActor.run {
                    isLoadingPrompt = false
                    promptMessage = "Couldn’t load instructions: \(error.localizedDescription)"
                }
            }
        }
    }

    private func saveSummaryPrompt() {
        let prompt = activePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isSavingPrompt else { return }
        isSavingPrompt = true
        promptMessage = ""
        setActivePrompt(prompt)
        isSavingPrompt = false
        promptMessage = "Saved — \(summaryTone) summaries will use these instructions."
    }

    private func selectTone(_ tone: String) {
        summaryTone = tone
        promptMessage = ""
    }

    private func addDashboardOneLinerRequirement() {
        let start = "<!-- sekitiri-dashboard-summary:start -->"
        let end = "<!-- sekitiri-dashboard-summary:end -->"
        let block = """

        \(start)
        ## Dashboard one-liner
        Start every completed summary with a `## At a glance` heading followed by exactly one factual sentence (maximum 28 words). State the main outcome or topic in plain language. Do not use metadata, speaker labels, filler, or speculation.
        \(end)
        """
        var prompt = activePrompt
        if let rangeStart = prompt.range(of: start), let rangeEnd = prompt.range(of: end, range: rangeStart.upperBound..<prompt.endIndex) {
            prompt.replaceSubrange(rangeStart.lowerBound..<rangeEnd.upperBound, with: block.trimmingCharacters(in: .newlines))
        } else {
            prompt += "\n\n" + block
        }
        setActivePrompt(prompt)
        promptMessage = "Dashboard one-liner added — save instructions to apply it."
    }

    private var activePrompt: String {
        switch summaryTone {
        case "Detailed": return detailedPrompt
        case "Executive Brief": return executivePrompt
        default: return concisePrompt
        }
    }

    private func setActivePrompt(_ prompt: String) {
        switch summaryTone {
        case "Detailed": detailedPrompt = prompt
        case "Executive Brief": executivePrompt = prompt
        default: concisePrompt = prompt
        }
    }
}

// MARK: - Reusable settings components

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(SekitiriType.display(25))
                .foregroundStyle(SekitiriColor.ink)
                .padding(.bottom, 4)
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(18)
            .background(.white.opacity(0.68), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(SekitiriColor.line))
        }
    }
}

struct SettingsRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                labelView
                Spacer()
                content
            }
            VStack(alignment: .leading, spacing: 8) {
                labelView
                content
            }
        }
    }

    private var labelView: some View {
        Text(label).font(SekitiriType.body(14, weight: .medium)).foregroundStyle(SekitiriColor.ink)
    }
}

struct SettingsToggle: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(label)
                .font(SekitiriType.body(14, weight: .medium))
                .foregroundStyle(SekitiriColor.ink)
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(SekitiriColor.terracotta)
        }
    }
}

struct PrivacyBanner: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 18))
                Text("Privacy & Air-Gapping Guarantee")
                    .font(.system(.headline))
            }
            .foregroundColor(.white)

            Text("Audio, transcription, notes, and summaries stay on this Mac. Sekitiri does not send meeting content to external summary models.")
                .font(.system(.caption))
                .foregroundColor(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                startPoint: .leading, endPoint: .trailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
