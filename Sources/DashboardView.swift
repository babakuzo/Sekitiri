import SwiftUI

// MARK: - Sekitiri dashboard

struct DashboardView: View {
    @EnvironmentObject var model: AppModel
    let openMeetings: () -> Void
    let openMeeting: (String) -> Void

    private var firstName: String {
        let name = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return name.components(separatedBy: " ").first ?? "there"
    }

    var body: some View {
        Group {
            if model.recording || model.isStartingRecording || model.showingCompletedRecording {
                RecordView()
            } else {
                GeometryReader { proxy in
                    let compact = proxy.size.width < 940
                    let tight = proxy.size.width < 680
                    if compact {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 28) {
                                dashboardContent(compact: true, tight: tight)
                                TodaySchedulePanel(start: { model.start(context: model.upcomingMeeting) })
                            }
                            .padding(tight ? 22 : 32)
                        }
                    } else {
                        HStack(spacing: 0) {
                            ScrollView {
                                dashboardContent(compact: false, tight: false)
                                    .padding(.horizontal, 42)
                            }
                            .frame(maxWidth: .infinity)
                            TodaySchedulePanel(start: { model.start(context: model.upcomingMeeting) })
                                .frame(width: 280)
                        }
                    }
                }
            }
        }
        .background(SekitiriColor.canvas)
    }

    @ViewBuilder
    private func dashboardContent(compact: Bool, tight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            greeting(fontSize: tight ? 30 : (compact ? 34 : 38))
            .padding(.top, compact ? 10 : 48)

            Group {
                if compact {
                    VStack(spacing: 18) { actionCards }
                } else {
                    HStack(spacing: 18) { actionCards }
                }
            }
            .padding(.top, compact ? 32 : 48)

            RecentMeetingsStrip(openMeetings: openMeetings, openMeeting: openMeeting)
                .padding(.top, compact ? 40 : 62)
                .padding(.bottom, 40)
        }
    }

    private func greeting(fontSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hello, \(firstName)")
                .font(SekitiriType.display(fontSize))
            Text("What would you like to capture today?")
                .font(SekitiriType.display(fontSize))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actionCards: some View {
        Group {
            DashboardActionCard(icon: "mic", title: "Start a meeting\nrecording", accent: true, action: { model.startIfNotRecording() })
            DashboardActionCard(icon: "doc.text", title: "Browse notes from a\nprevious meeting", accent: false, action: openMeetings)
        }
    }

}

struct CompactNavigationBar: View {
    @Binding var selected: NavTab
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            Text("Sekitiri")
                .font(SekitiriType.display(26))
                .foregroundStyle(SekitiriColor.terracotta)
            Spacer()
            if model.recording || model.isStartingRecording {
                RecordingStatusButton {
                    selected = .record
                }
            }
            Picker("Section", selection: $selected) {
                Text("Dashboard").tag(NavTab.record)
                Text("Meetings").tag(NavTab.meetings)
                Text("Settings").tag(NavTab.settings)
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(SekitiriColor.sidebar)
        .overlay(alignment: .bottom) { Divider().overlay(SekitiriColor.line) }
    }
}

struct DashboardSidebarView: View {
    @Binding var selected: NavTab
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Sekitiri")
                .font(SekitiriType.display(38))
                .foregroundStyle(SekitiriColor.terracotta)
            Divider().overlay(SekitiriColor.line).padding(.top, 10)
            VStack(alignment: .leading, spacing: 14) {
                dashboardNav("square.grid.2x2", "Dashboard", .record)
                dashboardNav("list.bullet", "Meetings", .meetings)
            }
            .padding(.top, 70)
            Spacer()
            if model.recording || model.isStartingRecording {
                RecordingStatusButton {
                    selected = .record
                }
                .padding(.bottom, 12)
            }
            Button { selected = .settings } label: {
                HStack(spacing: 10) {
                    Image(systemName: "gearshape")
                    Text("Settings")
                }
                .font(SekitiriType.body(15, weight: .medium))
                .foregroundStyle(SekitiriColor.muted)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SekitiriColor.blush, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .frame(width: 250)
        .background(SekitiriColor.sidebar)
        .overlay(alignment: .trailing) { Divider().overlay(SekitiriColor.line) }
    }

    private func dashboardNav(_ icon: String, _ title: String, _ tab: NavTab) -> some View {
        Button { selected = tab } label: {
            Label(title, systemImage: icon)
                .font(SekitiriType.body(16, weight: selected == tab ? .semibold : .regular))
                .foregroundStyle(selected == tab ? SekitiriColor.terracotta : SekitiriColor.muted)
        }
        .buttonStyle(.plain)
    }
}

private struct RecordingStatusButton: View {
    @EnvironmentObject var model: AppModel
    let action: () -> Void

