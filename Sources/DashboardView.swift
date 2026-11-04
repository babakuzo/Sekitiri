import AVFoundation
import SwiftUI

// MARK: - Sekitiri dashboard

struct DashboardView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.skShowsRail) private var showsRail
    let startRecording: () -> Void
    let setUpRecording: () -> Void
    let openMeetings: () -> Void
    let openMeeting: (String) -> Void
    @State private var recent: [MeetingItem] = []
    @State private var inbox = OpenActionItem.Inbox()
    @State private var readiness = RecordingReadiness.current()

    private var firstName: String {
        let name = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return name.components(separatedBy: " ").first.flatMap { $0.isEmpty ? nil : $0 } ?? "there"
    }

    var body: some View {
        SKRailLayout {
            VStack(alignment: .leading, spacing: 40) {
                header
                actionCards
                if !showsRail {
                    VStack(alignment: .leading, spacing: 16) {
                        TodaySchedulePanel(readiness: readiness, setUpRecording: setUpRecording, inline: true)
                    }
                }
                OpenActionItemsSection(inbox: $inbox, openMeeting: openMeeting)
                RecentMeetingsSection(meetings: recent, openMeetings: openMeetings, openMeeting: openMeeting)
            }
        } rail: {
            TodaySchedulePanel(readiness: readiness, setUpRecording: setUpRecording, inline: false)
        }
        .task(id: model.archiveRevision) {
            let all = await MeetingLibrary.load()
            recent = Array(all.prefix(3))
            inbox = await OpenActionItem.load(from: all)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            readiness = RecordingReadiness.current()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(SKDate.dayLine())
                .font(SekitiriType.body)
                .foregroundStyle(SekitiriColor.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text("Hello, \(firstName)")
                    .foregroundStyle(SekitiriColor.ink)
                Text("What can I help you capture today?")
                    .fontWeight(.medium)
                    .foregroundStyle(SekitiriColor.muted)
            }
            .font(SekitiriType.pageTitle)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
    }

    private var actionCards: some View {
        HStack(alignment: .top, spacing: 24) {
            if model.recording || model.isStartingRecording {
                DashboardActionCard(
                    icon: "waveform",
                    title: model.isStartingRecording ? "Starting your recording" : "Recording in progress",
                    detail: model.isStartingRecording ? "Getting the microphone ready." : "\(model.elapsed) so far. Open it to add notes or stop.",
                    shortcut: "⇧⌘R",
                    accent: true,
                    action: setUpRecording
                )
            } else {
                DashboardActionCard(
                    icon: "mic",
                    title: "Start a meeting recording",
                    detail: readiness.startDetail,
                    shortcut: "⇧⌘R",
                    accent: true,
                    action: startRecording
                )
                .disabled(model.isFinalizingRecording)
            }
            DashboardActionCard(
                icon: "doc.text.magnifyingglass",
                title: "Browse notes from a previous meeting",
                detail: "Search titles, people and notes.",
                shortcut: "⌘K",
                accent: false,
                action: openMeetings
            )
        }
    }
}

// MARK: - Readiness

/// What the next recording will use, read when the dashboard appears or the
/// app becomes active. Cheap: device names and a permission status only.
struct RecordingReadiness: Equatable {
    var microphoneName: String?
    var microphoneAllowed: Bool
    var microphoneUndetermined: Bool
    var systemAudio: Bool

    static func current() -> RecordingReadiness {
        let devices = AudioInputDevice.available()
        let requested = UserDefaults.standard.string(forKey: "inputDeviceID")
        let device = devices.first(where: { $0.id == requested })
            ?? AudioInputDevice.defaultID().flatMap { id in devices.first(where: { $0.id == id }) }
            ?? devices.first
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return RecordingReadiness(
            microphoneName: device?.name,
            microphoneAllowed: status == .authorized,
            microphoneUndetermined: status == .notDetermined,
            systemAudio: UserDefaults.standard.object(forKey: "systemAudio") as? Bool ?? true
        )
    }

