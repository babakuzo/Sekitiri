import AppKit
import SwiftUI

// ============================================================================
// Menu bar: the icon shows the elapsed time while recording; clicking opens a
// small panel to start, mark, pause or stop, see what's next on the calendar,
// and jump to a recent meeting.
// ============================================================================

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.recording {
            HStack(spacing: 4) {
                Image(systemName: model.isPaused ? "pause.circle.fill" : "record.circle.fill")
                Text(model.elapsed).monospacedDigit()
            }
            .accessibilityLabel(model.isPaused ? "Sekitiri, paused, \(model.elapsed)" : "Sekitiri, recording, \(model.elapsed)")
        } else {
            Image(systemName: model.isStartingRecording ? "record.circle" : "waveform.circle")
                .accessibilityLabel("Sekitiri")
        }
    }
}

struct MenuBarPanel: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(MiniRecorderController.enabledKey) private var miniRecorder = true
    @State private var recent: [MeetingItem] = []
    @State private var readiness = RecordingReadiness.unknown

    private var capturing: Bool { model.recording || model.isStartingRecording }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sekitiri")
                    .font(SekitiriType.serif(24, .semibold))
                    .foregroundStyle(SekitiriColor.terracotta)
                Spacer()
                statusBadge
            }

            if capturing { recordingSection } else { idleSection }

            if let progress = processingLine {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progress).font(SekitiriType.meta).foregroundStyle(SekitiriColor.muted)
                }
            }

            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    rule
                    Text("Recent Meetings")
                        .font(SekitiriType.labelStrong)
                        .foregroundStyle(SekitiriColor.muted)
                        .padding(.top, 6)
                    ForEach(recent) { item in
                        MenuRow(title: item.title, detail: item.date.map(SKDate.dayLine)) {
                            open(meeting: item.id)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                rule
                Toggle("Floating recorder in other apps", isOn: $miniRecorder)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(SekitiriType.meta)
                    .padding(.vertical, 6)
                MenuRow(title: "Open Sekitiri", shortcut: "⌘O") { openMain() }
                    .keyboardShortcut("o", modifiers: .command)
                MenuRow(title: "Settings…", shortcut: "⌘,") { openMain(section: AppSection.settings.rawValue) }
                MenuRow(title: "Quit Sekitiri", shortcut: "⌘Q") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
        }
        .padding(18)
        .frame(width: 320)
        .background(SekitiriColor.canvas)
        .task(id: model.archiveRevision) { recent = Array(await MeetingLibrary.load(limit: 3)) }
        .onAppear { readiness = RecordingReadiness.current() }
    }

    // MARK: Sections

    @ViewBuilder
    private var statusBadge: some View {
        if model.isStartingRecording {
            SKBadge(text: "Starting", tone: .progress)
        } else if model.recording {
            SKBadge(text: model.isPaused ? "Paused" : "Recording", tone: model.isPaused ? .outline : .live)
        } else if model.isTranscribing {
            SKBadge(text: "Transcribing", tone: .progress)
        }
    }

    private var recordingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Text(model.isStartingRecording ? "--:--" : model.elapsed)
                    .font(SekitiriType.sans(30).monospacedDigit())
                Spacer()
                ActivityWaveform(isActive: model.isHearingAudio && model.recording && !model.isPaused)
            }
            Text(model.recordingTitle.isEmpty ? "Untitled meeting" : model.recordingTitle)
                .font(SekitiriType.serif(19, .medium))
                .lineLimit(2)
            if let mic = model.microphoneDeviceName {
                Label(mic, systemImage: "mic")
                    .font(SekitiriType.meta)
                    .foregroundStyle(SekitiriColor.muted)
            }
            HStack(spacing: 8) {
                Button { model.markMoment() } label: { Label("Mark", systemImage: "flag") }
                    .buttonStyle(.sk(.outline, .small))
                    .disabled(!model.recording || model.isPaused)
                    .help("Mark this moment (⇧⌘M)")
                Button { model.togglePause() } label: {
                    Label(model.isPaused ? "Resume" : "Pause", systemImage: model.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.sk(.outline, .small))
                .disabled(!model.recording || model.isFinalizingRecording)
                Spacer(minLength: 0)
                Button(model.isStartingRecording ? "Cancel" : "Stop & Save") { model.stop() }
                    .buttonStyle(.sk(.primary, .small))
                    .disabled(model.isFinalizingRecording)
            }
        }
    }

    private var idleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                model.startIfNotRecording()
                closePanel()
            } label: {
                HStack(spacing: 10) {
                    Circle().fill(SekitiriColor.onAccent).frame(width: 9, height: 9)
                    Text("Start Recording")
                    Spacer()
                    Text("⇧⌘R").font(SekitiriType.caption).opacity(0.75)
                }
            }
            .buttonStyle(SKButtonStyle(kind: .primary, size: .regular, fullWidth: true))
            .disabled(model.isFinalizingRecording)
            Text(readiness.startDetail)
                .font(SekitiriType.caption)
                .foregroundStyle(SekitiriColor.muted)
                .fixedSize(horizontal: false, vertical: true)

            if let meeting = model.activeMeeting ?? model.upcomingMeeting {
                VStack(alignment: .leading, spacing: 4) {
                    Text(SKDate.relative(to: meeting.start, end: meeting.end))
                        .font(SekitiriType.labelStrong)
                        .foregroundStyle(SekitiriColor.terracotta)
                    Text(meeting.title)
                        .font(SekitiriType.serif(19, .medium))
                        .lineLimit(2)
                    HStack {
                        Text(SKDate.slot(start: meeting.start, end: meeting.end))
                            .font(SekitiriType.meta.monospacedDigit())
                            .foregroundStyle(SekitiriColor.muted)
                        Spacer()
                        Button("Record") {
                            model.start(context: meeting)
                            closePanel()
                        }
                        .buttonStyle(.sk(.outline, .small))
                    }
                }
                .padding(14)
                .background(SekitiriColor.blush, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private var processingLine: String? {
        guard !capturing, model.isTranscribing else { return nil }
        if let fraction = model.transcriptionProgress?.fractionCompleted {
            return "Transcribing the last meeting, \(Int(fraction * 100))%"
        }
        return "Transcribing the last meeting…"
    }

    private var rule: some View {
        Rectangle().fill(SekitiriColor.border).frame(height: 1)
    }

    // MARK: Actions

    private func open(meeting id: String) {
        model.requestedMeetingID = id
        openMain()
    }

    private func openMain(section: String? = nil) {
        if let section { model.requestedSection = section }
        closePanel()
        MainWindow.show()
    }

    private func closePanel() {
        NSApp.windows.first { $0.className.contains("MenuBarExtra") }?.close()
    }
}

private struct MenuRow: View {
    let title: String
    var detail: String? = nil
    var shortcut: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(SekitiriType.sans(14)).lineLimit(1)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail).font(SekitiriType.caption).foregroundStyle(SekitiriColor.muted).lineLimit(1)
                }
                if let shortcut {
                    Text(shortcut).font(SekitiriType.caption).foregroundStyle(SekitiriColor.muted)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(hovering ? SekitiriColor.blush : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
