import AppKit
import SwiftUI
import UniformTypeIdentifiers

// ============================================================================
// Screen B — Meetings archive. Left: searchable list. Right: detail with
// structured summary sections + raw transcript + re-summarize button.
// ============================================================================

struct MeetingsScreenView: View {
    @EnvironmentObject var model: AppModel
    @Binding var requestedMeetingID: String?
    @State private var items: [MeetingItem] = []
    @State private var selected: MeetingItem?

    var body: some View {
        Group {
            if let selected {
                MeetingDetailView(item: selected)
                    .environmentObject(model)
                    .background(SekitiriColor.canvas)
            } else {
                GeometryReader { proxy in
                    let showSchedule = proxy.size.width >= 980
                    HStack(spacing: 0) {
                        MeetingArchiveView(items: items) { selected = $0 }
                        if showSchedule {
                            TodaySchedulePanel(start: { model.start() })
                                .environmentObject(model)
                                .frame(width: 300)
                        }
                    }
                }
            }
        }
        .onAppear {
            load()
            openRequestedMeetingIfNeeded()
        }
        .onChange(of: requestedMeetingID) { _, _ in openRequestedMeetingIfNeeded() }
    }

    private func load() {
        let vault = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Meetings")
        let index = (try? Data(contentsOf: vault.appendingPathComponent(".index.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let indexedMeetings = index?["meetings"] as? [[String: Any]] ?? []
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: vault, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey]
        )) ?? []

        var loaded = entries
            .filter { $0.lastPathComponent.hasPrefix("20") }
            .compactMap { url -> MeetingItem? in
                let folder = url.lastPathComponent
                let summaryURL = url.appendingPathComponent("summary.md")
                let transcriptURL = url.appendingPathComponent("transcript.diarized.md")
                let plainTranscriptURL = url.appendingPathComponent("transcript.md")

                let summary = (try? String(contentsOf: summaryURL, encoding: .utf8)) ?? ""
                let title = Self.extractTitle(from: summary) ?? folder
                let engine = Self.extractEngine(from: summary)
                let duration = Self.estimateDuration(transcriptURL: transcriptURL, fallback: plainTranscriptURL)
                let date = Self.parseDate(from: folder)
                let source = (try? Data(contentsOf: url.appendingPathComponent("source.json")))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let meta = (try? Data(contentsOf: url.appendingPathComponent("meta.json")))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let override = meta?["title_override"] as? String
                let participants = source?["attendees"] as? [String] ?? meta?["attendees"] as? [String] ?? []
                let sourceSession = (indexedMeetings.first(where: { ($0["id"] as? String) == folder })?["sourceSessionDir"] as? String)
                    .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }

                return MeetingItem(
                    id: folder,
                    url: url,
                    title: override?.isEmpty == false ? override! : title,
                    engine: engine,
                    duration: duration,
                    date: date,
                    participants: participants,
                    sourceSession: sourceSession
                )
            }
        let indexedSessionPaths = Set(loaded.compactMap(\.sourceSession).map(\.path))
        let recordings = (try? FileManager.default.contentsOfDirectory(at: AppModel.recordingsRoot(), includingPropertiesForKeys: nil)) ?? []
        loaded += recordings.compactMap { directory -> MeetingItem? in
            guard !indexedSessionPaths.contains(directory.path),
                  let data = try? Data(contentsOf: directory.appendingPathComponent("meta.json")),
                  let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let title = (meta["title_override"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return MeetingItem(
                id: directory.lastPathComponent,
                url: directory,
                title: title?.isEmpty == false ? title! : "Untitled meeting",
                engine: "",
                duration: "",
                date: Self.parseDate(from: directory.lastPathComponent),
                participants: meta["attendees"] as? [String] ?? [],
                sourceSession: directory
            )
        }
        items = loaded.sorted { $0.id > $1.id }
    }

    private func openRequestedMeetingIfNeeded() {
        guard let requestedMeetingID, let item = items.first(where: { $0.id == requestedMeetingID }) else { return }
        selected = item
        self.requestedMeetingID = nil
    }

    private static func extractTitle(from summary: String) -> String? {
        // First line after frontmatter: "# Title"
        let lines = summary.components(separatedBy: .newlines)
        var pastFrontmatter = false
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                pastFrontmatter.toggle(); continue
            }
            if pastFrontmatter || !line.hasPrefix("---") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("# ") {
                    return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                }
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func extractEngine(from summary: String) -> String {
        // Frontmatter: engine: afm
        for line in summary.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("engine:") {
                let val = String(t.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                return val.components(separatedBy: "|").first ?? val
            }
        }
        return ""
    }

    private static func estimateDuration(transcriptURL: URL, fallback: URL) -> String {
        let path = FileManager.default.fileExists(atPath: transcriptURL.path) ? transcriptURL : fallback
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return "" }
        // Count timestamp entries like [00:05] or [01:23:45]
        let regex = try? NSRegularExpression(pattern: "\\[(\\d{1,2}):(\\d{2})(?::(\\d{2}))?\\]")
        let matches = regex?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []
        guard let last = matches.last, let range = Range(last.range, in: text) else { return "" }
        let parts = String(text[range]).drop { $0 == "[" }.dropLast()
            .split(separator: ":")
        let mins = Int(parts.count == 3 ? parts[1] : parts[0]) ?? 0
        let secs = Int(parts.count == 3 ? parts[2] : parts[1]) ?? 0
        if parts.count == 3, let h = Int(parts[0]) {
            return "\(h)h \(mins)m"
        }
        return "\(mins + (secs > 0 ? 1 : 0)) min"
    }

