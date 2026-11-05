import AppKit
import SwiftUI
import UniformTypeIdentifiers

// ============================================================================
// Meetings — searchable archive grouped by date, and a meeting page with the
// structured summary, a seekable transcript and a pinned audio player.
// ============================================================================

// MARK: - Meeting model

enum MeetingStatus: Equatable, Sendable {
    case transcribing
    case needsAttention
    case transcriptReady
    case notesReady
    case actionsPending

    var title: String {
        switch self {
        case .transcribing: return "Transcribing"
        case .needsAttention: return "Needs attention"
        case .transcriptReady: return "Transcript ready"
        case .notesReady: return "Notes ready"
        case .actionsPending: return "Action items pending"
        }
    }

    var kind: SekitiriStatusKind {
        switch self {
        case .transcribing: return .active
        case .needsAttention: return .warning
        case .transcriptReady: return .waiting
        case .notesReady: return .ready
        case .actionsPending: return .pending
        }
    }
}

struct MeetingItem: Identifiable, Sendable {
    let id: String
    let url: URL
    let title: String
    let engine: String
    let durationSeconds: Int?
    let date: Date?
    let participants: [String]
    let sourceSession: URL?
    let status: MeetingStatus
    let excerpt: String
    /// Lower-cased title, participants and summary text for search.
    let searchText: String

    /// The capture folder when it still exists, else the vault folder.
    var workingDirectory: URL { sourceSession ?? url }

