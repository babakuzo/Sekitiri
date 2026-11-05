import AppKit
import AVFoundation
import SwiftUI

// ============================================================================
// Record: three states on one page.
//   Set Up Recording: only when asked for or a check fails. Start buttons
//     elsewhere record straight away with these settings.
//   Recording: live transcript, notes, and a terracotta control dock.
//   Processing: steps after Stop, the transcript as it lands, notes rail.
// ============================================================================

struct RecordView: View {
    @EnvironmentObject var model: AppModel
    /// Opens a meeting by id (session folder name) in the Meetings section.
    let openMeeting: (String) -> Void
    @State private var micAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var completedTranscript: TranscriptDocument?
    @State private var completedNames = SpeakerNames()

    private var isCapturing: Bool { model.recording || model.isStartingRecording }

    var body: some View {
        Group {
            if isCapturing {
                SKRailLayout(scrolls: false) {
                    VStack(alignment: .leading, spacing: 24) {
                        RecordingHeader()
                        CaptureBanners()
                        transcriptAndNotes
                        ControlDock()
                    }
                } rail: {
                    UpNextRail()
                }
            } else if model.showingCompletedRecording {
                SKRailLayout(scrolls: false) {
                    VStack(alignment: .leading, spacing: 24) {
                        RecordingHeader()
                        ProcessingPanel(openMeeting: openMeeting)
                        transcriptPanel
                    }
                } rail: {
                    SKSectionHeader("While You Wait")
                    AdditionalNotesPanel(compact: true)
                }
            } else {
                SKRailLayout {
                    SetUpRecordingPage(micAuthorization: micAuthorization)
                } rail: {
                    TodaySchedulePanel(readiness: RecordingReadiness.current(), setUpRecording: {}, inline: false, showsFooter: false)
                }
            }
        }
        .onAppear {
            micAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
            model.retryAdditionalNotesSave()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            micAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
        }
        .task(id: completedTranscriptKey) { loadCompletedTranscript() }
    }

    @ViewBuilder
    private var transcriptAndNotes: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 28) {
                transcriptPanel.frame(minWidth: 380, maxWidth: .infinity, alignment: .topLeading)
                Rectangle().fill(SekitiriColor.rule).frame(width: 1)
                AdditionalNotesPanel(compact: false).frame(width: 300)
            }
            VStack(alignment: .leading, spacing: 24) {
                transcriptPanel
                AdditionalNotesPanel(compact: false)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: Transcript

    private var completedTranscriptKey: String {
        guard model.showingCompletedRecording, let directory = model.lastCompletedSessionDirectory else { return "" }
        return "\(directory.path)|\(model.transcriptionProgress?.stage ?? "")|\(model.isTranscribing)"
    }

    private func loadCompletedTranscript() {
        typealias Stage = TranscriptionProgressInfo.Stage
        guard model.showingCompletedRecording, let directory = model.lastCompletedSessionDirectory else {
            completedTranscript = nil
            return
        }
        let progress = model.transcriptionProgress
        let stage = progress?.session == directory.lastPathComponent ? progress?.stage : nil
        let finished = stage == Stage.ready || stage == Stage.speakers || stage == Stage.failed
            || (stage == nil && !model.isTranscribing)
        guard finished else {
            completedTranscript = nil
            return
        }
        completedTranscript = TranscriptDocument.load(in: directory)
        completedNames = SpeakerNames.load(from: completedTranscript?.directory)
    }

    private var liveSegments: [TranscriptDocument.Segment] {
        model.liveSegments.enumerated().map { index, segment in
            TranscriptDocument.Segment(id: index, speaker: segment.speaker, start: segment.start, end: nil,
                                       text: segment.text, lowConfidenceRanges: [])
        }
    }

    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .bottom, spacing: 24) {
                Text(isCapturing ? "Live Transcript" : completedTranscript == nil ? "Transcript So Far" : "Transcript")
                    .font(SekitiriType.cardTitle)
                    .padding(.bottom, 6)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(SekitiriColor.terracotta).frame(height: 2)
                    }
                    .accessibilityAddTraits(.isHeader)
                if isCapturing {
                    Text("The full transcript is finished within minutes of Stop.")
                        .font(SekitiriType.meta)
                        .foregroundStyle(SekitiriColor.muted)
                        .padding(.bottom, 8)
                }
                Spacer(minLength: 0)
                if let completedTranscript, !completedTranscript.isEmpty {
                    CopyTranscriptButton(text: completedTranscript.plainText(names: completedNames))
                        .padding(.bottom, 6)
                }
            }
            if let completedTranscript, !completedTranscript.isEmpty, !isCapturing {
                ScrollView {
                    TranscriptListView(segments: completedTranscript.segments, names: completedNames)
                        .padding(.vertical, 4)
                }
                .frame(minHeight: 240, maxHeight: .infinity)
            } else if !liveSegments.isEmpty {
                LiveTranscriptScroll(segments: liveSegments, follow: isCapturing)
                    .frame(minHeight: 240, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(isCapturing
                         ? "Lines appear here a few seconds after they’re spoken."
                         : "The transcript is being finished from the saved audio.")
                        .font(SekitiriType.reading)
                        .foregroundStyle(SekitiriColor.muted)
                    if !model.liveTranscriptionStatus.isEmpty {
                        Text(model.liveTranscriptionStatus)
                            .font(SekitiriType.meta)
                            .foregroundStyle(SekitiriColor.muted)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            }
            if isCapturing, !liveSegments.isEmpty, !model.liveTranscriptionStatus.isEmpty {
                Text(model.liveTranscriptionStatus)
                    .font(SekitiriType.caption)
                    .foregroundStyle(SekitiriColor.muted)
            }
        }
    }
}