    private static func parseDate(from folder: String) -> Date? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy.MM.dd-HHmm"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.date(from: folder)
    }
}

private struct MeetingArchiveView: View {
    let items: [MeetingItem]
    let open: (MeetingItem) -> Void

    var body: some View {
        GeometryReader { proxy in
            let columnCount = proxy.size.width >= 690 ? 3 : (proxy.size.width >= 440 ? 2 : 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Your meeting history")
                        .font(SekitiriType.display(23))
                        .foregroundStyle(SekitiriColor.terracotta)
                    Text("All Your Meetings")
                        .font(SekitiriType.display(44))
                        .padding(.top, 4)

                    if items.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Your meeting library is ready.")
                                .font(SekitiriType.display(25))
                            Text("Record a meeting to keep its transcript, summary, action items, and your additional notes together here.")
                                .font(SekitiriType.body(14))
                                .foregroundStyle(SekitiriColor.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 66)
                    } else {
                        Divider().overlay(SekitiriColor.line).padding(.top, 122)
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: columnCount),
                            spacing: 0
                        ) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                ArchiveMeetingCell(item: item) { open(item) }
                                    .padding(.horizontal, 36)
                                    .padding(.vertical, 18)
                                    .frame(minHeight: 190, alignment: .topLeading)
                                    .overlay(alignment: .leading) {
                                        if index % columnCount != 0 {
                                            Rectangle().fill(SekitiriColor.line).frame(width: 1)
                                        }
                                    }
                                    .overlay(alignment: .top) {
                                        if index >= columnCount {
                                            Rectangle().fill(SekitiriColor.line).frame(height: 1)
                                        }
                                    }
                            }
                        }
                    }
                }
                .padding(.horizontal, proxy.size.width < 500 ? 24 : 36)
                .padding(.top, 46)
                .padding(.bottom, 56)
            }
        }
        .background(SekitiriColor.canvas)
    }
}

private struct ArchiveMeetingCell: View {
    let item: MeetingItem
    let action: () -> Void