    private var title: String {
        model.isStartingRecording ? "Starting recording…" : "Recording active"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(SekitiriColor.terracotta)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(SekitiriType.body(12, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(SekitiriColor.terracotta)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SekitiriColor.blush, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(SekitiriColor.terracotta.opacity(0.45)))
        }
        .buttonStyle(.plain)
        .help("Open the active recording")
        .accessibilityLabel(title)
    }
}

private struct DashboardActionCard: View {
    let icon: String
    let title: String
    let accent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(SekitiriColor.terracotta)
                    .frame(width: 70, height: 70)
                    .background(SekitiriColor.blush.opacity(accent ? 0.9 : 0.66), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                Text(title)
                    .font(SekitiriType.display(27))
                    .foregroundStyle(SekitiriColor.ink)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(25)
            .frame(maxWidth: .infinity, minHeight: 232, alignment: .topLeading)
            .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(accent ? SekitiriColor.terracotta : SekitiriColor.line, lineWidth: 1))
        }
        .buttonStyle(SekitiriHoverButtonStyle())
    }
}

struct TodaySchedulePanel: View {
    @EnvironmentObject var model: AppModel
    let start: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Today’s schedule")
                .font(SekitiriType.display(26))
            Divider().overlay(SekitiriColor.line)
            if !model.todaySchedule.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(model.todaySchedule, id: \.eventID) { meeting in
                            ScheduleCard(
                                title: meeting.title,
                                detail: Self.detail(for: meeting),
                                source: meeting.calendarSource,
                                highlight: meeting.eventID == model.upcomingMeeting?.eventID,
                                buttonTitle: "Record",
                                action: { model.start(context: meeting) }
                            )
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "calendar.badge.checkmark")
                        .font(.system(size: 24))
                        .foregroundStyle(SekitiriColor.terracotta)
                    Text("Nothing else on the calendar.")
                        .font(SekitiriType.body(14, weight: .medium))
                    Text("You can still start a free recording whenever you need it.")
                        .font(SekitiriType.body(12))
                        .foregroundStyle(SekitiriColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SekitiriColor.blush, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            Spacer()
            Text(model.calendarStatusText)
                .font(SekitiriType.body(11))
                .foregroundStyle(SekitiriColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(26)
        .background(SekitiriColor.sidebar)
    }

    private static func detail(for meeting: MeetingContext) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        let minutes = max(1, Int(meeting.end.timeIntervalSince(meeting.start) / 60))
        return "\(formatter.string(from: meeting.start)) · \(minutes)m"
    }
}

private struct ScheduleCard: View {
    let title: String
    let detail: String
    let source: String
    let highlight: Bool
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(SekitiriType.display(23))
                .lineLimit(2)
            Text(detail)
                .font(SekitiriType.body(14))
            HStack {
                Text(source)
                    .font(SekitiriType.body(11))
                Spacer()
                Button(buttonTitle, action: action)
                    .font(SekitiriType.body(11, weight: .medium))
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(highlight ? SekitiriColor.blush : SekitiriColor.terracotta, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .foregroundStyle(highlight ? SekitiriColor.ink : .white)
            }
            .padding(.top, 5)
        }
        .foregroundStyle(highlight ? Color.white : SekitiriColor.ink)
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlight ? SekitiriColor.terracotta : SekitiriColor.blush, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct RecentMeetingsStrip: View {
    let openMeetings: () -> Void
    let openMeeting: (String) -> Void
    @State private var meetings: [RecentMeetingPreview] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recent meetings")
                .font(SekitiriType.display(27))
            Divider().overlay(SekitiriColor.line)
            if meetings.isEmpty {
                Text("Your latest recordings and notes will appear here.")
                    .font(SekitiriType.body(13))
                    .foregroundStyle(SekitiriColor.muted)
                    .padding(.vertical, 24)
            } else {
                GeometryReader { proxy in
                    if proxy.size.width >= 700 {
                        HStack(spacing: 0) {
                            ForEach(Array(meetings.prefix(3).enumerated()), id: \.element.id) { index, meeting in
                                RecentMeetingColumn(meeting: meeting, openMeeting: openMeeting)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 34)
                                if index < min(meetings.count, 3) - 1 {
                                    Divider().overlay(SekitiriColor.line).frame(height: 170)
                                }
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(meetings.prefix(3).enumerated()), id: \.element.id) { index, meeting in
                                RecentMeetingColumn(meeting: meeting, openMeeting: openMeeting)
                                    .padding(.vertical, 18)
                                if index < min(meetings.count, 3) - 1 { Divider().overlay(SekitiriColor.line) }
                            }
                        }
                    }
                }
                .frame(minHeight: 174)
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        let vault = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Meetings")
        guard let folders = try? FileManager.default.contentsOfDirectory(at: vault, includingPropertiesForKeys: nil) else { return }
        meetings = folders
            .filter { $0.lastPathComponent.hasPrefix("20") }
            .compactMap(RecentMeetingPreview.init)
            .sorted { $0.id > $1.id }
    }
}