// MARK: - Header (recording and processing)

private struct RecordingHeader: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmDeleteAudio = false
    @FocusState private var titleFocused: Bool

    private var isCapturing: Bool { model.recording || model.isStartingRecording }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                TextField("Untitled meeting", text: Binding(get: { model.recordingTitle }, set: { model.updateRecordingTitle($0) }))
                    .textFieldStyle(.plain)
                    .font(SekitiriType.pageTitle)
                    .focused($titleFocused)
                    .fixedSize(horizontal: !model.recordingTitle.isEmpty, vertical: false)
                    .accessibilityLabel("Meeting title")
                Button { titleFocused = true } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 15))
                        .foregroundStyle(SekitiriColor.muted)
                        .frame(width: 36, height: 36)
                        .background(SekitiriColor.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(SekitiriColor.line))
                }
                .buttonStyle(.plain)
                .help("Rename this meeting")
                .accessibilityLabel("Rename meeting")
                Spacer(minLength: 0)
                if model.showingCompletedRecording && !isCapturing {
                    completedActions
                }
            }
            HStack(spacing: 12) {
                badge
                Text(dateLine)
                    .font(SekitiriType.sans(17))
                    .foregroundStyle(SekitiriColor.muted)
                    .monospacedDigit()
            }
            if model.statusTone == .warning {
                Label(model.status, systemImage: "exclamationmark.triangle.fill")
                    .font(SekitiriType.label)
                    .foregroundStyle(SekitiriColor.cautionText)
            }
        }
    }

    private typealias Stage = TranscriptionProgressInfo.Stage

    @ViewBuilder
    private var badge: some View {
        if model.isStartingRecording {
            SKBadge(text: "Starting", tone: .progress)
        } else if model.recording {
            SKBadge(text: model.isPaused ? "Paused" : "Recording", tone: model.isPaused ? .outline : .live)
        } else if let progress = model.transcriptionProgress,
                  progress.session == model.lastCompletedSessionDirectory?.lastPathComponent {
            switch progress.stage {
            case Stage.ready: SKBadge(text: "Transcript ready", tone: .success, icon: "checkmark")
            case Stage.failed: SKBadge(text: "Needs attention", tone: .warning, icon: "exclamationmark")
            case Stage.speakers: SKBadge(text: "Finding speakers", tone: .progress)
            default:
                SKBadge(text: progress.fractionCompleted.map { "Transcribing, \(Int($0 * 100))%" } ?? "Transcribing", tone: .progress)
            }
        } else {
            SKBadge(text: "Saved", tone: .neutral)
        }
    }

    private var dateLine: String {
        let start = model.recordingStartedAt ?? Date()
        let day = SKDate.dayLine(start)
        let time = start.formatted(date: .omitted, time: .shortened)
        if model.isStartingRecording { return "\(day) · \(time)" }
        return model.recording ? "\(day) · \(time) · \(model.elapsed) elapsed" : "\(day) · \(time) · \(model.elapsed)"
    }

    private var completedActions: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Delete Audio…", role: .destructive) { confirmDeleteAudio = true }
                Button("Move Meeting to Trash", role: .destructive) { model.deleteCompletedMeeting() }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            Button("Done") { model.dismissCompletedRecording() }
                .buttonStyle(.sk(.outline))
                .help("Close this recording and go back to Set Up Recording")
        }
        .confirmationDialog("Delete the original audio?", isPresented: $confirmDeleteAudio, titleVisibility: .visible) {
            Button("Delete Audio", role: .destructive) { model.deleteCompletedAudio() }
            Button("Keep Audio", role: .cancel) {}
        } message: {
            Text("Your transcript, notes and action items stay available.")
        }
    }
}