    var duration: String {
        guard let durationSeconds, durationSeconds > 0 else { return "" }
        let minutes = max(1, Int((Double(durationSeconds) / 60).rounded()))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes) min"
    }

    /// Recordings are stored in the source session; older imported meetings
    /// may also have their tracks directly beside the canonical note files.
    /// Reads the disk — call once when a meeting opens, not from `body`.
    func loadRecordingTrackURLs() -> [URL] {
        let roots = [sourceSession, url].compactMap { $0 }
        var seen = Set<String>()
        return roots.flatMap { root in
            ["mic.caf", "system.caf"].map { root.appendingPathComponent($0) }
        }.filter { candidate in
            guard FileManager.default.fileExists(atPath: candidate.path), !seen.contains(candidate.path) else { return false }
            seen.insert(candidate.path)
            return true
        }
    }

    var engineShort: String {
        switch engine {
        case "source-notes": return "Quick extract"
        case "afm": return "Apple Intelligence"
        case "qwen3.5-2b": return "Qwen 3.5 2B"
        case "qwen3.5-0.8b": return "Qwen 3.5 0.8B"
        case "qwen3-4b": return "Qwen 3 4B"
        case "gemma3n-e2b": return "Gemma 3n E2B"
        default: return engine.isEmpty ? "Local" : engine
        }
    }

    var dateString: String {
        guard let date else { return id }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    var metadataLine: String {
        [dateString, duration.isEmpty ? nil : duration].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Reads meetings from the notes vault and the recordings folder. All disk
/// work happens here, off the main actor, so views never touch the disk in
/// `body`.
enum MeetingLibrary {
    enum RenameError: Error { case noMetadata }

    /// Writes `title_override` into the metadata file the library reads for
    /// this meeting: the note folder's meta.json, else the capture's.
    static func rename(_ item: MeetingItem, to title: String) throws {
        let candidates = [item.url.appendingPathComponent("meta.json")]
            + (item.sourceSession.map { [$0.appendingPathComponent("meta.json")] } ?? [])
        guard let metaURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw RenameError.noMetadata
        }
        var meta = try JSONSerialization.jsonObject(with: Data(contentsOf: metaURL)) as? [String: Any] ?? [:]
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { meta.removeValue(forKey: "title_override") } else { meta["title_override"] = trimmed }
        let data = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: metaURL, options: .atomic)
    }

    static func load(limit: Int? = nil) async -> [MeetingItem] {
        let vault = MeetingNotesService.meetingsDirectory()
        let recordings = AppModel.recordingsRoot()
        return await Task.detached(priority: .userInitiated) {
            let items = build(vault: vault, recordingsRoot: recordings)
            return limit.map { Array(items.prefix($0)) } ?? items
        }.value
    }

    private static func build(vault: URL, recordingsRoot: URL) -> [MeetingItem] {
        let fm = FileManager.default
        let index = (try? Data(contentsOf: vault.appendingPathComponent(".index.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let indexedMeetings = index?["meetings"] as? [[String: Any]] ?? []
        let vaultEntries = (try? fm.contentsOfDirectory(at: vault, includingPropertiesForKeys: nil)) ?? []

        var items: [MeetingItem] = vaultEntries
            .filter { $0.lastPathComponent.hasPrefix("20") && isDirectory($0) }
            .map { url in
                let folder = url.lastPathComponent
                let sourceSession = (indexedMeetings.first(where: { ($0["id"] as? String) == folder })?["sourceSessionDir"] as? String)
                    .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                    .flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil }
                return makeItem(id: folder, url: url, sourceSession: sourceSession)
            }
        let indexedSessionPaths = Set(items.compactMap(\.sourceSession).map(\.standardizedFileURL.path))
        let recordingEntries = (try? fm.contentsOfDirectory(at: recordingsRoot, includingPropertiesForKeys: nil)) ?? []
        items += recordingEntries.compactMap { directory -> MeetingItem? in
            guard !indexedSessionPaths.contains(directory.standardizedFileURL.path),
                  fm.fileExists(atPath: directory.appendingPathComponent("meta.json").path) else { return nil }
            return makeItem(id: directory.lastPathComponent, url: directory, sourceSession: directory)
        }
        return items.sorted { ($0.date ?? .distantPast, $0.id) > ($1.date ?? .distantPast, $1.id) }
    }

    private static func makeItem(id: String, url: URL, sourceSession: URL?) -> MeetingItem {
        let fm = FileManager.default
        let source = sourceSession ?? url
        let localMeta = json(url.appendingPathComponent("meta.json"))
        let sourceMeta = json(url.appendingPathComponent("source.json")) ?? json(source.appendingPathComponent("meta.json"))
        let meta = localMeta ?? sourceMeta

        let legacySummary = (try? String(contentsOf: url.appendingPathComponent("summary.md"), encoding: .utf8)) ?? ""
        let document = try? SummaryDocumentStore.load(from: url)
        let summary = document.map { CanonicalSummaryBuilder.markdown(from: $0) } ?? legacySummary
        let hasSummary = !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let transcriptNames = ["transcript.md", "transcript.diarized.md", "transcript.json"]
        let hasTranscript = [url, source].contains { directory in
            transcriptNames.contains { fm.fileExists(atPath: directory.appendingPathComponent($0).path) }
        }
        let modern = fm.fileExists(atPath: source.appendingPathComponent("transcription-settings.json").path)

        let status: MeetingStatus
        let excerpt: String
        if hasTranscript, modern, !TranscriptIntegrity.isComplete(at: source) {
            status = .needsAttention
            excerpt = "Some audio couldn’t be transcribed. Open the meeting to check the recording and retry."
        } else if hasSummary {
            let hasOpenActions = document.map { doc in
                doc.actionItems.contains { !$0.isCompleted && !OpenActionItem.isPlaceholder($0.text) }
            } ?? SummaryParser.hasPendingActions(summary)
            status = hasOpenActions ? .actionsPending : .notesReady
            excerpt = oneLineSummary(from: summary)
        } else if hasTranscript {
            status = .transcriptReady
            excerpt = "Transcript saved. Open the meeting to create notes and action items."
        } else if let log = try? String(contentsOf: source.appendingPathComponent("transcribe.log"), encoding: .utf8),
                  log.localizedCaseInsensitiveContains("transcription failed") {
            status = .needsAttention
            excerpt = "Transcription needs attention. Your recording is preserved."
        } else {
            status = .transcribing
            excerpt = "Your recording is saved and being transcribed."
        }

        let override = (meta?["title_override"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let recordedTitle = (meta?["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = [override, recordedTitle, markdownTitle(in: summary)]
            .compactMap { $0 }
            .first { !$0.isEmpty } ?? "Untitled meeting"
        let participants = meta?["attendees"] as? [String] ?? []
        let date = (meta?["started"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? parseDate(from: id)
        let duration = meta?["duration_seconds"] as? Int

        return MeetingItem(
            id: id,
            url: url,
            title: title,
            engine: engine(in: legacySummary),
            durationSeconds: duration,
            date: date,
            participants: participants,
            sourceSession: sourceSession,
            status: status,
            excerpt: excerpt,
            searchText: ([title] + participants + [summary]).joined(separator: "\n").lowercased()
        )
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    private static func json(_ url: URL) -> [String: Any]? {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private static func markdownTitle(in summary: String) -> String? {
        summary.components(separatedBy: .newlines)
            .first { $0.hasPrefix("# ") }
            .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
    }

    private static func engine(in summary: String) -> String {
        for line in summary.components(separatedBy: .newlines).prefix(30) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("engine:") {
                let value = String(t.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                return value.components(separatedBy: "|").first ?? value
            }
        }
        return ""
    }

    private static func oneLineSummary(from markdown: String) -> String {
        for heading in ["## At a glance", "## Key Takeaway", "## Summary"] {
            guard let range = markdown.range(of: heading, options: .caseInsensitive) else { continue }
            let paragraph = String(markdown[range.upperBound...])
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("-") }
            if let paragraph, !paragraph.isEmpty {
                return paragraph.count > 155 ? String(paragraph.prefix(152)) + "…" : paragraph
            }
        }
        return "Your meeting notes are ready to review."
    }

    private static func parseDate(from folder: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy.MM.dd-HHmm"
        if let date = formatter.date(from: String(folder.prefix(15))) { return date }
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(folder.prefix(10)))
    }
}

// MARK: - Screen

struct MeetingsScreenView: View {
    @EnvironmentObject var model: AppModel
    @Binding var selectedMeetingID: String?
    @State private var items: [MeetingItem] = []
    @State private var hasLoaded = false
    @State private var query = ""
    @State private var filter: ArchiveFilter = .all
    @State private var person: String?
    @State private var renaming: MeetingItem?
    @State private var renameText = ""

    private var selectedItem: MeetingItem? {
        guard let selectedMeetingID else { return nil }
        return items.first { $0.id == selectedMeetingID || $0.sourceSession?.lastPathComponent == selectedMeetingID }
    }

    var body: some View {
        Group {
            if let item = selectedItem {
                MeetingDetailView(item: item, onBack: { selectedMeetingID = nil })
                    .id(item.id)
            } else if selectedMeetingID != nil && !hasLoaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SKRailLayout {
                    MeetingArchiveView(
                        allItems: items,
                        items: filteredItems,
                        query: $query,
                        filter: $filter,
                        isFiltering: !query.trimmingCharacters(in: .whitespaces).isEmpty || filter != .all || person != nil,
                        open: { selectedMeetingID = $0.id },
                        rename: { item in
                            renameText = item.title == "Untitled meeting" ? "" : item.title
                            renaming = item
                        },
                        delete: { item in
                            if let session = item.sourceSession, model.deleteMeeting(session: session) {
                                items.removeAll { $0.id == item.id }
                            }
                        }
                    )
                } rail: {
                    PeopleRail(items: items, selected: $person)
                }
            }
        }
        .task(id: model.archiveRevision) {
            items = await MeetingLibrary.load()
            hasLoaded = true
        }
        .alert(
            "Rename meeting",
            isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
        ) {
            TextField("Meeting name", text: $renameText)
            Button("Rename") {
                if let item = renaming { model.renameMeeting(item, to: renameText) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Leave it empty to go back to the original name.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .sekitiriSnapshotOpenMeeting)) { _ in
            selectedMeetingID = (items.first { $0.status == .actionsPending || $0.status == .notesReady } ?? items.first)?.id
        }
    }

    private var filteredItems: [MeetingItem] {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        return items.filter { item in
            guard filter.includes(item) else { return false }
            if let person, !item.participants.contains(person) { return false }
            return terms.allSatisfy { item.searchText.contains($0) }
        }
    }
}

enum ArchiveFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case openActions = "With Open Actions"
    case needsAttention = "Needs Attention"

    var id: String { rawValue }

    func includes(_ item: MeetingItem) -> Bool {
        switch self {
        case .all: return true
        case .openActions: return item.status == .actionsPending
        case .needsAttention: return item.status == .needsAttention
        }
    }
}

private struct MeetingGroup: Identifiable {
    let title: String
    let items: [MeetingItem]
    var id: String { title }

    static func grouped(_ items: [MeetingItem], now: Date = Date()) -> [MeetingGroup] {
        let calendar = Calendar.current
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: now)) ?? now
        var buckets: [(String, [MeetingItem])] = [("Today", []), ("Yesterday", []), ("Earlier This Week", []), ("Earlier", [])]
        for item in items {
            let index: Int
            if let date = item.date, calendar.isDateInToday(date) { index = 0 }
            else if let date = item.date, calendar.isDateInYesterday(date) { index = 1 }
            else if let date = item.date, date >= weekAgo { index = 2 }
            else { index = 3 }
            buckets[index].1.append(item)
        }
        return buckets.filter { !$0.1.isEmpty }.map { MeetingGroup(title: $0.0, items: $0.1) }
    }
}

private struct MeetingArchiveView: View {
    @EnvironmentObject var model: AppModel
    let allItems: [MeetingItem]
    let items: [MeetingItem]
    @Binding var query: String
    @Binding var filter: ArchiveFilter
    let isFiltering: Bool
    let open: (MeetingItem) -> Void
    let rename: (MeetingItem) -> Void
    let delete: (MeetingItem) -> Void
    @FocusState private var searchFocused: Bool

    private var summaryLine: String {
        let count = allItems.count
        let seconds = allItems.compactMap(\.durationSeconds).reduce(0, +)
        let hours = Double(seconds) / 3600
        let recorded = hours >= 1 ? "\(Int(hours.rounded())) \(Int(hours.rounded()) == 1 ? "hour" : "hours") recorded"
                                  : "\(max(0, seconds / 60)) min recorded"
        return "\(count) \(count == 1 ? "meeting" : "meetings"), \(recorded)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                Text("All Your Meetings")
                    .font(SekitiriType.pageTitle)
                    .accessibilityAddTraits(.isHeader)
                if !allItems.isEmpty {
                    Text(summaryLine)
                        .font(SekitiriType.sans(17))
                        .foregroundStyle(SekitiriColor.muted)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { searchField; filterPills }
                VStack(alignment: .leading, spacing: 12) { searchField; filterPills }
            }

            if items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(isFiltering ? "No matching meetings" : "Your meetings will live here")
                        .font(SekitiriType.subTitle)
                    Text(isFiltering
                         ? "Try a different title, person or phrase from the notes, or clear the filters."
                         : "Record a meeting to keep its transcript, notes, action items and your own notes together here.")
                        .font(SekitiriType.body)
                        .foregroundStyle(SekitiriColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 12)
            } else {
                ForEach(MeetingGroup.grouped(items)) { group in
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.title)
                                .font(SekitiriType.labelStrong)
                                .foregroundStyle(SekitiriColor.muted)
                                .accessibilityAddTraits(.isHeader)
                            Rectangle().fill(SekitiriColor.rule).frame(height: 1)
                        }
                        SKColumnGrid(items: group.items) { item in
                            MeetingColumn(item: item, showsTime: true, open: { open(item) },
                                          retry: item.status == .needsAttention ? { model.retryTranscription(for: item.workingDirectory) } : nil)
                                .contextMenu {
                                    Button("Open") { open(item) }
                                    Button("Rename…") { rename(item) }
                                    Button("Show in Finder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([item.url])
                                    }
                                    if let session = item.sourceSession {
                                        Divider()
                                        if item.status != .needsAttention, MeetingNotesService.hasAudio(in: session) {
                                            Button("Delete Audio, Keep Transcript", role: .destructive) {
                                                model.deleteAudio(session: session)
                                            }
                                        }
                                        Button("Move to Trash", role: .destructive) { delete(item) }
                                    }
                                }
                        }
                    }
                }
            }
        }
        .background {
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(SekitiriColor.muted)
                .accessibilityHidden(true)
            TextField("Search titles, people and notes", text: $query)
                .textFieldStyle(.plain)
                .font(SekitiriType.body)
                .focused($searchFocused)
                .accessibilityLabel("Search meetings")
            if query.isEmpty {
                SKKbd(keys: "⌘F")
            } else {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(SekitiriColor.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(minWidth: 280, maxWidth: .infinity)
        .frame(height: 44)
        .background(SekitiriColor.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(searchFocused ? SekitiriColor.terracotta : SekitiriColor.line, lineWidth: searchFocused ? 1.5 : 1))
    }

    private var filterPills: some View {
        SKSegmented(selection: $filter, options: ArchiveFilter.allCases) { $0.rawValue }
            .fixedSize()
    }
}

/// People who attended, from calendar attendees. Click one to filter.
private struct PeopleRail: View {
    let items: [MeetingItem]
    @Binding var selected: String?

    /// Calendar attendees without a display name arrive as email addresses;
    /// the part before "@" reads better on a chip.
    static func display(_ name: String) -> String {
        guard name.contains("@"), let local = name.split(separator: "@").first else { return name }
        return String(local)
    }

    private var people: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for item in items { for name in Set(item.participants) { counts[name, default: 0] += 1 } }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(16).map { ($0.key, $0.value) }
    }

    var body: some View {
        SKSectionHeader("People")
        if people.isEmpty {
            Text("People appear here when your meetings have attendees from your calendar.")
                .font(SekitiriType.meta)
                .foregroundStyle(SekitiriColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Filter by who was in the room")
                .font(SekitiriType.meta)
                .foregroundStyle(SekitiriColor.muted)
            SKFlowLayout(spacing: 8) {
                ForEach(people, id: \.name) { person in
                    let isOn = selected == person.name
                    Button { selected = isOn ? nil : person.name } label: {
                        Text("\(Self.display(person.name)) (\(person.count))")
                            .font(SekitiriType.label)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 230, alignment: .leading)
                            .fixedSize(horizontal: true, vertical: false)
                            .foregroundStyle(isOn ? SekitiriColor.onAccent : SekitiriColor.ink)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(isOn ? SekitiriColor.terracotta : SekitiriColor.blush, in: Capsule())
                    }
                    .buttonStyle(SekitiriHoverButtonStyle())
                    .help(person.name)
                    .accessibilityLabel("\(person.name), \(person.count) meetings")
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
            if selected != nil {
                Button("Show Everyone") { selected = nil }
                    .buttonStyle(.skLink)
                    .font(SekitiriType.labelStrong)
            }
        }
    }
}

/// One meeting in a ruled column: status, title, one-line summary and an
/// action. Used by the dashboard and the archive.
struct MeetingColumn: View {
    let item: MeetingItem
    var showsTime = false
    var showsButton = false
    let open: () -> Void
    var retry: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(statusLine)
                    .font(SekitiriType.sans(12, .semibold))
                    .foregroundStyle(statusColor)
                Spacer(minLength: 8)
                if showsTime, let slot = timeSlot {
                    Text(slot)
                        .font(SekitiriType.caption.monospacedDigit())
                        .foregroundStyle(SekitiriColor.muted)
                }
            }
            Button(action: open) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title)
                        .font(SekitiriType.serif(26, .medium))
                        .foregroundStyle(SekitiriColor.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(SummaryParser.inline(item.excerpt))
                        .font(SekitiriType.meta)
                        .foregroundStyle(SekitiriColor.muted)
                        .lineSpacing(3)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(SekitiriHoverButtonStyle())
            .accessibilityLabel("\(item.title), \(statusLine)")
            .accessibilityHint("Opens the meeting")
            if let retry {
                Button("Retry Transcript", action: retry)
                    .buttonStyle(.sk(.secondary, .small))
                    .padding(.top, 4)
            } else if showsButton {
                Button(item.status == .transcribing ? "View Progress" : "Open Notes", action: open)
                    .buttonStyle(.sk(.primary, .small))
                    .padding(.top, 4)
                    .accessibilityLabel("\(item.status == .transcribing ? "View progress for" : "Open notes for") \(item.title)")
            }
        }
    }

    private var timeSlot: String? {
        guard let date = item.date else { return nil }
        let day = Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        guard let seconds = item.durationSeconds, seconds > 0 else { return day }
        return "\(day) | \(SKDate.duration(TimeInterval(seconds)))"
    }

    private var statusLine: String {
        switch item.status {
        case .actionsPending: return "Action items open"
        case .notesReady: return "Summary ready"
        default: return item.status.title
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .transcribing: return SekitiriColor.terracotta
        case .notesReady: return SekitiriColor.sage
        case .actionsPending: return SekitiriColor.bronze
        case .needsAttention: return SekitiriColor.danger
        case .transcriptReady: return SekitiriColor.muted
        }
    }
}

// MARK: - Meeting detail

struct MeetingDetailView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.skShowsRail) private var showsRail
    let item: MeetingItem
    let onBack: () -> Void
    @StateObject private var playback = PlaybackManager()
    @State private var tab: DetailTab = .summary
    @State private var summaryRaw = ""
    @State private var transcriptRaw = ""
    @State private var transcript = TranscriptDocument.empty
    @State private var speakerNames = SpeakerNames()
    @State private var trackURLs: [URL] = []
    @State private var parsedSections: [SummarySection] = []
    @State private var summaryDocument: CanonicalSummaryDocument?
    @State private var selectedEvidence: SummaryEvidenceSource?
    @State private var isSummarizing = false
    @State private var summaryProgress: SummaryProgress?
    @State private var summaryTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var additionalNotes = ""
    @State private var notesSaveError: String?
    @State private var notesSaveStatus = ""
    @State private var transcriptIsProcessing = false
    @State private var transcriptFailed = false
    @State private var transcriptFailureReason: String?
    @State private var actionSaveError: String?
    @State private var showShareSheet = false
    @State private var transcriptQuery = ""
    @State private var pendingSeek: TimeInterval?
    @State private var renamingSpeaker: String?
    @State private var renameText = ""
    @State private var choseInitialTab = false
    @State private var editingTitle = false
    @State private var moments: [MarkedMoment] = []
    @State private var titleDraft = ""
    @State private var renameFailed = false
    @FocusState private var titleFocused: Bool
    @AppStorage("summaryTone") private var summaryTone = "Concise"
    @AppStorage("summaryPrompt.concise") private var concisePrompt = ""
    @AppStorage("summaryPrompt.detailed") private var detailedPrompt = ""
    @AppStorage("summaryPrompt.executive") private var executivePrompt = ""

    enum DetailTab: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case transcript = "Transcript"
        var id: String { rawValue }
    }

    private var activeSegmentID: Int? {
        guard playback.hasLoadedTrack, playback.isPlaying || playback.isPaused else { return nil }
        return transcript.segmentID(at: playback.currentTime)
    }

    var body: some View {
        SKRailLayout(padded: false) {
            ScrollViewReader { proxy in
                SKScroll {
                    VStack(alignment: .leading, spacing: 28) {
                        header
                        SKTabRow(selection: $tab, tabs: DetailTab.allCases) { $0.rawValue }
                        if tab == .summary { summaryTab } else { transcriptTab }
                        if tab == .summary || !showsRail { additionalNotesEditor }
                    }
                    .padding(SKLayout.pagePadding)
                    .frame(maxWidth: 1000, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: activeSegmentID) { _, id in
                    // Follow playback only while audio is playing and nothing is filtered.
                    guard tab == .transcript, playback.isPlaying, transcriptQuery.isEmpty, let id else { return }
                    withAnimation(SekitiriMotion.easeOut) { proxy.scrollTo(id, anchor: .center) }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !trackURLs.isEmpty { playerBar }
            }
        } rail: {
            notesRail
        }
        .background {
            Button("", action: onBack)
                .keyboardShortcut("[", modifiers: .command)
                .hidden()
        }
        .onAppear {
            load()
            startPendingSummaryIfNeeded()
        }
        .onChange(of: model.isTranscribing) { _, processing in
            if !processing, notesSaveError == nil { load() }
        }
        .onChange(of: model.archiveRevision) { _, _ in
            // Audio can be trashed or restored from here or the archive.
            trackURLs = item.loadRecordingTrackURLs()
        }
        .onChange(of: playback.duration) { _, duration in
            guard duration > 0, let target = pendingSeek else { return }
            pendingSeek = nil
            playback.seek(to: target)
        }
        .onDisappear {
            playback.stop()
            summaryTask?.cancel()
        }
        .sheet(isPresented: $showShareSheet) {
            ShareMeetingSheet(item: item, summaryRaw: summaryRaw, transcriptRaw: transcriptRaw)
        }
        .sheet(item: $selectedEvidence) { source in
            EvidenceSheet(
                source: source,
                speakerName: source.speaker.map { speakerNames.display($0) },
                canPlay: !trackURLs.isEmpty && source.timestampSeconds != nil,
                play: {
                    if let seconds = source.timestampSeconds { play(from: TimeInterval(seconds)) }
                    selectedEvidence = nil
                },
                done: { selectedEvidence = nil }
            )
        }
        .alert(
            "Rename speaker",
            isPresented: Binding(get: { renamingSpeaker != nil }, set: { if !$0 { renamingSpeaker = nil } })
        ) {
            TextField("Name", text: $renameText)
            Button("Rename") { commitRename() }
            Button("Cancel", role: .cancel) { renamingSpeaker = nil }
        } message: {
            Text("Shown instead of “\(renamingSpeaker.map(SpeakerNames.defaultName) ?? "")” in this meeting. Leave empty to use the original label. The transcript file isn’t changed.")
        }
    }

    // MARK: Header

    private var headingStatus: MeetingStatus {
        if transcriptIsProcessing { return .transcribing }
        if transcriptFailed { return .needsAttention }
        if summaryDocument != nil || !summaryRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return actionItems.contains(where: { !$0.checked }) ? .actionsPending : .notesReady
        }
        return transcriptRaw.isEmpty && transcript.isEmpty ? item.status : .transcriptReady
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                        Text("All meetings").font(SekitiriType.labelStrong)
                        SKKbd(keys: "⌘[")
                    }
                    .foregroundStyle(SekitiriColor.muted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Back to all meetings (⌘[)")
                Spacer()
                if hasShareableOutput {
                    Button { showShareSheet = true } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.skOutline)
                }
                if let session = item.sourceSession, !trackURLs.isEmpty {
                    Menu {
                        Button("Delete Audio, Keep Transcript", role: .destructive) {
                            playback.stop()
                            model.deleteAudio(session: session)
                        }
                        .disabled(transcriptFailed || transcriptIsProcessing)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More")
                }
            }
            titleRow
            if renameFailed {
                Text("Couldn’t save the new name. This meeting has no metadata file to update.")
                    .font(SekitiriType.caption)
                    .foregroundStyle(SekitiriColor.dangerText)
            }
            HStack(spacing: 12) {
                SekitiriStatusBadge(title: headingStatus.title, kind: headingStatus.kind)
                Text(dateLine)
                    .font(SekitiriType.sans(17))
                    .foregroundStyle(SekitiriColor.muted)
            }
            if !item.participants.isEmpty {
                Text("With \(item.participants.joined(separator: ", "))")
                    .font(SekitiriType.meta)
                    .foregroundStyle(SekitiriColor.muted)
                    .lineLimit(2)
            }
            if trackURLs.isEmpty {
                Label("No saved audio for this meeting.", systemImage: "speaker.slash")
                    .font(SekitiriType.caption)
                    .foregroundStyle(SekitiriColor.muted)
            }
        }
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 14) {
            if editingTitle {
                TextField("Meeting name", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(SekitiriType.pageTitle)
                    .focused($titleFocused)
                    .onSubmit { commitTitle() }
                    .onExitCommand { editingTitle = false }
                    .accessibilityLabel("Meeting name")
            } else {
                Text(item.title)
                    .font(SekitiriType.pageTitle)
                    .foregroundStyle(SekitiriColor.ink)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .onTapGesture(count: 2) { beginTitleEdit() }
            }
            Button { if editingTitle { commitTitle() } else { beginTitleEdit() } } label: {
                Image(systemName: editingTitle ? "checkmark" : "pencil")
                    .font(.system(size: 15))
                    .foregroundStyle(editingTitle ? SekitiriColor.terracotta : SekitiriColor.muted)
                    .frame(width: 36, height: 36)
                    .background(SekitiriColor.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(SekitiriColor.line))
            }
            .buttonStyle(.plain)
            .help(editingTitle ? "Save name (Return)" : "Rename this meeting")
            .accessibilityLabel(editingTitle ? "Save meeting name" : "Rename meeting")
            Spacer(minLength: 0)
        }
    }

    private func beginTitleEdit() {
        titleDraft = item.title == "Untitled meeting" ? "" : item.title
        renameFailed = false
        editingTitle = true
        titleFocused = true
    }

    private func commitTitle() {
        let name = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        editingTitle = false
        guard name != item.title else { return }
        renameFailed = !model.renameMeeting(item, to: name)
    }

    /// "Wednesday, 4 November · 9:36 AM · 41 min"
    private var dateLine: String {
        guard let date = item.date else { return item.duration }
        return [SKDate.dayLine(date), date.formatted(date: .omitted, time: .shortened), item.duration.isEmpty ? nil : item.duration]
            .compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Notes rail

    @ViewBuilder
    private var notesRail: some View {
        SKSectionHeader("Notes")
        VStack(alignment: .leading, spacing: 8) {
            Text("Model").font(SekitiriType.labelStrong)
            SummaryEnginePicker()
            Text("On this Mac. Nothing is sent anywhere.")
                .font(SekitiriType.caption)
                .foregroundStyle(SekitiriColor.muted)
        }
        VStack(alignment: .leading, spacing: 8) {
            Text("Summary Tone").font(SekitiriType.labelStrong)
            Picker("Summary tone", selection: $summaryTone) {
                ForEach(SummaryTonePrompts.tones, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .disabled(isSummarizing)
        }
        HStack(spacing: 8) { summaryButtons }
        summaryStatus
        Rectangle().fill(SekitiriColor.rule).frame(height: 1).padding(.vertical, 6)
        VStack(alignment: .leading, spacing: 8) {
            Text("Export").font(SekitiriType.labelStrong)
            if hasShareableOutput {
                Button("Share or Export…") { showShareSheet = true }
                    .buttonStyle(.sk(.outline, .small))
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                .buttonStyle(.sk(.outline, .small))
        }
        if tab == .transcript {
            Rectangle().fill(SekitiriColor.rule).frame(height: 1).padding(.vertical, 6)
            additionalNotesEditor
        }
    }

    private var hasShareableOutput: Bool {
        !summaryRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !transcriptRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Player

    private var playerBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Button {
                    playback.toggle(trackURLs: trackURLs)
                } label: {
                    Image(systemName: playback.isPreparing ? "hourglass" : playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .disabled(playback.isPreparing)
                .accessibilityLabel(playback.isPlaying ? "Pause recording" : "Play recording")

                Button { playback.stop() } label: {
                    Image(systemName: "stop.fill").frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .disabled(!playback.isPlaying && !playback.isPaused)
                .accessibilityLabel("Stop playback")

                Text(playback.timeLabel(playback.currentTime))
                    .font(SekitiriType.caption)
                    .monospacedDigit()
                    .foregroundStyle(SekitiriColor.muted)

                Slider(
                    value: Binding(get: { playback.currentTime }, set: { playback.seek(to: $0) }),
                    in: 0...max(playback.duration, 1)
                )
                .disabled(!playback.hasLoadedTrack)
                .accessibilityLabel("Playback position")

                Text(playback.hasLoadedTrack ? playback.timeLabel(playback.duration) : "--:--")
                    .font(SekitiriType.caption)
                    .monospacedDigit()
                    .foregroundStyle(SekitiriColor.muted)
            }
            if let message = playback.message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(SekitiriType.caption).foregroundStyle(SekitiriColor.warning)
            } else if let notice = playback.notice {
                Label(notice, systemImage: "info.circle")
                    .font(SekitiriType.caption).foregroundStyle(SekitiriColor.muted)
            }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 12)
        .background(SekitiriColor.sidebar)
        .overlay(alignment: .top) { Rectangle().fill(SekitiriColor.border).frame(height: 1) }
    }

    /// Seeks to `seconds` and plays, loading the recording first if needed.
    private func play(from seconds: TimeInterval) {
        guard !trackURLs.isEmpty else { return }
        if playback.hasLoadedTrack && (playback.isPlaying || playback.isPaused) {
            playback.seek(to: seconds)
            if playback.isPaused { playback.toggle(trackURLs: trackURLs) }
        } else {
            pendingSeek = seconds
            playback.start(trackURLs: trackURLs)
        }
    }

    // MARK: Summary

    private var summaryTab: some View {
        VStack(alignment: .leading, spacing: 28) {
            if !showsRail { summaryControls }
            if let document = summaryDocument, document.modelID != "legacy-markdown" {
                let isDraft = document.modelID.hasSuffix("+source-draft")
                Label(isDraft
                      ? "Source-based draft — check the linked passages and the recording for context."
                      : "Notes keep the transcript’s wording. Implicit commitments may need review; source links show where each point came from.",
                      systemImage: "text.quote")
                    .font(SekitiriType.meta)
                    .foregroundStyle(SekitiriColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            summaryBody
            actionItemsPanel
            if !moments.isEmpty { momentsPanel }
        }
    }

    private var summaryControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { summaryPickers; Spacer(minLength: 8); summaryButtons }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) { summaryPickers }
                    HStack(spacing: 12) { summaryButtons }
                }
            }
            summaryStatus
        }
        .sekitiriCard()
    }

    @ViewBuilder
    private var summaryPickers: some View {
        SummaryEnginePicker()
        Picker("Tone", selection: $summaryTone) {
            ForEach(SummaryTonePrompts.tones, id: \.self) { Text($0).tag($0) }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .disabled(isSummarizing)
    }

    @ViewBuilder
    private var summaryButtons: some View {
        if isSummarizing {
            Button("Cancel") { summaryTask?.cancel() }
                .buttonStyle(.skOutline)
        }
        Button(action: resummarize) {
            Label(summaryDocument == nil && summaryRaw.isEmpty ? "Create Notes" : "Summarise Again", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.skPrimary)
        .disabled(isSummarizing || model.summaryModelActionMessage != nil)
    }

    @ViewBuilder
    private var summaryStatus: some View {
        if isSummarizing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(summaryProgress?.label ?? "Preparing summary…")
                    .font(SekitiriType.meta)
                    .foregroundStyle(SekitiriColor.muted)
            }
        } else if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .font(SekitiriType.meta)
                .foregroundStyle(SekitiriColor.warning)
                .fixedSize(horizontal: false, vertical: true)
        } else if model.selectedModel.requiresDownload, !model.isTranscribing, !model.recording {
            SummaryModelDownloadRow()
        } else if let message = model.summaryModelActionMessage {
            Label(message, systemImage: "info.circle")
                .font(SekitiriType.meta)
                .foregroundStyle(SekitiriColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var summaryBody: some View {
        VStack(alignment: .leading, spacing: 22) {
            if parsedSections.isEmpty {
                Text(summaryDocument != nil
                     ? (actionItems.isEmpty
                        ? "No decisions, key points or open questions were found in this transcript. Review the transcript or summarise again."
                        : "The follow-up commitments from this meeting are listed under Action Items.")
                     : (summaryRaw.isEmpty ? "Notes appear here after you summarise this meeting." : summaryRaw))
                    .font(SekitiriType.reading)
                    .foregroundStyle(summaryRaw.isEmpty && summaryDocument == nil ? SekitiriColor.muted : SekitiriColor.ink)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(parsedSections.filter { !$0.title.localizedCaseInsensitiveContains("action item") && !$0.isEmptyPlaceholder }) {
                    SummarySectionView(
                        section: $0,
                        onEvidence: { selectedEvidence = $0 },
                        onPlay: trackURLs.isEmpty ? nil : { source in
                            if let seconds = source.timestampSeconds { play(from: TimeInterval(seconds)) }
                        }
                    )
                }
            }
        }
    }

    private var actionItemsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            SKSectionHeader("Action Items", font: SekitiriType.subTitle)
            if actionItems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .font(.title3)
                        .foregroundStyle(SekitiriColor.terracotta)
                        .accessibilityHidden(true)
                    Text("No action items found").font(SekitiriType.bodyStrong)
                    Text("Clear follow-up commitments from the meeting appear here.")
                        .font(SekitiriType.meta)
                        .foregroundStyle(SekitiriColor.muted)
                }
            } else {
                ForEach(actionItems) { action in
                    VStack(alignment: .leading, spacing: 4) {
                        SekitiriActionItemRow(text: String(SummaryParser.inline(action.text).characters), isChecked: action.checked) {
                            toggleAction(action)
                        }
                        .accessibilityLabel("\(action.checked ? "Completed" : "Not completed"): \(action.text)")
                        .accessibilityHint(action.checked ? "Marks the item incomplete" : "Marks the item complete")
                        .disabled(isSummarizing)
                        if let stored = summaryDocument?.actionItems.first(where: { $0.id == action.id }) {
                            HStack(spacing: 10) {
                                ForEach(stored.evidenceSourceIDs, id: \.self) { sourceID in
                                    if let source = summaryDocument?.sources.first(where: { $0.id == sourceID }) {
                                        EvidenceChip(source: source, onOpen: { selectedEvidence = source },
                                                     onPlay: trackURLs.isEmpty ? nil : { _ in
                                                         if let seconds = source.timestampSeconds { play(from: TimeInterval(seconds)) }
                                                     })
                                    }
                                }
                            }
                            .padding(.leading, 34)
                        }
                    }
                }
            }
            if let actionSaveError {
                Label(actionSaveError, systemImage: "exclamationmark.triangle.fill")
                    .font(SekitiriType.caption).foregroundStyle(SekitiriColor.warning)
            }
        }
    }

    private var momentsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            SKSectionHeader("Marked Moments", font: SekitiriType.subTitle)
            ForEach(moments) { moment in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    let clock = TranscriptDocument.clock(moment.seconds)
                    if trackURLs.isEmpty {
                        Text(clock)
                            .font(SekitiriType.label.monospacedDigit())
                            .foregroundStyle(SekitiriColor.terracotta)
                    } else {
                        Button(clock) { play(from: moment.seconds) }
                            .buttonStyle(.plain)
                            .font(SekitiriType.label.monospacedDigit())
                            .foregroundStyle(SekitiriColor.terracotta)
                            .help("Play from \(clock)")
                            .accessibilityLabel("Play from \(clock)")
                    }
                    Text(moment.label)
                        .font(SekitiriType.reading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Transcript

    @ViewBuilder
    private var transcriptTab: some View {
        if transcriptIsProcessing && transcript.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Transcription is in progress").font(SekitiriType.title3)
                Text("Your recording is safe. The timestamped transcript appears here as soon as on-device transcription finishes.")
                    .font(SekitiriType.meta).foregroundStyle(SekitiriColor.muted)
            }
        } else if transcriptFailed && transcript.isEmpty {
            SekitiriBanner(
                systemImage: "exclamationmark.triangle.fill",
                title: "Transcription needs attention",
                message: "The recording was preserved. Retry transcription or show the saved audio files."
            ) {
                Button("Retry Transcription") { model.retryTranscription(for: item.workingDirectory) }
                    .buttonStyle(.skPrimary)
                    .disabled(model.isTranscribing)
                Button("Show Recording") { model.revealRecording(at: item.workingDirectory) }
            }
        } else if transcript.isEmpty {
            Text("No transcript has been created for this recording yet.")
                .font(SekitiriType.meta).foregroundStyle(SekitiriColor.muted)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                if transcriptFailed {
                    SekitiriBanner(
                        systemImage: "exclamationmark.triangle.fill",
                        title: "Transcript incomplete",
                        message: transcriptFailureReason ?? "Some audio couldn’t be transcribed. Available speech is shown below."
                    ) {
                        Button("Retry Transcription") { model.retryTranscription(for: item.workingDirectory) }
                            .disabled(model.isTranscribing)
                        Button("Show Recording") { model.revealRecording(at: item.workingDirectory) }
                    }
                }
                HStack(spacing: 10) {
                    TranscriptSearchField(text: $transcriptQuery)
                        .frame(maxWidth: 320)
                    Spacer(minLength: 0)
                    CopyTranscriptButton(text: transcript.plainText(names: speakerNames))
                }
                if transcript.segments.contains(where: \.hasLowConfidence) {
                    Label("Words with a dotted underline were transcribed with low confidence.", systemImage: "info.circle")
                        .font(SekitiriType.caption)
                        .foregroundStyle(SekitiriColor.muted)
                }
                TranscriptListView(
                    segments: transcript.segments,
                    names: speakerNames,
                    query: transcriptQuery,
                    activeID: activeSegmentID,
                    onSeek: trackURLs.isEmpty ? nil : { play(from: $0) },
                    onRename: transcript.directory == nil ? nil : { raw in
                        renameText = speakerNames.names[raw] ?? ""
                        renamingSpeaker = raw
                    }
                )
            }
        }
    }

    private func commitRename() {
        guard let raw = renamingSpeaker, let directory = transcript.directory else { return }
        var updated = speakerNames
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.names[raw] = name.isEmpty ? nil : name
        do {
            try updated.save(to: directory)
            speakerNames = updated
            errorMessage = nil
        } catch {
            errorMessage = "Couldn’t save the speaker name: \(error.localizedDescription)"
        }
        renamingSpeaker = nil
    }

    // MARK: Notes

    private var additionalNotesEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            SKSectionHeader("Your Additional Notes", font: SekitiriType.subTitle)
            Text("Saved with this meeting and used the next time you summarise it.")
                .font(SekitiriType.meta).foregroundStyle(SekitiriColor.muted)
            TextEditor(text: Binding(get: { additionalNotes }, set: { value in
                additionalNotes = value
                saveAdditionalNotes()
            }))
            .font(SekitiriType.reading)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 120)
            .padding(10)
            .background(SekitiriColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(SekitiriColor.border))
            .accessibilityLabel("Your notes")
            if let notesSaveError {
                HStack(spacing: 8) {
                    Label(notesSaveError, systemImage: "exclamationmark.triangle.fill")
                        .font(SekitiriType.caption).foregroundStyle(SekitiriColor.warning)
                    Button("Retry Save", action: saveAdditionalNotes)
                }
            } else {
                Text(notesSaveStatus.isEmpty ? "Saved automatically." : notesSaveStatus)
                    .font(SekitiriType.caption).foregroundStyle(SekitiriColor.muted)
            }
        }
        .padding(.top, 8)
    }

    // MARK: Loading

    private func load() {
        let fm = FileManager.default
        trackURLs = item.loadRecordingTrackURLs()
        moments = MarkedMoment.load(from: item.workingDirectory)
        summaryRaw = (try? String(contentsOf: item.url.appendingPathComponent("summary.md"), encoding: .utf8)) ?? ""
        let source = item.workingDirectory
        let modern = fm.fileExists(atPath: source.appendingPathComponent("transcription-settings.json").path)
        let transcriptDirectory = modern ? source : item.url
        let diarized = transcriptDirectory.appendingPathComponent("transcript.diarized.md")
        let plain = transcriptDirectory.appendingPathComponent("transcript.md")
        let transcriptPath = !modern && fm.fileExists(atPath: diarized.path) ? diarized : plain
        transcriptRaw = (try? String(contentsOf: transcriptPath, encoding: .utf8)) ?? ""
        transcript = TranscriptDocument.load(session: item.sourceSession, vaultFolder: item.url) ?? .empty
        speakerNames = SpeakerNames.load(from: transcript.directory)
        let log = (try? String(contentsOf: source.appendingPathComponent("transcribe.log"), encoding: .utf8)) ?? ""
        transcriptFailureReason = modern && !transcriptRaw.isEmpty
            ? TranscriptIntegrity.incompletenessReason(at: source) : nil
        transcriptFailed = transcriptFailureReason != nil
            || (transcriptRaw.isEmpty && transcript.isEmpty && log.localizedCaseInsensitiveContains("transcription failed"))
        transcriptIsProcessing = transcriptRaw.isEmpty && transcript.isEmpty && !transcriptFailed
        additionalNotes = (try? String(contentsOf: source.appendingPathComponent("additional-notes.md"), encoding: .utf8)) ?? ""
        notesSaveError = nil
        notesSaveStatus = "Saved automatically."
        do {
            summaryDocument = try SummaryDocumentStore.loadOrMigrateIfPresent(from: item.url, transcript: transcriptRaw)
            if let document = summaryDocument {
                summaryRaw = SummaryDocumentStore.metadataPrefix(in: summaryRaw) + CanonicalSummaryBuilder.markdown(from: document)
                parsedSections = SummaryParser.parse(document)
            } else { parsedSections = SummaryParser.parse(summaryRaw) }
            actionSaveError = nil
        } catch {
            summaryDocument = nil
            parsedSections = SummaryParser.parse(summaryRaw)
            actionSaveError = "Couldn’t open structured notes: \(error.localizedDescription)"
        }
        if !choseInitialTab {
            choseInitialTab = true
            // Nothing to read on the summary tab yet; open on the transcript.
            if summaryDocument == nil, summaryRaw.isEmpty, !transcript.isEmpty { tab = .transcript }
        }
    }

    private func startPendingSummaryIfNeeded() {
        guard let pending = model.pendingSummarySession,
              pending.standardizedFileURL == item.workingDirectory.standardizedFileURL else { return }
        model.pendingSummarySession = nil
        tab = .summary
        resummarize()
    }

    private func saveAdditionalNotes() {
        do {
            // Keep the canonical meeting immediately up to date and mirror to
            // the source session, which is what the summariser reads.
            let directories = [item.url, item.sourceSession]
                .compactMap { $0 }
                .reduce(into: [URL]()) { result, directory in
                    if !result.contains(directory) { result.append(directory) }
                }
            for directory in directories {
                try additionalNotes.write(
                    to: directory.appendingPathComponent("additional-notes.md"),
                    atomically: true,
                    encoding: .utf8
                )
            }
            notesSaveError = nil
            notesSaveStatus = "Saved automatically."
        } catch {
            notesSaveStatus = ""
            notesSaveError = "Couldn’t save these notes. They are still in this editor — retry before leaving."
        }
    }

    private var actionItems: [PersistedActionItem] {
        if let document = summaryDocument {
            return document.actionItems
                .filter { !OpenActionItem.isPlaceholder($0.text) }
                .map { PersistedActionItem(id: $0.id, lineIndex: -1, text: $0.text, checked: $0.isCompleted) }
        }
        return PersistedActionItem.parse(summaryRaw).filter { !OpenActionItem.isPlaceholder($0.text) }
    }

    private func toggleAction(_ action: PersistedActionItem) {
        do {
            let document = try SummaryDocumentStore.toggleAction(id: action.id, in: item.url, transcript: transcriptRaw)
            summaryDocument = document
            summaryRaw = (try? String(contentsOf: item.url.appendingPathComponent("summary.md"), encoding: .utf8)) ?? CanonicalSummaryBuilder.markdown(from: document)
            parsedSections = SummaryParser.parse(document)
            actionSaveError = nil
        } catch {
            actionSaveError = "Couldn’t save action-item completion. \(error.localizedDescription)"
        }
    }

    private func resummarize() {
        guard !isSummarizing else { return }
        if let message = model.summaryModelActionMessage {
            errorMessage = message
            return
        }
        isSummarizing = true
        summaryProgress = .preparing
        errorMessage = nil
        let source = item.workingDirectory
        summaryTask = Task { @MainActor in
            do {
                try await model.summarizeMeeting(
                    session: source,
                    tone: summaryTone,
                    prompt: promptForSelectedTone
                ) { stage in
                    summaryProgress = stage
                }
                load()
            } catch is CancellationError {
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            isSummarizing = false
            summaryProgress = nil
            summaryTask = nil
        }
    }

    private var promptForSelectedTone: String {
        switch summaryTone {
        case "Detailed": return detailedPrompt.isEmpty ? SummaryTonePrompts.default(for: summaryTone) : detailedPrompt
        case "Executive Brief": return executivePrompt.isEmpty ? SummaryTonePrompts.default(for: summaryTone) : executivePrompt
        default: return concisePrompt.isEmpty ? SummaryTonePrompts.default(for: summaryTone) : concisePrompt
        }
    }
}