    var startDetail: String {
        let mic = microphoneName ?? "microphone"
        if !microphoneAllowed && !microphoneUndetermined {
            return "Microphone access is off. Open Set Up Recording to fix it."
        }
        return systemAudio
            ? "Starts right away with your \(mic) and computer audio."
            : "Starts right away with your \(mic)."
    }
}

// MARK: - Action cards

private struct DashboardActionCard: View {
    let icon: String
    let title: String
    let detail: String
    let shortcut: String?
    let accent: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    Image(systemName: icon)
                        .font(.system(size: 30, weight: .regular))
                        .foregroundStyle(SekitiriColor.terracotta)
                        .frame(width: 72, height: 72)
                        .background(accent ? SekitiriColor.tint : SekitiriColor.sidebar,
                                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .accessibilityHidden(true)
                    Spacer()
                    if let shortcut { SKKbd(keys: shortcut) }
                }
                Text(title)
                    .font(SekitiriType.serif(28, .semibold))
                    .foregroundStyle(SekitiriColor.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 300, alignment: .leading)
                Text(detail)
                    .font(SekitiriType.body)
                    .foregroundStyle(SekitiriColor.muted)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
            .background(SekitiriColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(accent ? SekitiriColor.terracotta : SekitiriColor.line, lineWidth: accent ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(isEnabled ? 1 : 0.55)
        }
        .buttonStyle(SekitiriHoverButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(shortcut.map { "Shortcut \($0)" } ?? "")
    }
}

// MARK: - Schedule

struct TodaySchedulePanel: View {
    @EnvironmentObject var model: AppModel
    let readiness: RecordingReadiness
    let setUpRecording: () -> Void
    /// Inline on narrow windows: cards flow in a grid and the readiness lines
    /// are left to the start card.
    let inline: Bool
    var showsFooter = true

    var body: some View {
        SKSectionHeader("Today’s Schedule")
        if !model.isCalendarConnected {
            VStack(alignment: .leading, spacing: 12) {
                Text("Connect your calendar to see today’s meetings here and name recordings for you.")
                    .font(SekitiriType.meta)
                    .foregroundStyle(SekitiriColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Connect Calendar") { model.requestCalendarAccess() }
                    .buttonStyle(.sk(.outline, .small))
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SekitiriColor.blush, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        } else if model.todaySchedule.isEmpty {
            Text("Nothing else on your calendar today.")
                .font(SekitiriType.meta)
                .foregroundStyle(SekitiriColor.muted)
                .padding(.vertical, 4)
        } else if inline {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 14)], alignment: .leading, spacing: 14) {
                cards
            }
        } else {
            cards
        }
        if !inline && showsFooter {
            Spacer(minLength: 24)
            readinessFooter
        }
    }

    @ViewBuilder
    private var cards: some View {
        let featuredID = model.activeMeeting?.eventID ?? model.upcomingMeeting?.eventID
        ForEach(model.todaySchedule, id: \.eventID) { meeting in
            ScheduleCard(
                meeting: meeting,
                featured: meeting.eventID == featuredID,
                recordDisabled: model.recording || model.isStartingRecording || model.isFinalizingRecording,
                record: { model.start(context: meeting) }
            )
        }
    }

    private var readinessFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(SekitiriColor.rule).frame(height: 1).padding(.bottom, 6)
            ReadinessLine(
                ok: readiness.microphoneAllowed,
                text: readiness.microphoneAllowed
                    ? "\(readiness.microphoneName ?? "Microphone") ready"
                    : readiness.microphoneUndetermined ? "Microphone access asked on first recording" : "Microphone access is off"
            )
            ReadinessLine(ok: readiness.systemAudio, text: readiness.systemAudio ? "Computer audio on" : "Computer audio off")
            Button("Set Up Recording…", action: setUpRecording)
                .buttonStyle(.skLink)
                .font(SekitiriType.labelStrong)
                .padding(.top, 2)
        }
    }
}