// MARK: - Set Up Recording

private struct SetUpRecordingPage: View {
    @EnvironmentObject var model: AppModel
    let micAuthorization: AVAuthorizationStatus
    @AppStorage("systemAudio") private var systemAudio = true

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            if micAuthorization == .denied || micAuthorization == .restricted {
                SekitiriBanner(
                    systemImage: "mic.slash",
                    title: "Sekitiri can’t use your microphone",
                    message: "Allow Sekitiri in System Settings › Privacy & Security › Microphone, then come back.",
                    severity: .danger
                ) {
                    Button("Open Privacy Settings") { SystemSettingsLink.open(SystemSettingsLink.microphone) }
                        .buttonStyle(.sk(.outline, .small))
                }
            } else if let meeting = model.activeMeeting ?? model.upcomingMeeting,
                      model.draftMeetingTitle != meeting.title {
                SekitiriBanner(
                    systemImage: "calendar",
                    title: meeting.title,
                    message: "\(SKDate.relative(to: meeting.start, end: meeting.end)) on your calendar\(meeting.attendees.isEmpty ? "" : ", with \(meeting.attendees.count) \(meeting.attendees.count == 1 ? "attendee" : "attendees")").",
                    severity: .info
                ) {
                    Button("Use This Meeting") { model.draftMeetingTitle = meeting.title }
                        .buttonStyle(.sk(.outline, .small))
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Set Up Recording")
                    .font(SekitiriType.pageTitle)
                    .accessibilityAddTraits(.isHeader)
                Text("Start buttons, calendar cards, the menu bar and ⇧⌘R record straight away with these settings.")
                    .font(SekitiriType.body)
                    .foregroundStyle(SekitiriColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Meeting name").font(SekitiriType.labelStrong)
                    TextField("Name this meeting", text: $model.draftMeetingTitle)
                        .textFieldStyle(.plain)
                        .font(SekitiriType.sans(16))
                        .padding(.horizontal, 12)
                        .frame(height: 40)
                        .background(SekitiriColor.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(SekitiriColor.line))
                        .frame(maxWidth: 520)
                        .accessibilityLabel("Meeting name")
                    Text("Leave it blank and Sekitiri takes the name from your calendar.")
                        .font(SekitiriType.caption)
                        .foregroundStyle(SekitiriColor.muted)
                }
                .padding(.top, 8)
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Label("Microphone", systemImage: "mic").font(SekitiriType.bodyStrong)
                    Spacer()
                    MicrophonePicker(showsLabel: false)
                }
                .padding(.vertical, 14)
                Rectangle().fill(SekitiriColor.border).frame(height: 1)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Computer audio", systemImage: "speaker.wave.2").font(SekitiriType.bodyStrong)
                        Text("Records the other participants from Zoom, Teams or your browser.")
                            .font(SekitiriType.meta)
                            .foregroundStyle(SekitiriColor.muted)
                    }
                    Spacer()
                    Toggle("Computer audio", isOn: $systemAudio)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                .padding(.vertical, 14)
                Rectangle().fill(SekitiriColor.border).frame(height: 1)
                HStack(spacing: 14) {
                    Button { model.startIfNotRecording() } label: {
                        HStack(spacing: 10) {
                            Circle().fill(SekitiriColor.onAccent).frame(width: 10, height: 10)
                            Text("Start Recording")
                            Text("⇧⌘R").font(SekitiriType.caption).opacity(0.75)
                        }
                    }
                    .buttonStyle(.sk(.primary, .large))
                    .disabled(model.isFinalizingRecording || micAuthorization == .denied || micAuthorization == .restricted)
                    Text("Make sure everyone has agreed to be recorded.")
                        .font(SekitiriType.meta)
                        .foregroundStyle(SekitiriColor.muted)
                }
                .padding(.top, 18)
            }
            .sekitiriCard(cornerRadius: 14, padding: 22)

            ReadinessChecklist(micAuthorization: micAuthorization, systemAudio: systemAudio)
        }
    }
}