/// Inline download / progress / retry for the optional Qwen model, shown next
/// to the Summarise button.
struct SummaryModelDownloadRow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        switch model.localSummaryModelState {
        case .ready:
            EmptyView()
        case .notDownloaded:
            HStack(spacing: 10) {
                Label("Qwen 3.5 needs a one-time \(ModelItem.qwenDownloadSize) download. After that it runs offline.",
                      systemImage: "arrow.down.circle")
                    .font(SekitiriType.meta)
                    .foregroundStyle(SekitiriColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Download") { model.downloadLocalSummaryModel() }
            }
        case .downloading(let progress):
            HStack(spacing: 10) {
                ProgressView(value: progress)
                    .frame(maxWidth: 220)
                    .accessibilityLabel("Downloading Qwen 3.5")
                Text("Downloading · \(Int(progress * 100))%")
                    .font(SekitiriType.meta).monospacedDigit()
                    .foregroundStyle(SekitiriColor.muted)
                Button("Cancel") { model.cancelLocalSummaryModelDownload() }
            }
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading Qwen 3.5…").font(SekitiriType.meta).foregroundStyle(SekitiriColor.muted)
            }
        case .failed(let message):
            HStack(spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(SekitiriType.meta)
                    .foregroundStyle(SekitiriColor.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry") { model.downloadLocalSummaryModel() }
            }
        }
    }
}

