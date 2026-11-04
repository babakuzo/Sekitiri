import SwiftUI

struct SummarySection: Identifiable {
    let id = UUID()
    let title: String
    let items: [SummaryItem]
}

enum SummaryItem {
    case text(String)
    case checkbox(String, checked: Bool)
    case bullet(String)
    case claim(String, sources: [SummaryEvidenceSource], bullet: Bool)

    var text: String {
        switch self {
        case .text(let text), .checkbox(let text, _), .bullet(let text), .claim(let text, _, _): return text
        }
    }
}

extension SummarySection {
    /// True when the model wrote only "None." (or nothing) under this heading.
    var isEmptyPlaceholder: Bool {
        items.allSatisfy { OpenActionItem.isPlaceholder($0.text) }
    }
}

struct SummaryParser {
    static func parse(_ document: CanonicalSummaryDocument) -> [SummarySection] {
        let sources = Dictionary(document.sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func section(_ title: String, _ claims: [SummaryClaim], bullet: Bool) -> SummarySection {
            SummarySection(title: title, items: claims.map { .claim($0.text, sources: $0.evidenceSourceIDs.compactMap { sources[$0] }, bullet: bullet) })
        }
        return [
            section("At a glance", document.sections.atAGlance, bullet: false),
            section("Decisions", document.sections.decisions, bullet: true),
            section("Key Points", document.sections.keyPoints, bullet: true),
            section("Open Questions and Risks", document.sections.openQuestionsAndRisks, bullet: true),
            section("Summary", document.sections.narrative, bullet: false),
        ].filter { !$0.items.isEmpty }
    }

    static func parse(_ markdown: String) -> [SummarySection] {
        var sections: [SummarySection] = []
        var title = ""
        var items: [SummaryItem] = []
        let lines = SummaryInput.canonicalizeSummary(markdown).components(separatedBy: .newlines)
        var inFrontmatter = false
        var frontmatterEnded = false
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---", index == 0 || inFrontmatter {
                inFrontmatter.toggle()
                if !inFrontmatter { frontmatterEnded = true }
                continue
            }
            if inFrontmatter { continue }
            if trimmed.hasPrefix("## ") {
                if !title.isEmpty || !items.isEmpty { sections.append(SummarySection(title: title, items: items)) }
                title = String(trimmed.dropFirst(3)); items = []; continue
            }
            if trimmed.isEmpty || trimmed == "_(none)_" || trimmed.hasPrefix("# ") || (frontmatterEnded && trimmed == "---") { continue }
            let value = trimmed.replacingOccurrences(of: #"^(?:[-*+]\s+|\d+[.)]\s+)"#, with: "", options: .regularExpression)
            if let range = value.range(of: #"^\[([ xX])\]\s*"#, options: .regularExpression) {
                let checked = String(value[range]).lowercased().contains("x")
                items.append(.checkbox(String(value[range.upperBound...]), checked: checked))
            } else if value != trimmed {
                items.append(.bullet(value))
            } else {
                items.append(.text(trimmed))
            }
        }
        if !title.isEmpty || !items.isEmpty { sections.append(SummarySection(title: title, items: items)) }
        return sections
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    static func hasPendingActions(_ markdown: String) -> Bool {
        CanonicalSummaryBuilder.build(markdown: markdown, transcript: "", modelID: "legacy", tone: "Unknown").actionItems.contains { !$0.isCompleted }
    }
}

struct SummarySectionView: View {
    let section: SummarySection
    var onEvidence: (SummaryEvidenceSource) -> Void = { _ in }
    var onPlay: ((SummaryEvidenceSource) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SKSectionHeader(section.title, font: SekitiriType.subTitle)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(section.items.indices, id: \.self) { i in
                    SummaryItemView(item: section.items[i], onEvidence: onEvidence, onPlay: onPlay)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SummaryItemView: View {
    let item: SummaryItem
    var onEvidence: (SummaryEvidenceSource) -> Void = { _ in }
    var onPlay: ((SummaryEvidenceSource) -> Void)? = nil

    var body: some View {
        switch item {
        case .text(let text): content(text)
        case .checkbox(let text, let checked):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(checked ? SekitiriColor.terracotta : SekitiriColor.muted)
                    .accessibilityHidden(true)
                content(text).strikethrough(checked)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityValue(checked ? "Completed" : "Not completed")
        case .bullet(let text): bullet(text)
        case .claim(let text, let sources, let isBullet):
            VStack(alignment: .leading, spacing: 5) {
                if isBullet { bullet(text) } else { content(text) }
                if !sources.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(sources) { source in
                            EvidenceChip(source: source, onOpen: { onEvidence(source) }, onPlay: onPlay)
                        }
                    }
                    .padding(.leading, isBullet ? 18 : 0)
                }
            }
        }
    }

    private func content(_ text: String) -> some View {
        Text(SummaryParser.inline(text))
            .font(SekitiriType.reading)
            .foregroundStyle(SekitiriColor.ink)
            .lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("•").foregroundStyle(SekitiriColor.muted).accessibilityHidden(true)
            content(text)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A transcript reference attached to a summary claim. Click shows the quote
/// (with "Play from …"); the context menu plays the recording directly.
struct EvidenceChip: View {
    let source: SummaryEvidenceSource
    let onOpen: () -> Void
    var onPlay: ((SummaryEvidenceSource) -> Void)? = nil

    private var label: String { source.timestampText ?? "Transcript" }

    var body: some View {
        Button(action: onOpen) {
            Label(label, systemImage: "text.quote")
                .font(SekitiriType.label.monospacedDigit())
        }
        .buttonStyle(.plain)
        .foregroundStyle(SekitiriColor.terracotta)
        .help(source.quote)
        .accessibilityLabel("Show transcript source \(source.timestampText ?? "")")
        .contextMenu {
            Button("Show Source Quote", action: onOpen)
            if let onPlay, source.timestampSeconds != nil {
                Button("Play from \(label)") { onPlay(source) }
            }
        }
    }
}