    private var presentation: MeetingArchivePresentation { MeetingArchivePresentation(item: item) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(presentation.status)
                .font(SekitiriType.body(10, weight: .medium))
                .foregroundStyle(SekitiriColor.terracotta)
            Text(item.title)
                .font(SekitiriType.display(25))
                .lineLimit(2)
            Text(presentation.description)
                .font(SekitiriType.body(12))
                .foregroundStyle(SekitiriColor.muted)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Open notes", action: action)
                .font(SekitiriType.body(11, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(SekitiriColor.terracotta, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct MeetingArchivePresentation {
    let status: String
    let description: String

    init(item: MeetingItem) {
        let legacySummary = (try? String(contentsOf: item.url.appendingPathComponent("summary.md"), encoding: .utf8)) ?? ""
        let document = try? SummaryDocumentStore.load(from: item.url)
        let summary = document.map { CanonicalSummaryBuilder.markdown(from: $0) } ?? legacySummary
        let fileManager = FileManager.default
        let hasSummary = !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasTranscript = fileManager.fileExists(atPath: item.url.appendingPathComponent("transcript.diarized.md").path)
            || fileManager.fileExists(atPath: item.url.appendingPathComponent("transcript.md").path)
            || fileManager.fileExists(atPath: (item.sourceSession ?? item.url).appendingPathComponent("transcript.diarized.md").path)
            || fileManager.fileExists(atPath: (item.sourceSession ?? item.url).appendingPathComponent("transcript.md").path)

        if hasSummary {
            status = Self.hasUncheckedActions(in: summary) ? "Action Items Pending" : "Summary ready"
            description = Self.oneLineSummary(from: summary)
        } else if hasTranscript {
            status = "Summary pending"
            description = Self.metadata(for: item, fallback: "Your transcript is ready. A summary can be generated when you’re ready.")
        } else {
            status = "Transcription ongoing"
            description = Self.metadata(for: item, fallback: "Your recording is safely saved and is being transcribed.")
        }
    }

    private static func metadata(for item: MeetingItem, fallback: String) -> String {
        let parts = [item.dateString, item.duration.isEmpty ? nil : item.duration].compactMap { $0 }
        return parts.isEmpty ? fallback : parts.joined(separator: " · ")
    }

    private static func oneLineSummary(from markdown: String) -> String {
        let headings = ["## At a glance", "## Key Takeaway", "## Summary"]
        for heading in headings {
            guard let range = markdown.range(of: heading, options: .caseInsensitive) else { continue }
            let paragraph = String(markdown[range.upperBound...])
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("-") }
            if let paragraph, !paragraph.isEmpty { return truncate(paragraph) }
        }
        return "Your meeting summary is ready to review."
    }

    private static func hasUncheckedActions(in markdown: String) -> Bool {
        SummaryParser.hasPendingActions(markdown)
    }

    private static func truncate(_ text: String) -> String {
        text.count > 155 ? String(text.prefix(152)) + "…" : text
    }
}

// MARK: - Meeting card

struct MeetingCard: View {
    let item: MeetingItem
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.dateString)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(isSelected ? .white.opacity(0.7) : .secondary)
                Spacer(minLength: 4)
                if !item.engine.isEmpty {
                    Text(item.engineShort)
                        .font(.system(.caption2, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.8))
                        .clipShape(Capsule())
                }
            }
            Text(item.title)
                .font(.system(.body, weight: .semibold))
                .foregroundColor(isSelected ? .white : .primary)
                .lineLimit(2)
            if !item.duration.isEmpty {
                Text(item.duration)
                    .font(.system(.caption2))
                    .foregroundColor(isSelected ? .white.opacity(0.6) : .secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor : Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Meeting detail

struct MeetingDetailView: View {
    @EnvironmentObject var model: AppModel
    let item: MeetingItem
    @StateObject private var playback = PlaybackManager()
    @State private var tab: DetailTab = .summary
    @State private var summaryRaw = ""
    @State private var transcriptRaw = ""
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
    @AppStorage("summaryTone") private var summaryTone = "Concise"
    @AppStorage("summaryPrompt.concise") private var concisePrompt = ""
    @AppStorage("summaryPrompt.detailed") private var detailedPrompt = ""
    @AppStorage("summaryPrompt.executive") private var executivePrompt = ""

    enum DetailTab: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case transcript = "Transcript"
        var id: String { rawValue }
    }

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 860
            if compact {
                VStack(spacing: 0) {
                    summaryControls(compact: true)
                    detailDocument(compact: true)
                }
            } else {
                HStack(spacing: 0) {
                    detailDocument(compact: false)
                    summaryControls(compact: false)
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: model.isTranscribing) { _, processing in
            if !processing, notesSaveError == nil { load() }
        }
        .onDisappear {
            playback.stop()
            summaryTask?.cancel()
        }
        .sheet(isPresented: $showShareSheet) {
            ShareMeetingSheet(item: item, summaryRaw: summaryRaw, transcriptRaw: transcriptRaw)
        }
        .sheet(item: $selectedEvidence) { source in
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Transcript source").font(SekitiriType.display(23))
                    Spacer()
                    Button("Done") { selectedEvidence = nil }
                }
                Text([source.timestampText, source.speaker].compactMap { $0 }.joined(separator: " · "))
                    .font(SekitiriType.body(12)).foregroundStyle(SekitiriColor.terracotta)
                Text(source.quote).font(.system(size: 16, design: .serif)).textSelection(.enabled)
                Text("This quotation is preserved from the transcript. Review the recording for the surrounding context.")
                    .font(SekitiriType.body(11)).foregroundStyle(SekitiriColor.muted)
            }.padding(28).frame(minWidth: 440, idealWidth: 560)
        }
    }

    private func detailDocument(compact: Bool) -> some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Group {
                        if compact {
                            VStack(alignment: .leading, spacing: 14) {
                                meetingHeading
                                shareButton
                            }
                        } else {
                            HStack(alignment: .top) {
                                meetingHeading
                                Spacer()
                                shareButton
                            }
                        }
                    }
                    .padding(.top, compact ? 24 : 42)

                    HStack(spacing: 22) {
                        ForEach(DetailTab.allCases) { value in
                            Button(value.rawValue) { tab = value }
                                .font(SekitiriType.body(14, weight: tab == value ? .semibold : .regular))
                                .foregroundStyle(tab == value ? SekitiriColor.terracotta : SekitiriColor.muted)
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 38)
                    Divider().overlay(SekitiriColor.line).padding(.top, 10)

                    if tab == .summary {
                        if compact {
                            VStack(alignment: .leading, spacing: 28) {
                                summaryBody
                                actionItemsPanel
                            }
                        } else {
                            HStack(alignment: .top, spacing: 32) {
                                summaryBody.frame(maxWidth: .infinity, alignment: .leading)
                                Divider().overlay(SekitiriColor.line).frame(height: 430)
                                actionItemsPanel.frame(width: 310)
                            }
                        }
                    } else {
                        transcriptContent
                    }
                    additionalNotesEditor
                    if let errorMessage { Text(errorMessage).font(SekitiriType.body(11)).foregroundStyle(.red).padding(.top, 16) }
                }
                .padding(.horizontal, compact ? 24 : 42).padding(.bottom, 40)
            }
            .frame(maxWidth: .infinity).background(SekitiriColor.canvas)
    }