private struct EvidenceSheet: View {
    let source: SummaryEvidenceSource
    let speakerName: String?
    let canPlay: Bool
    let play: () -> Void
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Transcript source")
                .font(SekitiriType.title2)
            Text([source.timestampText, speakerName].compactMap { $0 }.joined(separator: " · "))
                .font(SekitiriType.meta)
                .foregroundStyle(SekitiriColor.terracotta)
            Text(source.quote)
                .font(SekitiriType.reading)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("This quotation is preserved from the transcript. Play the recording for the surrounding context.")
                .font(SekitiriType.caption)
                .foregroundStyle(SekitiriColor.muted)
            HStack {
                if canPlay {
                    Button(action: play) {
                        Label("Play from \(source.timestampText ?? "here")", systemImage: "play.fill")
                    }
                    .buttonStyle(.skPrimary)
                }
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 420, idealWidth: 540)
        .background(SekitiriColor.canvas)
    }
}

private struct PersistedActionItem: Identifiable {
    let id: String
    let lineIndex: Int
    let text: String
    let checked: Bool

    static func parse(_ markdown: String) -> [PersistedActionItem] {
        CanonicalSummaryBuilder.build(markdown: markdown, transcript: "", modelID: "legacy", tone: "Unknown")
            .actionItems.map { PersistedActionItem(id: $0.id, lineIndex: -1, text: $0.text, checked: $0.isCompleted) }
    }
}