private struct ReadinessLine: View {
    let ok: Bool
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(ok ? SekitiriColor.sage : SekitiriColor.caution)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(text).font(SekitiriType.meta)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ScheduleCard: View {
    let meeting: MeetingContext
    let featured: Bool
    let recordDisabled: Bool
    let record: () -> Void

    private var secondary: Color { featured ? SekitiriColor.onAccent.opacity(0.82) : SekitiriColor.muted }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if featured {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(SKDate.relative(to: meeting.start, end: meeting.end, now: context.date))
                        .font(SekitiriType.labelStrong)
                        .foregroundStyle(secondary)
                }
            }
            Text(meeting.title)
                .font(SekitiriType.cardTitle)
                .foregroundStyle(featured ? SekitiriColor.onAccent : SekitiriColor.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(SKDate.slot(start: meeting.start, end: meeting.end))
                .font(SekitiriType.sans(15).monospacedDigit())
                .foregroundStyle(secondary)
            HStack {
                Text(attendeeLine)
                    .font(SekitiriType.label)
                    .foregroundStyle(featured ? secondary : SekitiriColor.terracotta)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button(featured ? "Start Recording" : "Record", action: record)
                    .buttonStyle(.sk(featured ? .onAccent : .outline, .small))
                    .disabled(recordDisabled)
                    .accessibilityLabel("Record \(meeting.title)")
            }
            .padding(.top, 6)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(featured ? SekitiriColor.terracotta : SekitiriColor.blush,
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var attendeeLine: String {
        switch meeting.attendees.count {
        case 0: return meeting.meetingURL == nil ? "No attendees" : "Online meeting"
        case 1: return meeting.attendees[0]
        default: return "\(meeting.attendees.count) people"
        }
    }
}

// MARK: - Open action items

/// One unfinished action from a meeting's saved summary.
struct OpenActionItem: Identifiable, Sendable {
    let meeting: MeetingItem
    var item: CanonicalActionItem
    var id: String { "\(meeting.id)/\(item.id)" }

    /// The first few open actions plus totals across every meeting.
    struct Inbox: Sendable {
        var items: [OpenActionItem] = []
        var totalOpen = 0
        var meetingCount = 0
    }

    /// Reads summaries only for meetings already known to have open actions.
    static func load(from meetings: [MeetingItem], limit: Int = 5) async -> Inbox {
        await Task.detached(priority: .utility) {
            var inbox = Inbox()
            for meeting in meetings where meeting.status == .actionsPending {
                guard let document = try? SummaryDocumentStore.load(from: meeting.url) else { continue }
                let open = document.actionItems.filter { !$0.isCompleted && !isPlaceholder($0.text) }
                guard !open.isEmpty else { continue }
                inbox.totalOpen += open.count
                inbox.meetingCount += 1
                let room = limit - inbox.items.count
                if room > 0 { inbox.items += open.prefix(room).map { OpenActionItem(meeting: meeting, item: $0) } }
            }
            return inbox
        }.value
    }

    /// Models sometimes write "None." when a meeting had no actions.
    static func isPlaceholder(_ text: String) -> Bool {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
        return cleaned.isEmpty || ["none", "n/a", "na", "no action items", "nothing"].contains(cleaned)
    }

    /// Untitled meetings are told apart by their date instead.
    var meetingLabel: String {
        guard meeting.title == "Untitled meeting", let date = meeting.date else { return meeting.title }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

private struct OpenActionItemsSection: View {
    @EnvironmentObject var model: AppModel
    @Binding var inbox: OpenActionItem.Inbox
    let openMeeting: (String) -> Void
    @State private var saveError: String?

    private var items: [OpenActionItem] { inbox.items }
    /// Rows checked off this session are still listed but no longer open.
    private var openCount: Int { inbox.totalOpen - items.filter(\.item.isCompleted).count }
    private var meetingCount: Int { inbox.meetingCount }

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SKSectionHeader(title: "Open Action Items") {
                    Text("\(openCount) open across \(meetingCount) \(meetingCount == 1 ? "meeting" : "meetings")")
                        .font(SekitiriType.body)
                        .foregroundStyle(SekitiriColor.muted)
                }
                if let saveError {
                    SekitiriBanner(systemImage: "exclamationmark.triangle", title: "Couldn’t save that change", message: saveError, severity: .danger)
                        .padding(.vertical, 6)
                }
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, action in
                        ActionRow(action: action, toggle: { toggle(index) }, open: { openMeeting(action.meeting.id) })
                        if index < items.count - 1 {
                            Rectangle().fill(SekitiriColor.border).frame(height: 1)
                        }
                    }
                }
            }
        }
    }

    /// Checked rows stay in place, struck through, so a mis-click is undone
    /// by clicking again. They drop off the next time the dashboard loads.
    private func toggle(_ index: Int) {
        let action = items[index]
        do {
            let document = try SummaryDocumentStore.toggleAction(id: action.item.id, in: action.meeting.url, transcript: "")
            if let updated = document.actionItems.first(where: { $0.id == action.item.id }) {
                inbox.items[index].item = updated
            }
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }
}