private struct ReadinessChecklist: View {
    let micAuthorization: AVAuthorizationStatus
    let systemAudio: Bool
    @State private var items: [(ok: Bool, text: String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SKSectionHeader("Ready to Go")
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Label {
                    Text(item.text).font(SekitiriType.sans(15))
                } icon: {
                    Image(systemName: item.ok ? "checkmark.circle" : "exclamationmark.circle")
                        .foregroundStyle(item.ok ? SekitiriColor.sage : SekitiriColor.caution)
                }
            }
        }
        .task(id: "\(micAuthorization.rawValue)|\(systemAudio)") { items = await Self.check(micAuthorization, systemAudio) }
    }

    /// Reads device route, model cache and disk space off the main thread.
    private static func check(_ mic: AVAuthorizationStatus, _ systemAudio: Bool) async -> [(ok: Bool, text: String)] {
        await Task.detached(priority: .utility) {
            var items: [(ok: Bool, text: String)] = []
            switch mic {
            case .authorized: items.append((true, "Microphone allowed"))
            case .notDetermined: items.append((true, "Microphone access is asked for on first recording"))
            default: items.append((false, "Microphone access is off"))
            }
            items.append((true, systemAudio ? "Computer audio on" : "Computer audio off, only your microphone records"))
            let headphones = AudioOutputRoute.isPrivateListening()
            switch Config.echoCancellation() {
            case .automatic: items.append((true, headphones ? "Headphones in, echo cancellation off" : "Speakers in use, echo cancellation on"))
            case .on: items.append((true, "Echo cancellation always on"))
            case .off: items.append((headphones, headphones ? "Echo cancellation off" : "Echo cancellation off while using speakers"))
            }
            let engine = Config.transcriptionEngine()
            let name = TranscriptionEngineOption(rawValue: engine).map { $0 == .ultra ? "Best accuracy" : $0.label } ?? engine
            items.append(ParakeetEngine.isCached(engine: engine)
                         ? (true, "Speech model ready (\(name))")
                         : (false, "Speech model downloads after your first recording (\(name))"))
            if let free = try? AppModel.recordingsRoot().deletingLastPathComponent()
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
                let low = free < 2_000_000_000
                items.append((!low, "\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free on this Mac\(low ? ", which may not be enough for a long meeting" : "")"))
            }
            let minutes = UserDefaults.standard.integer(forKey: "recordingSafetyTimeoutMinutes")
            items.append((true, minutes > 0 ? "Stops after \(minutes) min of silence" : "Keeps recording until you stop it"))
            return items
        }.value
    }
}

// MARK: - Capture

/// Microphone menu. Disabled during capture: the device is read at start.
private struct MicrophonePicker: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("inputDeviceID") private var inputDeviceID = ""
    @State private var devices: [AudioInputDevice] = []
    var showsLabel = true

    private var isCapturing: Bool { model.recording || model.isStartingRecording }

    var body: some View {
        Picker(selection: $inputDeviceID) {
            if devices.isEmpty { Text("No microphone found").tag(inputDeviceID) }
            ForEach(devices) { device in
                Text(device.name).tag(device.id)
            }
        } label: {
            if showsLabel { Label("Microphone", systemImage: "mic") }
        }

        .pickerStyle(.menu)
        .fixedSize()
        .disabled(isCapturing)
        .help(isCapturing ? "Applies to the next recording" : "Choose the microphone for the next recording")
        .onAppear(perform: refresh)
    }

    private func refresh() {
        devices = AudioInputDevice.available()
        if !devices.contains(where: { $0.id == inputDeviceID }) {
            inputDeviceID = AudioInputDevice.defaultID() ?? devices.first?.id ?? ""
        }
    }
}

