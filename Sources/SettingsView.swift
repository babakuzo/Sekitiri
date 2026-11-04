import AppKit
import EventKit
import SwiftUI

// ============================================================================
// Settings, shown in the main window (⌘,). A page title and tab row above
// native grouped forms, with an "On This Mac" rail when the window is wide.
// ============================================================================

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, recording, transcription, summaries, privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .recording: return "Recording"
        case .transcription: return "Transcription"
        case .summaries: return "Summaries"
        case .privacy: return "Privacy"
        }
    }

    var detail: String {
        switch self {
        case .general: return "Calendar, reminders and meeting detection."
        case .recording: return "Which microphone Sekitiri uses and when a recording stops on its own."
        case .transcription: return "How Sekitiri turns your meetings into text. Everything runs on this Mac; changes apply to the next recording."
        case .summaries: return "The engine and tone used to write meeting notes."
        case .privacy: return "Where your notes and recordings are kept."
        }
    }
}

struct SettingsScreen: View {
    @AppStorage("settingsTab") private var tab: SettingsTab = .general

    var body: some View {
        SKRailLayout(scrolls: false) {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(tab.title)
                        .font(SekitiriType.pageTitle)
                        .accessibilityAddTraits(.isHeader)
                    Text(tab.detail)
                        .font(SekitiriType.body)
                        .foregroundStyle(SekitiriColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SKTabRow(selection: $tab, tabs: SettingsTab.allCases) { $0.title }
                Group {
                    switch tab {
                    case .general: GeneralSettingsPane()
                    case .recording: RecordingSettingsPane()
                    case .transcription: TranscriptionSettingsPane()
                    case .summaries: SummarySettingsPane()
                    case .privacy: PrivacySettingsPane()
                    }
                }
                .padding(.horizontal, -20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        } rail: {
            SKSectionHeader("On This Mac")
            Text("Meetings never leave this Mac. Models download once, then recording, transcription and summaries run offline, with no account.")
                .font(SekitiriType.meta)
                .foregroundStyle(SekitiriColor.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button("Show Where Files Are") { tab = .privacy }
                .buttonStyle(.sk(.outline, .small))
        }
    }
}

private extension View {
    func settingsPane(height: CGFloat = 460) -> some View {
        formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: 760, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - General

private struct GeneralSettingsPane: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("meetingReminders") private var meetingReminders = true
    // Mirrors CalendarService: no stored value means "on" for older installs;
    // new installs store an explicit "off" on first launch.
    @AppStorage("browserCallDetection") private var browserCallDetection = true
    @AppStorage("teamsDesktopDetection") private var teamsDesktopDetection = true
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = true

    var body: some View {
        Form {
            Section {
                LabeledContent("Calendar") {
                    CalendarAccessControl()
                }
                Toggle("Remind me before calendar meetings", isOn: $meetingReminders)
            } header: {
                Text("Calendar")
            } footer: {
                Text("Sekitiri reads event titles, times and attendee names to name recordings and remind you. It never changes your calendar.")
            }

            Section {
                Toggle("Detect meetings in browser tabs", isOn: $browserCallDetection)
                Toggle("Detect Microsoft Teams desktop calls", isOn: $teamsDesktopDetection)
            } header: {
                Text("Meeting detection")
            } footer: {
                Text("Browser detection checks only the address of the active Chrome, Edge or Safari tab for Meet, Zoom, Teams or Webex links. Teams detection reads visible Teams window titles and needs Accessibility permission. Detection only asks — it never starts recording on its own.")
            }

            Section {
                Button("Run Setup Again…") {
                    hasCompletedOnboarding = false
                    MainWindow.show()
                }
            } footer: {
                Text("Walks through microphone, system audio and calendar access. Your meetings are not affected.")
            }
        }
        .settingsPane()
    }
}

/// Connect / status control driven by the real authorization status.
struct CalendarAccessControl: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        switch model.calendarAuthorization {
        case .fullAccess:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(SekitiriColor.terracotta)
        case .notDetermined:
            Button("Connect Calendar…") { model.requestCalendarAccess() }
        case .denied, .restricted, .writeOnly:
            HStack(spacing: 8) {
                Text(model.calendarAuthorization == .restricted ? "Restricted" : "Not allowed")
                    .foregroundStyle(SekitiriColor.muted)
                Button("Open Privacy Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                }
            }
        @unknown default:
            Button("Connect Calendar…") { model.requestCalendarAccess() }
        }
    }
}

// MARK: - Recording

private struct RecordingSettingsPane: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("recordingSafetyTimeoutMinutes") private var silenceStopMinutes = 0
    @AppStorage("systemAudio") private var systemAudio = true
    @AppStorage(MiniRecorderController.enabledKey) private var miniRecorder = true
    @AppStorage("inputDeviceID") private var inputDeviceID = ""
    @State private var inputDevices: [AudioInputDevice] = []

    var body: some View {
        Form {
            Section {
                Picker("Microphone", selection: $inputDeviceID) {
                    if inputDevices.isEmpty { Text("No microphone found").tag(inputDeviceID) }
                    ForEach(inputDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .disabled(model.recording || model.isStartingRecording)
                .help(model.recording ? "Applies to the next recording" : "")
                Toggle("Record computer audio (the other side of calls)", isOn: $systemAudio)
                Toggle("Show a floating recorder while you’re in another app", isOn: $miniRecorder)
            } header: {
                HStack {
                    Text("Audio")
                    Spacer()
                    Button("Refresh Devices", action: refreshInputDevices)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            } footer: {
                Text("Computer audio needs Screen & System Audio Recording permission; macOS asks the first time you record. If it’s unavailable, your microphone still records.")
            }

            Section {
                Picker("Stop after silence", selection: $silenceStopMinutes) {
                    Text("Off").tag(0)
                    Text("5 minutes of silence").tag(5)
                    Text("10 minutes of silence").tag(10)
                    Text("15 minutes of silence").tag(15)
                }
            } header: {
                Text("Automatic stop")
            } footer: {
                Text("If no sound reaches the microphone or computer audio for this long, Sekitiri warns you, waits one more minute, then stops and saves the recording. You’ll also get reminders after 60 and 90 minutes; calendar and call-end checks only ask.")
            }
        }
        .settingsPane()
        .onAppear {
            // Older builds stored hour-based total-time limits.
            if ![0, 5, 10, 15].contains(silenceStopMinutes) { silenceStopMinutes = 15 }
            refreshInputDevices()
        }
    }

    private func refreshInputDevices() {
        inputDevices = AudioInputDevice.available()
        if !inputDevices.contains(where: { $0.id == inputDeviceID }) {
            inputDeviceID = AudioInputDevice.defaultID() ?? inputDevices.first?.id ?? ""
        }
    }
}

// MARK: - Transcription

private struct TranscriptionSettingsPane: View {
    var body: some View {
        Form {
            TranscriptionSettingsSection()
        }
        .settingsPane()
    }
}

// MARK: - Summaries

private struct SummarySettingsPane: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("summaryTone") private var summaryTone = "Concise"
    @AppStorage("summaryPrompt.concise") private var concisePrompt = ""
    @AppStorage("summaryPrompt.detailed") private var detailedPrompt = ""
    @AppStorage("summaryPrompt.executive") private var executivePrompt = ""
    @State private var confirmingModelRemoval = false

    var body: some View {
        Form {
            Section {
                SummaryEnginePicker(showsLabel: true)
                Text(model.selectedModel.detail)
                    .font(.callout)
                    .foregroundStyle(SekitiriColor.muted)
                if model.selectedModel.requiresDownload {
                    qwenControls
                } else if model.selectedModel.id == ModelItem.appleIntelligence.id,
                          !LocalSummaryRuntime.appleFoundationModelAvailable {
                    Label("Apple Intelligence isn’t available on this Mac. Choose Quick extract or Qwen 3.5.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(SekitiriColor.warning)
                }
            } header: {
                Text("Engine")
            }

            Section {
                Picker("Default tone", selection: $summaryTone) {
                    ForEach(SummaryTonePrompts.tones, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Tone shapes the short overview. Decisions, action items and transcript references keep the same format for every tone.")
            }

            Section {
                TextEditor(text: activePromptBinding)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 120)
                    .accessibilityLabel("Instructions for \(summaryTone)")
                HStack {
                    Spacer()
                    Button("Reset to Default") { setActivePrompt("") }
                        .disabled(activePrompt.isEmpty)
                }
            } header: {
                Text("Instructions for \(summaryTone)")
            } footer: {
                Text("Saved with your preferences and sent with each summary. Today’s engines follow a fixed, evidence-checked format, so these instructions don’t change the notes yet.")
            }
        }
        .settingsPane(height: 560)
        .onAppear { Task { await model.refreshLocalSummaryModelState() } }
        .confirmationDialog(
            "Remove Qwen 3.5 from this Mac?",
            isPresented: $confirmingModelRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Download", role: .destructive) {
                Task { await model.removeLocalSummaryModel() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes only the model files. Your meetings and notes are unchanged.")
        }
    }

    @ViewBuilder
    private var qwenControls: some View {
        let model = self.model
        switch model.localSummaryModelState {
        case .ready:
            LabeledContent("Status") {
                HStack {
                    Text(ProcessInfo.processInfo.physicalMemory <= 8 * 1_073_741_824
                         ? "Downloaded · unloads after each summary"
                         : "Downloaded · unloads shortly after each summary")
                        .foregroundStyle(SekitiriColor.muted)
                    Button("Remove…", role: .destructive) { confirmingModelRemoval = true }
                }
            }
        case .failed:
            SummaryModelDownloadRow()
            Button("Remove Partial Download…", role: .destructive) { confirmingModelRemoval = true }
        default:
            SummaryModelDownloadRow()
        }
        Text("Downloads only when you choose Download — summarising never starts a download. Needs about \(ByteCountFormatter.string(fromByteCount: LocalSummaryModel.qwen2B.minimumFreeSpaceBytes, countStyle: .file)) free while downloading.")
            .font(.caption)
            .foregroundStyle(SekitiriColor.muted)
    }

    private var activePrompt: String {
        switch summaryTone {
        case "Detailed": return detailedPrompt
        case "Executive Brief": return executivePrompt
        default: return concisePrompt
        }
    }

    /// Shows the default text when nothing custom is saved; saving the
    /// default verbatim stores nothing.
    private var activePromptBinding: Binding<String> {
        Binding(
            get: { activePrompt.isEmpty ? SummaryTonePrompts.default(for: summaryTone) : activePrompt },
            set: { value in
                setActivePrompt(value == SummaryTonePrompts.default(for: summaryTone) ? "" : value)
            }
        )
    }

    private func setActivePrompt(_ prompt: String) {
        switch summaryTone {
        case "Detailed": detailedPrompt = prompt
        case "Executive Brief": executivePrompt = prompt
        default: concisePrompt = prompt
        }
    }
}

// MARK: - Privacy

private struct PrivacySettingsPane: View {
    @State private var notesFolder = MeetingNotesService.meetingsDirectory()
    @State private var recordingsFolder = AppModel.recordingsRoot()

    var body: some View {
        Form {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Meetings never leave this Mac.")
                            .font(.headline)
                        Text("Models download once, then everything runs offline. Recording, transcription and summaries happen on this Mac, with no account and no cloud service.")
                            .font(.callout)
                            .foregroundStyle(SekitiriColor.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(SekitiriColor.terracotta)
                }
            }

            Section {
                FolderRow(title: "Notes", url: notesFolder)
                FolderRow(title: "Recordings", url: recordingsFolder)
            } header: {
                Text("Where your files are")
            } footer: {
                Text("Notes are plain Markdown and stay readable without Sekitiri. The notes folder is set by meetings_dir in ~/.config/meeting-notes/config.json.")
            }
        }
        .settingsPane()
        .onAppear {
            notesFolder = MeetingNotesService.meetingsDirectory()
            recordingsFolder = AppModel.recordingsRoot()
        }
    }
}

private struct FolderRow: View {
    let title: String
    let url: URL

    private var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text(displayPath)
                    .font(.callout.monospaced())
                    .foregroundStyle(SekitiriColor.muted)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .disabled(!FileManager.default.fileExists(atPath: url.path))
                .help(FileManager.default.fileExists(atPath: url.path) ? "Reveal \(displayPath) in Finder" : "Created after your first meeting")
            }
        }
    }
}