// MARK: - Sharing

private struct ShareMeetingSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: MeetingItem
    let summaryRaw: String
    let transcriptRaw: String
    @State private var includeSummary: Bool
    @State private var includeTranscript: Bool
    @State private var includeActionItems: Bool
    @State private var resultMessage = ""
    @State private var errorMessage = ""

    init(item: MeetingItem, summaryRaw: String, transcriptRaw: String) {
        self.item = item
        self.summaryRaw = summaryRaw
        self.transcriptRaw = transcriptRaw
        let actions = PersistedActionItem.parse(summaryRaw)
        _includeSummary = State(initialValue: !summaryRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        _includeTranscript = State(initialValue: false)
        _includeActionItems = State(initialValue: !actions.isEmpty)
    }

    private var actionItems: [PersistedActionItem] {
        PersistedActionItem.parse(summaryRaw)
    }

    private var hasSelection: Bool {
        (includeSummary && !summaryText.isEmpty)
            || (includeTranscript && !transcriptRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            || (includeActionItems && !actionItems.isEmpty)
    }

    private var summaryText: String {
        var lines = summaryRaw.components(separatedBy: .newlines)
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            lines.removeFirst()
            if let end = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
                lines.removeSubrange(0...end)
            }
        }
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        if lines.first?.trimmingCharacters(in: .whitespaces).hasPrefix("# ") == true { lines.removeFirst() }
        var filtered: [String] = []
        var skippingActionItems = false
        for line in lines {
            let heading = line.trimmingCharacters(in: .whitespaces)
            if heading.hasPrefix("## ") {
                skippingActionItems = heading.localizedCaseInsensitiveContains("action item")
            }
            if !skippingActionItems { filtered.append(line) }
        }
        return filtered.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Share meeting")
                    .font(SekitiriType.title2)
                Text(item.title)
                    .font(SekitiriType.bodyStrong)
                    .foregroundStyle(SekitiriColor.muted)
                Text("Choose exactly what to include. The meeting stays unchanged.")
                    .font(SekitiriType.meta)
                    .foregroundStyle(SekitiriColor.muted)
            }

            VStack(spacing: 0) {
                ShareOptionRow(title: "Summary", detail: "Decisions, context and open questions", isOn: $includeSummary)
                Divider()
                ShareOptionRow(title: "Transcript", detail: "Timestamped transcript with speaker labels", isOn: $includeTranscript)
                Divider()
                ShareOptionRow(title: "Action Items", detail: "Follow-up tasks and completion state", isOn: $includeActionItems)
            }
            .background(SekitiriColor.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(SekitiriColor.line))

            if !errorMessage.isEmpty {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(SekitiriType.meta)
                    .foregroundStyle(SekitiriColor.warning)
            }
            if !resultMessage.isEmpty {
                Label(resultMessage, systemImage: "checkmark.circle.fill")
                    .font(SekitiriType.meta)
                    .foregroundStyle(SekitiriColor.terracotta)
            }

            HStack(spacing: 10) {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Copy Selected") { copySelected() }
                    .disabled(!hasSelection)
                Button("Export Markdown…") { exportSelected() }
                    .buttonStyle(.skPrimary)
                    .disabled(!hasSelection)
            }
        }
        .padding(24)
        .frame(width: 540)
        .background(SekitiriColor.canvas)
    }

    private func copySelected() {
        guard hasSelection else { return }
        errorMessage = ""
        let content = composedMarkdown
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        resultMessage = "Copied \(selectionDescription) to the clipboard."
    }

    private func exportSelected() {
        guard hasSelection else { return }
        errorMessage = ""
        let panel = NSSavePanel()
        panel.title = "Export meeting notes"
        panel.nameFieldStringValue = "\(safeFilename(item.title)).md"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try composedMarkdown.write(to: destination, atomically: true, encoding: .utf8)
            resultMessage = "Exported \(selectionDescription) to \(destination.path)."
        } catch {
            errorMessage = "Couldn’t export the selected notes: \(error.localizedDescription)"
        }
    }

    private var selectionDescription: String {
        var values: [String] = []
        if includeSummary && !summaryText.isEmpty { values.append("Summary") }
        if includeTranscript && !transcriptRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { values.append("Transcript") }
        if includeActionItems && !actionItems.isEmpty { values.append("Action Items") }
        switch values.count {
        case 1: return values[0]
        case 2: return values.joined(separator: " and ")
        default: return values.dropLast().joined(separator: ", ") + ", and \(values.last ?? "")"
        }
    }

    private var composedMarkdown: String {
        var sections = ["# \(item.title)", "", item.dateString]
        if includeSummary && !summaryText.isEmpty { sections += ["", "## Summary", "", summaryText] }
        if includeActionItems && !actionItems.isEmpty {
            let lines = actionItems.map { "- [\($0.checked ? "x" : " ")] \($0.text)" }.joined(separator: "\n")
            sections += ["", "## Action Items", "", lines]
        }
        if includeTranscript && !transcriptRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections += ["", "## Transcript", "", transcriptRaw.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        return sections.joined(separator: "\n") + "\n"
    }

    private func safeFilename(_ title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/:")).joined(separator: "-")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "meeting-notes" : cleaned
    }
}

private struct ShareOptionRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(SekitiriType.bodyStrong)
                Text(detail).font(SekitiriType.meta).foregroundStyle(SekitiriColor.muted)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