private struct CaptureBanners: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if case .degraded(let message) = model.microphoneTrack {
                SekitiriBanner(systemImage: "mic.slash", title: "Microphone stopped", message: message, severity: .danger)
            }
            if case .degraded(let message) = model.systemAudioTrack {
                SekitiriBanner(
                    systemImage: "speaker.slash",
                    title: "Computer audio stopped. Only your microphone is recording",
                    message: "\(message) Check that Sekitiri is allowed under Screen & System Audio Recording.",
                    severity: .danger
                ) {
                    Button("Open Privacy Settings") { SystemSettingsLink.open(SystemSettingsLink.audioCapture) }
                        .buttonStyle(.sk(.outline, .small))
                }
            }
            if model.micSendingNothing, model.recording, !model.isPaused {
                SekitiriBanner(
                    systemImage: "mic.slash",
                    title: "Your microphone is sending no sound at all",
                    message: "Nothing you say is being recorded. Check that Sekitiri is allowed to use the microphone and that the mic isn’t muted, or pick another microphone in the control bar.",
                    severity: .danger
                ) {
                    Button("Open Privacy Settings") { SystemSettingsLink.open(SystemSettingsLink.microphone) }
                        .buttonStyle(.sk(.outline, .small))
                }
            }
            if let deadline = model.silenceStopDeadline {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = max(0, Int(deadline.timeIntervalSince(context.date).rounded(.up)))
                    SekitiriBanner(
                        systemImage: "speaker.zzz.fill",
                        title: "No sound. Recording stops in \(seconds) s",
                        message: "You chose to stop after a stretch of silence. The recording will be saved."
                    ) {
                        Button("Keep Recording") { model.keepRecordingThroughSilence() }
                            .buttonStyle(.sk(.primary, .small))
                    }
                }
            } else if model.noSoundWarning, model.recording {
                SekitiriBanner(
                    systemImage: "waveform.slash",
                    title: "No sound detected for 30 seconds",
                    message: "Check that your microphone is connected, unmuted and selected in System Settings."
                )
            } else if model.micSilenceWarning, model.recording, !model.micSendingNothing {
                SekitiriBanner(
                    systemImage: "mic.slash",
                    title: "Your microphone hasn’t picked up sound for 2 minutes",
                    message: "Others are still being recorded. If you’ve been speaking, check the microphone in the control bar."
                )
            }
        }
    }
}


// MARK: - Control dock

private struct ControlDock: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmDiscard = false

    var body: some View {
        HStack(spacing: 14) {
            pill {
                Circle().fill(SekitiriColor.onAccent).frame(width: 9, height: 9).opacity(model.isPaused ? 0.5 : 1)
                Text(model.isStartingRecording ? "--:--" : model.elapsed)
                    .font(SekitiriType.sans(20).monospacedDigit())
                    .accessibilityLabel("Elapsed \(model.elapsed)")
            }
            pill {
                Image(systemName: trackIcon(model.microphoneTrack, on: "mic", off: "mic.slash"))
                Text(model.microphoneDeviceName ?? "Microphone").font(SekitiriType.body).lineLimit(1)
                ActivityWaveform(isActive: model.isHearingAudio && model.recording && !model.isPaused, onAccent: true)
            }
            .help(trackHelp("Microphone", model.microphoneTrack))
            if model.systemAudioTrack != .off {
                pill {
                    Image(systemName: trackIcon(model.systemAudioTrack, on: "speaker.wave.2", off: "speaker.slash"))
                    Text("Computer audio").font(SekitiriType.body).lineLimit(1)
                }
                .help(trackHelp("Computer audio", model.systemAudioTrack))
            }
            Spacer(minLength: 8)
            Menu {
                Button("Discard Recording…", role: .destructive) { confirmDiscard = true }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(SekitiriColor.onAccent)
            .frame(width: 44, height: 44)
            .background(SekitiriColor.onAccent.opacity(0.18), in: Circle())
            .disabled(model.isFinalizingRecording)
            .help("More")
            Button { model.markMoment() } label: {
                Image(systemName: "flag")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SekitiriColor.onAccent)
                    .frame(width: 44, height: 44)
                    .background(SekitiriColor.onAccent.opacity(0.18), in: Circle())
            }
            .buttonStyle(SekitiriHoverButtonStyle())
            .disabled(!model.recording || model.isPaused)
            .help("Mark this moment (⇧⌘M)")
            .accessibilityLabel("Mark this moment")
            Button { model.togglePause() } label: {
                Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SekitiriColor.onAccent)
                    .frame(width: 44, height: 44)
                    .background(SekitiriColor.onAccent.opacity(0.18), in: Circle())
            }
            .buttonStyle(SekitiriHoverButtonStyle())
            .disabled(!model.recording || model.isFinalizingRecording)
            .help(model.isPaused ? "Resume recording (⇧⌘P)" : "Pause recording (⇧⌘P)")
            .accessibilityLabel(model.isPaused ? "Resume recording" : "Pause recording")
            Button { model.stop() } label: {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(SekitiriColor.terracotta).frame(width: 10, height: 10)
                    Text(model.isStartingRecording ? "Cancel" : "Stop & Save")
                    if !model.isStartingRecording {
                        Text("⇧⌘R").font(SekitiriType.caption).foregroundStyle(SekitiriColor.muted)
                    }
                }
            }
            .buttonStyle(.sk(.onAccent, .large))
            .disabled(model.isFinalizingRecording)
            .help(model.isStartingRecording ? "Cancel recording start" : "Stop and save (⇧⌘R)")
        }
        .foregroundStyle(SekitiriColor.onAccent)
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(SekitiriColor.terracotta, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording controls")
        .confirmationDialog(
            model.isStartingRecording ? "Cancel and discard this recording?" : "Discard this recording?",
            isPresented: $confirmDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard Recording", role: .destructive) { model.discardCurrentCapture() }
            Button("Keep Recording", role: .cancel) {}
        } message: {
            Text("The captured audio and live transcript from this recording will be deleted.")
        }
    }

    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(SekitiriColor.onAccent.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityElement(children: .combine)
    }

    private func trackIcon(_ state: CaptureTrackState, on: String, off: String) -> String {
        state == .off || state.isDegraded ? off : on
    }

    private func trackHelp(_ title: String, _ state: CaptureTrackState) -> String {
        switch state {
        case .recording: return "\(title) recording"
        case .paused: return "\(title) paused"
        case .off: return "\(title) off"
        case .degraded(let message): return message
        }
    }
}