    private var meetingHeading: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Recording complete")
                .font(SekitiriType.display(24))
                .foregroundStyle(SekitiriColor.terracotta)
            Text(item.title)
                .font(SekitiriType.display(43))
                .lineLimit(2)
            Text(item.dateString + (item.duration.isEmpty ? "" : " · \(item.duration) elapsed"))
                .font(SekitiriType.body(13))
                .foregroundStyle(SekitiriColor.muted)
            playbackControls
        }
    }

    private var playbackControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    playback.toggle(trackURLs: item.recordingTrackURLs)
                } label: {
                    Image(systemName: playback.isPreparing ? "hourglass" : playback.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(SekitiriColor.terracotta)
                .disabled(playback.isPreparing)
                .accessibilityLabel(playback.isPlaying ? "Pause recording" : "Play recording")

                Button {
                    playback.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(SekitiriColor.muted)
                .disabled(!playback.isPlaying && !playback.isPaused)
                .accessibilityLabel("Stop playback")

                Slider(
                    value: Binding(
                        get: { playback.currentTime },
                        set: { playback.seek(to: $0) }
                    ),
                    in: 0...max(playback.duration, 1)
                )
                .tint(SekitiriColor.terracotta)
                .disabled(!playback.hasLoadedTrack)

                Text("\(playback.timeLabel(playback.currentTime)) / \(playback.timeLabel(playback.duration))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(SekitiriColor.muted)
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(SekitiriColor.line))

            if let message = playback.message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(SekitiriType.body(10))
                    .foregroundStyle(.red)
            } else if let notice = playback.notice {
                Label(notice, systemImage: "info.circle")
                    .font(SekitiriType.body(10))
                    .foregroundStyle(SekitiriColor.muted)
            } else if playback.isPreparing {
                Text("Opening saved recording…")
                    .font(SekitiriType.body(10))
                    .foregroundStyle(SekitiriColor.muted)
            } else if item.recordingTrackURLs.isEmpty {
                Text("No saved audio track is available for this meeting.")
                    .font(SekitiriType.body(10))
                    .foregroundStyle(SekitiriColor.muted)
            } else {
                Text("Play saved audio")
                    .font(SekitiriType.body(10))
                    .foregroundStyle(SekitiriColor.muted)
            }
        }
        .padding(.top, 5)
    }

    private var shareButton: some View {
        Group {
            if hasShareableOutput {
                Button { showShareSheet = true } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .font(SekitiriType.body(12, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(SekitiriColor.ink)
                .padding(.horizontal, 13).padding(.vertical, 9)
                .background(.white.opacity(0.5), in: Capsule())
                .overlay(Capsule().stroke(SekitiriColor.line))
            }
        }
    }

    private var hasShareableOutput: Bool {
        !summaryRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !transcriptRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var summaryBody: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let document = summaryDocument, document.modelID != "legacy-markdown" {
                let isDraft = document.modelID.hasSuffix("+source-draft")
                VStack(alignment: .leading, spacing: 5) {
                    Text(isDraft ? "Source-based draft" : "Source-based notes")
                        .font(SekitiriType.body(11, weight: .medium))
                        .foregroundStyle(SekitiriColor.terracotta)
                    Text(isDraft
                         ? "These source-based notes need review. They preserve explicit transcript statements; check linked passages and the recording for context."
                         : "Extractive notes keep the transcript’s wording. Tasks include explicit commitments; implicit commitments may need review. Check source links for context.")
                        .font(SekitiriType.body(11))
                        .foregroundStyle(SekitiriColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if parsedSections.isEmpty {
                Text(summaryDocument != nil
                     ? (actionItems.isEmpty
                        ? "No decisions, key points or open questions were identified in this transcript. You can review the transcript or generate the summary again."
                        : "The follow-up commitments from this meeting are listed under Action Items.")
                     : (summaryRaw.isEmpty ? "Your summary will appear here once it is ready." : summaryRaw))
                    .font(.system(size: 16, design: .serif)).foregroundStyle(SekitiriColor.ink)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(parsedSections.filter { !$0.title.localizedCaseInsensitiveContains("action item") }) {
                    SummarySectionView(section: $0, onEvidence: { selectedEvidence = $0 })
                }
            }
        }
        .padding(.top, 26)
    }

    private var actionItemsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Action Items").font(SekitiriType.display(25))
            if actionItems.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "checkmark.circle").font(.system(size: 22)).foregroundStyle(SekitiriColor.terracotta)
                    Text("No action items detected").font(SekitiriType.body(13, weight: .medium))
                    Text("When the meeting contains clear follow-up commitments, they’ll appear here.")
                        .font(SekitiriType.body(11)).foregroundStyle(SekitiriColor.muted)
                }
                .padding(.top, 4)
            } else {
                ForEach(actionItems) { item in
                    SekitiriActionItemRow(text: String(SummaryParser.inline(item.text).characters), isChecked: item.checked) {
                        toggleAction(item)
                    }
                    .accessibilityLabel("\(item.checked ? "Mark incomplete" : "Mark complete"): \(item.text)")
                    .disabled(isSummarizing)
                    if let action = summaryDocument?.actionItems.first(where: { $0.id == item.id }) {
                        HStack(spacing: 10) {
                            ForEach(action.evidenceSourceIDs, id: \.self) { sourceID in
                                if let source = summaryDocument?.sources.first(where: { $0.id == sourceID }) {
                                    Button { selectedEvidence = source } label: {
                                        Label(source.timestampText ?? "Transcript", systemImage: "text.quote")
                                    }
                                    .buttonStyle(.plain).font(SekitiriType.body(10)).foregroundStyle(SekitiriColor.terracotta)
                                }
                            }
                        }
                    }
                }
            }
            if let actionSaveError {
                Label(actionSaveError, systemImage: "exclamationmark.triangle.fill")
                    .font(SekitiriType.body(10)).foregroundStyle(.red)
            }
        }
        .padding(.top, 26)
    }

    private var additionalNotesEditor: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Your Additional Notes").font(SekitiriType.display(23))
                .padding(.top, 34)
            Divider().overlay(SekitiriColor.line)
            Text("Your own context is saved with this meeting and used the next time you summarise it.")
                .font(SekitiriType.body(11)).foregroundStyle(SekitiriColor.muted)
            TextEditor(text: Binding(get: { additionalNotes }, set: { value in
                additionalNotes = value
                saveAdditionalNotes()
            }))
                .font(.system(size: 14, design: .serif))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 130)
                .padding(10)
                .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(SekitiriColor.line))
            if let notesSaveError {
                HStack(spacing: 8) {
                    Label(notesSaveError, systemImage: "exclamationmark.triangle.fill")
                        .font(SekitiriType.body(10)).foregroundStyle(.red)
                    Button("Retry save", action: saveAdditionalNotes)
                        .font(SekitiriType.body(10, weight: .medium)).buttonStyle(.plain)
                        .foregroundStyle(SekitiriColor.terracotta)
                }
            } else {
                Text(notesSaveStatus.isEmpty ? "Saved automatically." : notesSaveStatus)
                    .font(SekitiriType.body(10)).foregroundStyle(SekitiriColor.muted)
            }
        }
    }

    @ViewBuilder
    private var transcriptContent: some View {
        if transcriptIsProcessing && transcriptRaw.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Transcription is processing").font(SekitiriType.display(23))
                Text("Your recording is safe. Timestamped transcript entries will appear here as soon as on-device transcription finishes.")
                    .font(SekitiriType.body(13)).foregroundStyle(SekitiriColor.muted)
            }
            .padding(.top, 28)
        } else if transcriptFailed && transcriptRaw.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Label("Transcription needs attention", systemImage: "exclamationmark.triangle.fill")
                    .font(SekitiriType.display(22)).foregroundStyle(.red)
                Text("The recording was preserved. Retry transcription or reveal the saved audio files.")
                    .font(SekitiriType.body(13)).foregroundStyle(SekitiriColor.muted)
                HStack(spacing: 10) {
                    Button("Retry transcription") { model.retryTranscription(for: item.sourceSession ?? item.url) }
                        .buttonStyle(.borderedProminent)
                    Button("Show recording") { model.revealRecording(at: item.sourceSession ?? item.url) }
                        .buttonStyle(.bordered)
                }
            }
            .padding(.top, 28)
        } else if transcriptRaw.isEmpty {
            Text("No transcript has been created for this recording yet.")
                .font(SekitiriType.body(14)).foregroundStyle(SekitiriColor.muted).padding(.top, 26)
        } else {
            LazyVStack(alignment: .leading, spacing: 9) {
                if transcriptFailed {
                    Label("Transcript incomplete", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(transcriptFailureReason ?? "Some audio could not be transcribed. Available speech is shown below.")
                        .font(SekitiriType.body(13)).foregroundStyle(SekitiriColor.muted)
                    HStack {
                        Button("Retry transcription") { model.retryTranscription(for: item.sourceSession ?? item.url) }
                            .disabled(model.isTranscribing)
                        Button("Show recording") { model.revealRecording(at: item.sourceSession ?? item.url) }
                    }
                }
                ForEach(ArchivedTranscriptEntry.parse(transcriptRaw)) { entry in
                    HStack(alignment: .top, spacing: 12) {
                        Text(entry.timestamp)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(SekitiriColor.terracotta)
                            .frame(width: 58, alignment: .leading)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.speaker).font(SekitiriType.body(11, weight: .medium)).foregroundStyle(SekitiriColor.muted)
                            Text(entry.text).font(.system(size: 14, design: .serif)).foregroundStyle(SekitiriColor.ink)
                        }
                    }
                    .padding(.vertical, 8)
                    Divider().overlay(SekitiriColor.line)
                }
            }
            .padding(.top, 20)
        }
    }

    private func summaryControls(compact: Bool) -> some View {
            VStack(alignment: .leading, spacing: 18) {
                Text("Model").font(SekitiriType.display(20))
                ModelPill(selected: $model.selectedModel)
                    .disabled(model.isSummarizing || model.localSummaryModelState.isBusy)
                Button(action: resummarize) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text(isSummarizing ? "Summarising…" : "Resummarise")
                    }
                    .font(SekitiriType.body(13, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .disabled(isSummarizing || model.summaryModelActionMessage != nil)
                .foregroundStyle(.white)
                .background(SekitiriColor.terracotta, in: Capsule())
                if isSummarizing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(summaryProgress?.label ?? "Preparing summary…")
                            .font(SekitiriType.body(11))
                            .foregroundStyle(SekitiriColor.muted)
                    }
                    Button("Cancel summary") { summaryTask?.cancel() }
                        .buttonStyle(.plain)
                        .font(SekitiriType.body(11, weight: .medium))
                        .foregroundStyle(SekitiriColor.terracotta)
                } else if let message = model.summaryModelActionMessage {
                    Text(message)
                        .font(SekitiriType.body(11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider().overlay(SekitiriColor.line)
                Text("Summary Tone").font(SekitiriType.display(20))
                HStack(spacing: 0) {
                    ForEach(SummaryTonePrompts.tones, id: \.self) { tone in
                        Button(tone) { summaryTone = tone }
                            .font(SekitiriType.body(11, weight: summaryTone == tone ? .medium : .regular))
                            .foregroundStyle(summaryTone == tone ? .white : SekitiriColor.ink)
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(summaryTone == tone ? SekitiriColor.terracotta : SekitiriColor.canvas)
                    }
                }
                .clipShape(Capsule())
                .overlay(Capsule().stroke(SekitiriColor.line))
                if !compact { Spacer() }
            }
            .padding(26)
            .frame(maxWidth: compact ? .infinity : nil, alignment: .leading)
            .frame(width: compact ? nil : 300, alignment: .leading)
            .background(SekitiriColor.sidebar)
    }

    private func load() {
        let fm = FileManager.default
        summaryRaw = (try? String(contentsOf: item.url.appendingPathComponent("summary.md"),
                                   encoding: .utf8)) ?? ""
        let source = item.sourceSession ?? item.url
        let modern = fm.fileExists(atPath: source.appendingPathComponent("transcription-settings.json").path)
        let transcriptDirectory = modern ? source : item.url
        let diarized = transcriptDirectory.appendingPathComponent("transcript.diarized.md")
        let plain = transcriptDirectory.appendingPathComponent("transcript.md")
        let transcriptPath = !modern && fm.fileExists(atPath: diarized.path) ? diarized : plain
        transcriptRaw = (try? String(contentsOf: transcriptPath,
                                      encoding: .utf8)) ?? ""
        let logURL = (item.sourceSession ?? item.url).appendingPathComponent("transcribe.log")
        let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        transcriptFailureReason = modern && !transcriptRaw.isEmpty
            ? TranscriptIntegrity.incompletenessReason(at: source) : nil
        transcriptFailed = transcriptFailureReason != nil
            || (transcriptRaw.isEmpty && log.localizedCaseInsensitiveContains("transcription failed"))
        transcriptIsProcessing = transcriptRaw.isEmpty && !transcriptFailed
        let notesURL = (item.sourceSession ?? item.url).appendingPathComponent("additional-notes.md")
        additionalNotes = (try? String(contentsOf: notesURL, encoding: .utf8)) ?? ""
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
    }

    private func saveAdditionalNotes() {
        do {
            // Keep the canonical meeting immediately up to date and mirror to
            // the source session, which is what the CLI reads on re-summary.
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
            notesSaveError = "Couldn’t save these notes. They are still in this editor—please retry before leaving."
        }
    }

    private var actionItems: [PersistedActionItem] {
        if let document = summaryDocument {
            return document.actionItems.map { PersistedActionItem(id: $0.id, lineIndex: -1, text: $0.text, checked: $0.isCompleted) }
        }
        return PersistedActionItem.parse(summaryRaw)
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
        let source = item.sourceSession ?? item.url
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

// MARK: - Meeting item model

struct MeetingItem: Identifiable {
    let id: String
    let url: URL
    let title: String
    let engine: String
    let duration: String
    let date: Date?
    let participants: [String]
    let sourceSession: URL?

    /// Recordings are stored in the source session; older imported meetings
    /// may also have their tracks directly beside the canonical note files.
    var recordingTrackURLs: [URL] {
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
        case "source-notes": return "Source notes · lightweight"
        case "afm": return "Apple Foundation Model"
        case "qwen3.5-2b": return "Qwen3.5 2B · 4-bit"
        case "qwen3.5-0.8b": return "Qwen3.5 0.8B · 4-bit"
        case "qwen3-4b": return "Qwen3 4B · 4-bit"
        case "gemma3n-e2b": return "Gemma 3n E2B · 4-bit"
        default: return engine.isEmpty ? "Local" : engine
        }
    }

    var dateString: String {
        guard let date = date else { return id }
        let formatter = DateFormatter()
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            formatter.dateFormat = "'Today at' h:mm a"
        } else if cal.isDateInYesterday(date) {
            formatter.dateFormat = "'Yesterday' h:mm a"
        } else {
            formatter.dateFormat = "MMM d, h:mm a"
        }
        return formatter.string(from: date)
    }
}

private struct ArchivedTranscriptEntry: Identifiable {
    let id = UUID()
    let timestamp: String
    let speaker: String
    let text: String

    static func parse(_ raw: String) -> [ArchivedTranscriptEntry] {
        let pattern = #"\*\*\[([^\]]+)\]\s*([^:]+):\*\*\s*(.+)"#
        let regex = try? NSRegularExpression(pattern: pattern)
        return raw.split(separator: "\n").compactMap { line in
            let value = String(line)
            let range = NSRange(value.startIndex..., in: value)
            guard let match = regex?.firstMatch(in: value, range: range), match.numberOfRanges == 4,
                  let time = Range(match.range(at: 1), in: value),
                  let speaker = Range(match.range(at: 2), in: value),
                  let text = Range(match.range(at: 3), in: value) else { return nil }
            return ArchivedTranscriptEntry(timestamp: String(value[time]), speaker: String(value[speaker]), text: String(value[text]))
        }
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
                    .font(SekitiriType.display(28))
                Text(item.title)
                    .font(SekitiriType.body(14, weight: .medium))
                    .foregroundStyle(SekitiriColor.muted)
                Text("Choose exactly what to include. The meeting stays unchanged.")
                    .font(SekitiriType.body(12))
                    .foregroundStyle(SekitiriColor.muted)
            }

            VStack(spacing: 0) {
                ShareOptionRow(title: "Summary", detail: "Decisions, context, and open questions", isOn: $includeSummary)
                ShareOptionRow(title: "Transcript", detail: "Timestamped transcript with speaker labels", isOn: $includeTranscript)
                ShareOptionRow(title: "Action Items", detail: "Follow-up tasks and completion state", isOn: $includeActionItems)
            }
            .background(SekitiriColor.canvas, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(SekitiriColor.line))

            if !errorMessage.isEmpty {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(SekitiriType.body(11))
                    .foregroundStyle(.red)
            }
            if !resultMessage.isEmpty {
                Label(resultMessage, systemImage: "checkmark.circle.fill")
                    .font(SekitiriType.body(11))
                    .foregroundStyle(SekitiriColor.terracotta)
            }

            HStack(spacing: 10) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Copy selected") { copySelected() }
                    .buttonStyle(.borderedProminent)
                    .tint(SekitiriColor.terracotta)
                    .disabled(!hasSelection)
                Button("Export Markdown…") { exportSelected() }
                    .buttonStyle(.borderedProminent)
                    .tint(SekitiriColor.terracotta)
                    .disabled(!hasSelection)
            }
        }
        .padding(28)
        .frame(width: 560)
        .background(SekitiriColor.sidebar)
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
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(SekitiriType.body(13, weight: .medium))
                Text(detail).font(SekitiriType.body(11)).foregroundStyle(SekitiriColor.muted)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