private struct RecentMeetingColumn: View {
    let meeting: RecentMeetingPreview
    let openMeeting: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SekitiriStatusBadge(title: meeting.state, kind: meeting.statusKind)
            Text(meeting.title)
                .font(SekitiriType.display(26))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(SummaryParser.inline(meeting.excerpt))
                .font(SekitiriType.body(11))
                .foregroundStyle(SekitiriColor.muted)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Notes") { openMeeting(meeting.id) }
                .font(SekitiriType.body(11, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(SekitiriColor.terracotta, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
    }
}

private struct RecentMeetingPreview: Identifiable {
    let id: String
    let title: String
    let state: String
    let excerpt: String

    var statusKind: SekitiriStatusKind {
        switch state {
        case "Summary ready": return .ready
        case "Action Items Pending": return .warning
        case "Transcription ongoing": return .active
        default: return .waiting
        }
    }

    init?(_ url: URL) {
        let fm = FileManager.default
        let summaryURL = url.appendingPathComponent("summary.md")
        let diarizedURL = url.appendingPathComponent("transcript.diarized.md")
        let transcriptURL = url.appendingPathComponent("transcript.md")
        let localMeta = (try? Data(contentsOf: url.appendingPathComponent("meta.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let sourceMeta = (try? Data(contentsOf: url.appendingPathComponent("source.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let legacySummary = (try? String(contentsOf: summaryURL, encoding: .utf8)) ?? ""
        let document = try? SummaryDocumentStore.load(from: url)
        let summary = document.map { CanonicalSummaryBuilder.markdown(from: $0) } ?? legacySummary
        let hasSummary = !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasTranscript = fm.fileExists(atPath: diarizedURL.path) || fm.fileExists(atPath: transcriptURL.path)
        let modern = fm.fileExists(atPath: url.appendingPathComponent("transcription-settings.json").path)
        let transcriptIncomplete = modern && hasTranscript && !TranscriptIntegrity.isComplete(at: url)
        let hasPendingActions = Self.hasUncheckedActions(in: summary)
        let titleOverride = (localMeta?["title_override"] as? String) ?? (sourceMeta?["title_override"] as? String)
        let recordedTitle = (localMeta?["title"] as? String) ?? (sourceMeta?["title"] as? String)
        let markdownTitle = Self.firstTitle(in: summary)
        id = url.lastPathComponent
        title = titleOverride?.isEmpty == false ? titleOverride! : (recordedTitle?.isEmpty == false ? recordedTitle! : (markdownTitle ?? "Untitled meeting"))
        state = transcriptIncomplete ? "Transcript needs attention" : hasSummary
            ? (hasPendingActions ? "Action Items Pending" : "Summary ready")
            : (hasTranscript ? "Transcript ready" : "Transcription ongoing")
        excerpt = hasSummary
            ? Self.excerpt(from: summary)
            : (transcriptIncomplete ? "Available speech was saved. Open this meeting to check the recording and retry transcription."
               : hasTranscript ? "Your transcript is saved. Open the meeting to generate notes and action items." : "Your recording is being transcribed and will be ready to review shortly.")
    }

    private static func firstTitle(in text: String) -> String? {
        text.components(separatedBy: .newlines).first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) }
    }

    private static func excerpt(from text: String) -> String {
        for heading in ["## At a glance", "## Key Takeaway", "## Summary"] {
            if let range = text.range(of: heading) {
                let remaining = text[range.upperBound...]
                let sentence = remaining.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("-") } ?? ""
                if !sentence.isEmpty { return truncate(sentence) }
            }
        }
        return "Your meeting summary is ready to review."
    }

    private static func hasUncheckedActions(in text: String) -> Bool {
        SummaryParser.hasPendingActions(text)
    }

    private static func truncate(_ text: String) -> String {
        text.count > 145 ? String(text.prefix(142)) + "…" : text
    }
}

struct SekitiriHoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

enum SekitiriType {
    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .serif) }
    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .default) }
}

enum SekitiriColor {
    static let canvas = Color(hex: 0xFDF8F4)
    static let sidebar = Color(hex: 0xF7EFE8)
    static let blush = Color(hex: 0xEAD8CC)
    static let terracotta = Color(hex: 0x984536)
    static let ink = Color(hex: 0x1C1917)
    static let muted = Color(hex: 0x625A54)
    static let line = Color(hex: 0xD8CCC2)
}