// MARK: - Recording rail

private struct UpNextRail: View {
    @EnvironmentObject var model: AppModel

    private var upcoming: [MeetingContext] {
        let since = model.recordingStartedAt ?? Date()
        return model.todaySchedule.filter { $0.end > since && $0.title != model.recordingTitle }.prefix(3).map { $0 }
    }

    private var names: [String] {
        let attendees = (model.activeMeeting ?? model.upcomingMeeting)?.attendees ?? []
        return Config.transcriptionVocabulary(attendees: attendees)
    }

    var body: some View {
        SKSectionHeader("Up Next")
        if upcoming.isEmpty {
            Text(model.isCalendarConnected ? "Nothing else on your calendar today." : "Connect your calendar to see what’s next.")
                .font(SekitiriType.meta)
                .foregroundStyle(SekitiriColor.muted)
        }
        ForEach(upcoming, id: \.eventID) { meeting in
            VStack(alignment: .leading, spacing: 6) {
                Text(meeting.title).font(SekitiriType.cardTitle).lineLimit(2)
                Text(SKDate.slot(start: meeting.start, end: meeting.end))
                    .font(SekitiriType.sans(15).monospacedDigit())
                    .foregroundStyle(SekitiriColor.muted)
                if meeting.start < Date().addingTimeInterval(60 * 10), meeting.start > (model.recordingStartedAt ?? .distantPast) {
                    Text("Overlaps this recording")
                        .font(SekitiriType.label)
                        .foregroundStyle(SekitiriColor.terracotta)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SekitiriColor.blush, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        VStack(alignment: .leading, spacing: 8) {
            Text("Names to Listen For").font(SekitiriType.labelStrong)
            Text(names.isEmpty ? "None yet. Add people and product names so they’re spelled right." : names.prefix(12).joined(separator: ", "))
                .font(SekitiriType.meta)
                .foregroundStyle(SekitiriColor.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button("Edit Names and Terms") {
                UserDefaults.standard.set(SettingsTab.transcription.rawValue, forKey: "settingsTab")
                NotificationCenter.default.post(name: .sekitiriShowSection, object: AppSection.settings.rawValue)
            }
            .buttonStyle(.skLink)
            .font(SekitiriType.labelStrong)
            Text("Applies from the next recording.")
                .font(SekitiriType.caption)
                .foregroundStyle(SekitiriColor.muted)
        }
        .padding(.top, 8)
    }
}

// MARK: - Processing after Stop

private struct ProcessingPanel: View {
    @EnvironmentObject var model: AppModel
    let openMeeting: (String) -> Void

    private typealias Stage = TranscriptionProgressInfo.Stage

    private var progress: TranscriptionProgressInfo? {
        guard let progress = model.transcriptionProgress,
              progress.session == model.lastCompletedSessionDirectory?.lastPathComponent else { return nil }
        return progress
    }

    private var sessionID: String? { model.lastCompletedSessionDirectory?.lastPathComponent }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let progress {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(steps(for: progress)) { step in
                        StepColumn(step: step, fraction: step.kind == .active ? progress.fractionCompleted : nil)
                    }
                }
                HStack(spacing: 12) {
                    actions(for: progress)
                    Spacer(minLength: 0)
                    if let remaining = progress.remainingText, !progress.isReady, !progress.isFailed {
                        Text(remaining.prefix(1).uppercased() + remaining.dropFirst())
                            .font(SekitiriType.meta)
                            .foregroundStyle(SekitiriColor.muted)
                    }
                }
                if !progress.isReady && !progress.isFailed {
                    Text("Everything runs on this Mac. You can close this window; Sekitiri keeps working in the menu bar.")
                        .font(SekitiriType.meta)
                        .foregroundStyle(SekitiriColor.muted)
                }
            } else {
                Text(Config.transcriptionEnabled()
                     ? "Recording saved. Getting the transcript ready…"
                     : "Recording saved. Automatic transcription is turned off in your Sekitiri configuration.")
                    .font(SekitiriType.body)
                    .foregroundStyle(SekitiriColor.muted)
                if let sessionID {
                    Button("Open Meeting") { openMeeting(sessionID) }
                        .buttonStyle(.sk(.outline))
                }
            }
        }
        .sekitiriCard(cornerRadius: 14, padding: 22)
        .animation(SekitiriMotion.easeOut, value: model.transcriptionProgress)
    }

    private func steps(for progress: TranscriptionProgressInfo) -> [SekitiriProcessingStep] {
        let order = [Stage.saved, Stage.transcribing] + (Config.speakerDiarizationEnabled() ? [Stage.speakers] : []) + [Stage.ready]
        let current = order.firstIndex(of: progress.stage) ?? (progress.isFailed ? 1 : 0)
        let titles = [Stage.saved: "Audio saved", Stage.transcribing: "Transcribing", Stage.speakers: "Speakers", Stage.ready: "Ready"]
        let details = [
            Stage.saved: "Mic and computer tracks",
            Stage.transcribing: "Speech to text, on this Mac",
            Stage.speakers: "Separates other voices",
            Stage.ready: "Read it or create notes",
        ]
        return order.enumerated().map { index, stage in
            let kind: SekitiriStatusKind
            if progress.isFailed && index == current { kind = .warning }
            else if index < current || progress.isReady { kind = .ready }
            else if index == current { kind = .active }
            else { kind = .waiting }
            var title = titles[stage] ?? stage
            if kind == .active, stage == Stage.transcribing, let fraction = progress.fractionCompleted {
                title = "Transcribing, \(Int(fraction * 100))%"
            }
            if kind == .warning { title = "Transcription stopped" }
            return SekitiriProcessingStep(title: title, detail: kind == .warning ? "Your recording is safe" : details[stage] ?? "", kind: kind)
        }
    }

    @ViewBuilder
    private func actions(for progress: TranscriptionProgressInfo) -> some View {
        if progress.isReady || progress.stage == Stage.speakers, let sessionID, let directory = model.lastCompletedSessionDirectory {
            Button {
                model.pendingSummarySession = directory
                openMeeting(sessionID)
            } label: {
                Label("Create Notes", systemImage: "list.bullet.rectangle")
            }
            .buttonStyle(.skPrimary)
            .disabled(!progress.isReady)
            Button("Open Meeting") { openMeeting(sessionID) }
                .buttonStyle(.skOutline)
        } else if progress.isFailed, let directory = model.lastCompletedSessionDirectory {
            Button("Retry Transcription") { model.retryTranscription(for: directory) }
                .buttonStyle(.skPrimary)
                .disabled(model.isTranscribing)
            Button("Show Recording") { model.revealRecording(at: directory) }
                .buttonStyle(.skOutline)
            if let sessionID {
                Button("Open Meeting") { openMeeting(sessionID) }
                    .buttonStyle(.skGhost)
            }
        }
    }
}

/// One step: a bar on top (full when done, partial while running), then title and detail.
private struct StepColumn: View {
    let step: SekitiriProcessingStep
    let fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(SekitiriColor.fill)
                    Capsule().fill(barColor).frame(width: proxy.size.width * barFill)
                }
            }
            .frame(height: 4)
            HStack(spacing: 6) {
                if step.kind == .ready {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(SekitiriColor.sage)
                } else if step.kind == .warning {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 11, weight: .bold)).foregroundStyle(SekitiriColor.caution)
                }
                Text(step.title)
                    .font(SekitiriType.labelStrong)
                    .foregroundStyle(step.kind == .waiting ? SekitiriColor.muted : SekitiriColor.ink)
            }
            Text(step.detail)
                .font(SekitiriType.caption)
                .foregroundStyle(SekitiriColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var barFill: CGFloat {
        switch step.kind {
        case .ready, .warning: return 1
        case .active: return CGFloat(fraction ?? 0.35)
        default: return 0
        }
    }

    private var barColor: Color {
        switch step.kind {
        case .ready: return SekitiriColor.sage
        case .warning: return SekitiriColor.caution
        default: return SekitiriColor.terracotta
        }
    }
}