private struct ActionRow: View {
    let action: OpenActionItem
    let toggle: () -> Void
    let open: () -> Void

    private var done: Bool { action.item.isCompleted }

    var body: some View {
        HStack(spacing: 14) {
            Button(action: toggle) {
                Image(systemName: done ? "checkmark.square.fill" : "square")
                    .font(.system(size: 18))
                    .foregroundStyle(done ? SekitiriColor.terracotta : SekitiriColor.muted)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(done ? "Mark not done: \(action.item.text)" : "Mark done: \(action.item.text)")

            Text(action.item.text)
                .font(SekitiriType.sans(16))
                .foregroundStyle(done ? SekitiriColor.muted : SekitiriColor.ink)
                .strikethrough(done, color: SekitiriColor.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)

            if let owner = action.item.owner?.trimmingCharacters(in: .whitespaces), !owner.isEmpty {
                SKPersonPill(name: owner, color: SKPersonPill.color(for: owner))
            }
            Text(action.item.dueDateText?.isEmpty == false ? action.item.dueDateText! : "No date")
                .font(SekitiriType.meta)
                .foregroundStyle(action.item.dueDateText?.isEmpty == false ? SekitiriColor.terracotta : SekitiriColor.muted)
                .frame(minWidth: 70, alignment: .leading)
            Button(action: open) {
                Text(action.meetingLabel)
                    .font(SekitiriType.meta)
                    .foregroundStyle(SekitiriColor.muted)
                    .underline(true, color: SekitiriColor.line)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .frame(width: 170, alignment: .trailing)
            .help("Open \(action.meeting.title)")
        }
        .padding(.vertical, 12)
    }
}

// MARK: - Recent meetings

private struct RecentMeetingsSection: View {
    let meetings: [MeetingItem]
    let openMeetings: () -> Void
    let openMeeting: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SKSectionHeader(title: "Recent Meetings") {
                if !meetings.isEmpty {
                    Button("View All", action: openMeetings)
                        .buttonStyle(.skLink)
                        .font(SekitiriType.bodyStrong)
                }
            }
            if meetings.isEmpty {
                Text("Your latest recordings and notes appear here after your first meeting.")
                    .font(SekitiriType.body)
                    .foregroundStyle(SekitiriColor.muted)
            } else {
                SKColumnGrid(items: meetings) { meeting in
                    MeetingColumn(item: meeting, showsButton: true) { openMeeting(meeting.id) }
                }
            }
        }
    }
}
