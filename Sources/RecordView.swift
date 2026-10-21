import SwiftUI

// ============================================================================
// Screen A — Record / Live Transcript.
// Figma-inspired live recorder: compact header, transcript stream, clear state.
// ============================================================================

struct RecordView: View {
    @EnvironmentObject var model: AppModel
    @State private var section: CaptureSection = .transcript
    @AppStorage("inputDeviceID") private var inputDeviceID = ""

    private enum CaptureSection: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case transcript = "Transcript"
        var id: String { rawValue }
    }

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 940
            if compact {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        captureContent(compact: true)
                        TodaySchedulePanel(start: { model.start(context: model.upcomingMeeting) })
                    }
                    .padding(proxy.size.width < 680 ? 22 : 32)
                }
            } else {
                HStack(spacing: 0) {
                    ScrollView { captureContent(compact: false).padding(.horizontal, 42) }
                        .frame(maxWidth: .infinity)
                    TodaySchedulePanel(start: { model.start(context: model.upcomingMeeting) })
                        .frame(width: 280)
                }
            }
        }
        .background(SekitiriColor.canvas)
        .onAppear { model.retryAdditionalNotesSave() }
    }

    private func captureContent(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
                    Group {
                        if compact {
                            VStack(alignment: .leading, spacing: 16) {
                                HStack(alignment: .top) {
                                    recordingHeading
                                    Spacer()
                                    deletionMenu
                                }
                                if !model.recording && !model.isStartingRecording { backButton }
                            }
                        } else {
                            HStack(alignment: .top) {
                                recordingHeading
                                Spacer()
                                deletionMenu
                                if !model.recording && !model.isStartingRecording { backButton }
                            }
                        }
                    }
                    .padding(.top, compact ? 8 : 42)

                    Group {
                        if compact {
                            VStack(alignment: .leading, spacing: 28) { transcriptPanel; additionalNotesPanel }
                        } else {
                            HStack(alignment: .top, spacing: 38) {
                                transcriptPanel.frame(maxWidth: .infinity, alignment: .leading)
                                Divider().overlay(SekitiriColor.line).frame(height: 480)
                                additionalNotesPanel.frame(width: 330)
                            }
                        }
                    }
                    .padding(.top, 40)

                    RecordingControlBar(inputDeviceID: $inputDeviceID)
                        .padding(.top, 42)
                        .padding(.bottom, 36)
        }
    }

    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 30) {
                ForEach(CaptureSection.allCases) { item in
                    Button(item.rawValue) { section = item }
                        .font(SekitiriType.display(26))
                        .foregroundStyle(section == item ? SekitiriColor.ink : SekitiriColor.muted)
                        .buttonStyle(.plain)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(section == item ? SekitiriColor.terracotta : SekitiriColor.line).frame(height: 1).offset(y: 8)
                        }
                }
            }
            .padding(.bottom, 18)
            if section == .summary && !model.recording {
                Text("Your recording is being transcribed and prepared for review.")
                    .font(SekitiriType.display(22)).padding(.top, 20)
            } else if model.liveSegments.isEmpty && !model.hasSavedTranscript {
                VStack(alignment: .leading, spacing: 14) {
                    Text(model.recording ? "Saved transcript sections will appear during your meeting." : "Your transcript is being finished from the saved audio.")
                        .font(SekitiriType.display(20))
                    Text(model.liveTranscriptionStatus.isEmpty ? model.status : model.liveTranscriptionStatus)
                        .font(SekitiriType.body(13)).foregroundStyle(SekitiriColor.muted)
                    if model.recording && !model.isPaused { FigmaLiveWaveform() }
                }
                .padding(.top, 22)
            } else {
                TranscriptView(text: model.latestTranscript, liveSegments: model.liveSegments, isLive: model.recording)
                    .frame(minHeight: 330).padding(.top, 18)
            }
        }
    }

    private var additionalNotesPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Before you forget, add some contextual notes for yourself")
                .font(SekitiriType.body(10)).foregroundStyle(SekitiriColor.terracotta)
            Text("Additional Notes").font(SekitiriType.display(26))
            TextEditor(text: Binding(get: { model.additionalNotes }, set: { model.updateAdditionalNotes($0) }))
                .font(SekitiriType.body(13))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 300)
                .padding(12)
                .background(.white.opacity(0.7))
                .overlay(alignment: .topLeading) {
                    if model.additionalNotes.isEmpty {
                        Text("Write something here…").font(SekitiriType.body(11)).foregroundStyle(SekitiriColor.muted).padding(16).allowsHitTesting(false)
                    }
                }
            if let saveError = model.additionalNotesSaveError {
                VStack(alignment: .leading, spacing: 7) {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .font(SekitiriType.body(10))
                        .foregroundStyle(.red)
                    Button("Retry save") { model.retryAdditionalNotesSave() }
                        .font(SekitiriType.body(10, weight: .medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(SekitiriColor.terracotta)
                }
            } else {
                Text(model.additionalNotesSaveStatus.isEmpty
                     ? "Your notes will be saved automatically and included when this meeting is summarised."
                     : "\(model.additionalNotesSaveStatus) · included as context when this meeting is summarised.")
                    .font(SekitiriType.body(10)).foregroundStyle(SekitiriColor.muted)
            }
        }
    }

    private var recordingHeading: some View {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Untitled meeting", text: Binding(
                                get: { model.recordingTitle },
                                set: { model.updateRecordingTitle($0) }
                            ))
                                .textFieldStyle(.plain)
                                .font(SekitiriType.display(36))
                            Text(model.isStartingRecording ? "Starting recorder" : (model.recording ? "Recording in progress" : "Recording complete"))
                                .font(SekitiriType.body(14, weight: .medium))
                                .foregroundStyle(SekitiriColor.terracotta)
                            if !model.recordingSafetyStatus.isEmpty {
                                Text(model.recordingSafetyStatus)
                                    .font(SekitiriType.body(11))
                                    .foregroundStyle(SekitiriColor.terracotta)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text("\(Date.now.formatted(date: .complete, time: .shortened)) · \(model.elapsed) elapsed")
                                .font(SekitiriType.body(13))
                                .foregroundStyle(SekitiriColor.muted)
                        }
    }

    private var backButton: some View {
        Button("Back to dashboard") { model.dismissCompletedRecording() }
            .font(SekitiriType.body(12, weight: .medium))
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .padding(.horizontal, 13).padding(.vertical, 9)
            .background(SekitiriColor.terracotta, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    @ViewBuilder
    private var deletionMenu: some View {
        if model.recording || model.isStartingRecording || model.showingCompletedRecording {
            MeetingDeletionMenu()
        }
    }
}

private struct RecordingControlBar: View {
    @EnvironmentObject var model: AppModel
    @Binding var inputDeviceID: String
    @State private var showingDiscardConfirmation = false

    private var devices: [AudioInputDevice] { AudioInputDevice.available() }
    private var selectedDeviceName: String {
        devices.first(where: { $0.id == inputDeviceID })?.name
            ?? devices.first(where: { $0.id == AudioInputDevice.defaultID() })?.name
            ?? "No microphone found"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.status)
                .font(SekitiriType.body(11))
                .foregroundStyle(.white.opacity(0.82))
            HStack(spacing: 22) {
                HStack(spacing: 16) {
                    Image(systemName: model.recording ? "record.circle.fill" : "record.circle")
                        .accessibilityLabel(model.recording ? "Recording active" : "Recording setup")
                    Text(model.elapsed).monospacedDigit()
                    Button { model.togglePause() } label: {
                        Image(systemName: model.isPaused ? "play.circle.fill" : "pause.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(model.isPaused ? "Resume recording" : "Pause recording")
                    .disabled(model.isStartingRecording || !model.recording)
                    Button { model.stop() } label: { Image(systemName: "stop.circle.fill") }
                        .buttonStyle(.plain)
                        .accessibilityLabel(model.isStartingRecording ? "Cancel starting recording" : "Stop recording")
                }
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(SekitiriColor.terracotta)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(SekitiriColor.canvas, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                Menu {
                    if devices.isEmpty { Text("No microphone found") }
                    ForEach(devices) { device in
                        Button(device.name) { inputDeviceID = device.id }
                    }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "mic.fill")
                        Text(selectedDeviceName).lineLimit(1)
                        Image(systemName: "chevron.down")
                    }
                    .font(SekitiriType.body(13, weight: .medium))
                    .foregroundStyle(SekitiriColor.ink)
                    .padding(.horizontal, 15).padding(.vertical, 12)
                    .background(SekitiriColor.canvas, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .menuStyle(.borderlessButton)
                .disabled(model.isStartingRecording)
                if model.recording || model.isStartingRecording {
                    Button(role: .destructive) { showingDiscardConfirmation = true } label: {
                        Label("Discard", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
                Spacer(minLength: 0)
            }
            Text(model.captureHealthStatus)
                .font(SekitiriType.body(11))
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SekitiriColor.terracotta, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .confirmationDialog(
            model.isStartingRecording ? "Cancel and discard this recording?" : "Discard this recording?",
            isPresented: $showingDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard recording", role: .destructive) { model.discardCurrentCapture() }
            Button("Keep recording", role: .cancel) {}
        } message: {
            Text("The captured audio and any live transcript from this recording will be deleted.")
        }
    }
}

private struct MeetingDeletionMenu: View {
    @EnvironmentObject var model: AppModel
    @State private var showingDeleteAudioConfirmation = false
    @State private var showingDeleteMeetingConfirmation = false

    var body: some View {
        if model.recording || model.isStartingRecording {
            EmptyView()
        } else {
            Menu {
                Button("Delete audio…", role: .destructive) { showingDeleteAudioConfirmation = true }
                Button("Delete meeting…", role: .destructive) { showingDeleteMeetingConfirmation = true }
            } label: {
                Label("Delete", systemImage: "trash")
                    .font(SekitiriType.body(12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .confirmationDialog("Delete the original audio?", isPresented: $showingDeleteAudioConfirmation, titleVisibility: .visible) {
                Button("Delete audio", role: .destructive) { model.deleteCompletedAudio() }
                Button("Keep audio", role: .cancel) {}
            } message: {
                Text("Your transcript, summary, notes, and action items will remain available.")
            }
            .confirmationDialog("Delete this entire meeting?", isPresented: $showingDeleteMeetingConfirmation, titleVisibility: .visible) {
                Button("Delete meeting", role: .destructive) { model.deleteCompletedMeeting() }
                Button("Keep meeting", role: .cancel) {}
            } message: {
                Text("This permanently deletes the audio, transcript, summary, action items, and additional notes from this Mac.")
            }
        }
    }
}

private struct FigmaLiveWaveform: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: reduceMotion)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
            HStack(alignment: .center, spacing: 16) {
                ForEach(0..<5, id: \.self) { index in
                    let height = barHeight(index: index, phase: phase)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(SekitiriColor.terracotta)
                        .frame(width: 18, height: reduceMotion ? restingHeight(index) : height)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 230)
            .accessibilityLabel("Live transcription is listening")
        }
    }

    private func barHeight(index: Int, phase: Double) -> CGFloat {
        let base = restingHeight(index)
        let wave = (sin((phase * .pi * 2) + Double(index) * 0.8) + 1) / 2
        return base * (0.58 + wave * 0.62)
    }

    private func restingHeight(_ index: Int) -> CGFloat { [56, 138, 194, 138, 56][index] }
}

// MARK: - Transcript scroll view

struct TranscriptView: View {
    let text: String
    let liveSegments: [TranscriptionCoordinator.LiveSegment]
    let isLive: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !liveSegments.isEmpty {
                        ForEach(liveSegments) { segment in
                            LiveTranscriptRow(segment: segment, isLatest: segment.id == liveSegments.last?.id)
                        }
                    } else {
                        ForEach(Array(parseTranscript(text).enumerated()), id: \.offset) { entry in
                            TranscriptEntryView(entry: entry.element)
                        }
                    }

                    // Auto-scroll anchor
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.vertical, 10)
            }
            .onChange(of: text) {
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: liveSegments.count) {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    /// Parse speaker-attributed transcript lines into structured entries.
    private func parseTranscript(_ raw: String) -> [TranscriptEntry] {
        var entries: [TranscriptEntry] = []
        let lines = raw.components(separatedBy: .newlines)
        var currentSpeaker: String?
        var currentText: [String] = []
        _ = 0 // speaker detection below

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // Check for speaker line: "[Speaker N]" or "**[Speaker N]**"
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                // Flush previous
                if let speaker = currentSpeaker, !currentText.isEmpty {
                    entries.append(.init(speaker: speaker, text: currentText.joined(separator: " ")))
                }
                currentSpeaker = trimmed.replacingOccurrences(of: "**", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                currentText = []
            } else {
                currentText.append(trimmed)
            }
        }
        if let speaker = currentSpeaker, !currentText.isEmpty {
            entries.append(.init(speaker: speaker, text: currentText.joined(separator: " ")))
        }

        // If no speakers found, show the whole thing as a single block
        if entries.isEmpty && !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            entries = [.init(speaker: nil, text: raw)]
        }
        return entries
    }
}

struct LiveTranscriptRow: View {
    let segment: TranscriptionCoordinator.LiveSegment
    let isLatest: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(clock(segment.start))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(isLatest ? .accentColor : .secondary)
                .frame(width: 40, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(segment.speaker)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isLatest ? .accentColor : .secondary)
                Text(segment.text)
                    .font(.system(size: 13))
                    .foregroundColor(isLatest ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(isLatest ? 12 : 0)
        .background(isLatest ? Color.accentColor.opacity(0.09) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

enum TranscriptEntry {
    case attributed(speaker: String, text: String)
    case plain(text: String)

    init(speaker: String?, text: String) {
        if let speaker = speaker {
            self = .attributed(speaker: speaker, text: text)
        } else {
            self = .plain(text: text)
        }
    }

    var speaker: String? {
        if case .attributed(let s, _) = self { return s }
        return nil
    }
    var text: String {
        switch self {
        case .attributed(_, let t): return t
        case .plain(let t): return t
        }
    }
}

struct TranscriptEntryView: View {
    let entry: TranscriptEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let speaker = entry.speaker {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                    Text(speaker)
                        .font(.system(.caption, weight: .semibold))
                        .foregroundColor(.accentColor)
                }
            }
            Text(entry.text)
                .font(.system(.body))
                .foregroundColor(.primary)
        }
    }
}

// MARK: - Footer bar (recording controls)

struct FooterBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            // Recording status pill
            Button(action: { model.toggleRecording() }) {
                HStack(spacing: 8) {
                    if model.recording {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                            .overlay(
                                Circle()
                                    .stroke(Color.red.opacity(0.4), lineWidth: 2)
                                    .frame(width: 14, height: 14)
                            )
                    }
                    Text(model.recording
                         ? "Recording · \(model.elapsed)"
                         : "Start Recording")
                        .font(.system(.body, weight: .medium))
                    if model.recording {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 12))
                    }
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(model.recording ? Color.red : Color.accentColor)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Spacer()

            if model.recording {
                Button(action: { model.stop() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12))
                        Text("Stop Recording")
                            .font(.system(.body, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.accentColor)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