/// Decorative level indicator. Moves only while sound is being captured and
/// rests flat otherwise; hidden from accessibility.
struct ActivityWaveform: View {
    let isActive: Bool
    var onAccent = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !isActive || reduceMotion)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<5, id: \.self) { index in
                    Capsule()
                        .fill(onAccent
                              ? SekitiriColor.onAccent.opacity(isActive ? 1 : 0.4)
                              : (isActive ? SekitiriColor.terracotta : SekitiriColor.line))
                        .frame(width: 4, height: height(index: index, phase: phase))
                }
            }
            .frame(width: 32, height: 28)
        }
        .animation(.easeOut(duration: 0.2), value: isActive)
        .accessibilityHidden(true)
    }

    private func height(index: Int, phase: Double) -> CGFloat {
        guard isActive else { return 4 }
        let base: [CGFloat] = [10, 18, 26, 18, 10]
        guard !reduceMotion else { return base[index] }
        let wave = (sin(phase * 7 + Double(index) * 0.9) + 1) / 2
        return max(4, base[index] * CGFloat(0.45 + wave * 0.55))
    }
}

// MARK: - Transcript helpers

/// Live transcript that follows the newest line while recording.
private struct LiveTranscriptScroll: View {
    let segments: [TranscriptDocument.Segment]
    let follow: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                TranscriptListView(segments: segments, activeID: follow ? segments.last?.id : nil)
                    .padding(.vertical, 4)
            }
            .onChange(of: segments.count) {
                guard follow, let last = segments.last?.id else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }
}

