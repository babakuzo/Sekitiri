import SwiftUI

/// Selectable, searchable transcript rows shared by the live recorder and the
/// meeting page. Timestamps seek the recording when `onSeek` is provided.
struct TranscriptListView: View {
    let segments: [TranscriptDocument.Segment]
    var names = SpeakerNames()
    var query = ""
    /// Row that matches the playback position (or the newest live line).
    var activeID: Int? = nil
    var onSeek: ((TimeInterval) -> Void)? = nil
    /// Called with the raw speaker label to rename.
    var onRename: ((String) -> Void)? = nil

    var body: some View {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = trimmedQuery.isEmpty ? segments : segments.filter { segment in
            segment.text.localizedCaseInsensitiveContains(trimmedQuery)
                || (segment.speaker.map { names.display($0).localizedCaseInsensitiveContains(trimmedQuery) } ?? false)
        }
        LazyVStack(alignment: .leading, spacing: 2) {
            if !trimmedQuery.isEmpty {
                Text(visible.isEmpty ? "No matches" : "\(visible.count) matching \(visible.count == 1 ? "passage" : "passages")")
                    .font(.caption)
                    .foregroundStyle(SekitiriColor.muted)
                    .padding(.bottom, 6)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            ForEach(visible) { segment in
                TranscriptRow(
                    segment: segment,
                    speakerName: segment.speaker.map { names.display($0) },
                    isActive: segment.id == activeID,
                    query: trimmedQuery,
                    onSeek: onSeek,
                    onRename: onRename
                )
                .id(segment.id)
            }
        }
    }
}

private struct TranscriptRow: View {
    let segment: TranscriptDocument.Segment
    let speakerName: String?
    let isActive: Bool
    let query: String
    let onSeek: ((TimeInterval) -> Void)?
    let onRename: ((String) -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            timestamp
                .frame(width: 58, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                if let speakerName, let raw = segment.speaker {
                    Text(speakerName)
                        .font(SekitiriType.labelStrong)
                        .foregroundStyle(TranscriptRow.speakerColor(raw: raw, name: speakerName))
                        .contextMenu {
                            if let onRename {
                                Button("Rename “\(speakerName)”…") { onRename(raw) }
                            }
                        }
                        .help(onRename == nil ? "" : "Control-click to rename this speaker")
                }
                textView
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 8)
        .background(
            isActive ? SekitiriColor.tint : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    @ViewBuilder
    private var textView: some View {
        let text = Text(TranscriptRow.attributed(segment, query: query))
            .font(SekitiriType.serif(18))
            .lineSpacing(5)
            .foregroundStyle(SekitiriColor.ink)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        if segment.hasLowConfidence {
            text.help("Low confidence: dotted words may be transcribed incorrectly")
        } else {
            text
        }
    }

    @ViewBuilder
    private var timestamp: some View {
        if let start = segment.start {
            let label = TranscriptDocument.clock(start)
            if let onSeek {
                Button(label) { onSeek(start) }
                    .buttonStyle(.plain)
                    .font(SekitiriType.label.monospacedDigit())
                    .foregroundStyle(SekitiriColor.terracotta)
                    .help("Play from \(label)")
                    .accessibilityLabel("Play from \(label)")
            } else {
                Text(label)
                    .font(SekitiriType.label.monospacedDigit())
                    .foregroundStyle(SekitiriColor.terracotta)
            }
        } else {
            Color.clear.frame(height: 1)
        }
    }

    /// "You" (the microphone) in terracotta; everyone else in a stable
    /// secondary colour so the same person keeps the same colour.
    static func speakerColor(raw: String, name: String) -> Color {
        let lowered = raw.lowercased()
        if lowered == "you" || lowered == "me" || lowered == "mic" { return SekitiriColor.terracotta }
        return SKPersonPill.color(for: name)
    }

    /// Low-confidence words get a dotted underline; search matches a soft
    /// highlight. The text itself is never changed.
    static func attributed(_ segment: TranscriptDocument.Segment, query: String) -> AttributedString {
        var result = AttributedString(segment.text)
        for range in segment.lowConfidenceRanges {
            guard let target = Range(range, in: result) else { continue }
            result[target][AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self] =
                Text.LineStyle(pattern: .dot, color: SekitiriColor.muted)
        }
        guard !query.isEmpty else { return result }
        let text = segment.text
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let match = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<text.endIndex) {
            if let target = Range(match, in: result) {
                result[target][AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = SekitiriColor.highlight
            }
            searchStart = match.upperBound
        }
        return result
    }
}

/// Compact find field for a transcript.
struct TranscriptSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(SekitiriColor.muted)
                .accessibilityHidden(true)
            TextField("Find in transcript", text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(SekitiriColor.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(SekitiriColor.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(SekitiriColor.line))
    }
}