struct CopyTranscriptButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
        } label: {
            Label(copied ? "Copied" : "Copy Transcript", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.sk(.ghost, .small))
        .help("Copy the transcript with timestamps and speaker names")
    }
}

// MARK: - Additional notes

private struct AdditionalNotesPanel: View {
    @EnvironmentObject var model: AppModel
    /// The rail version drops the heading; the rail has its own.
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !compact {
                Text("Before you forget, add some context for yourself")
                    .font(SekitiriType.label)
                    .foregroundStyle(SekitiriColor.terracotta)
                Text("Additional Notes")
                    .font(SekitiriType.cardTitle)
                    .accessibilityAddTraits(.isHeader)
            }
            Text(compact ? "Anything the recording might have missed? It’s used in the summary." : "Saved with this meeting and used in the summary")
                .font(SekitiriType.label)
                .foregroundStyle(SekitiriColor.muted)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: Binding(get: { model.additionalNotes }, set: { model.updateAdditionalNotes($0) }))
                .font(SekitiriType.sans(15))
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 220, maxHeight: compact ? 360 : .infinity)
                .padding(10)
                .background(SekitiriColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(SekitiriColor.border))
                .overlay(alignment: .topLeading) {
                    if model.additionalNotes.isEmpty {
                        Text("Write something here…")
                            .font(SekitiriType.sans(15))
                            .foregroundStyle(SekitiriColor.muted)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityLabel("Additional notes")
            if !compact, !model.markedMoments.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Marked Moments")
                        .font(SekitiriType.labelStrong)
                        .foregroundStyle(SekitiriColor.muted)
                    ForEach(model.markedMoments) { moment in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(TranscriptDocument.clock(moment.seconds))
                                .font(SekitiriType.meta.monospacedDigit())
                                .foregroundStyle(SekitiriColor.terracotta)
                            Text(moment.label)
                                .font(SekitiriType.meta)
                                .lineLimit(2)
                        }
                    }
                }
                .padding(.top, 8)
            }
            if let saveError = model.additionalNotesSaveError {
                HStack(spacing: 8) {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .font(SekitiriType.caption)
                        .foregroundStyle(SekitiriColor.dangerText)
                    Button("Retry Save") { model.retryAdditionalNotesSave() }
                        .buttonStyle(.sk(.outline, .small))
                }
            } else {
                Text(model.additionalNotesSaveStatus.isEmpty ? "Saved automatically." : model.additionalNotesSaveStatus)
                    .font(SekitiriType.caption)
                    .foregroundStyle(SekitiriColor.muted)
            }
        }
    }
}
