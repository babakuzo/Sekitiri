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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(section.title.uppercased())
                .font(SekitiriType.body(10, weight: .medium))
                .foregroundColor(SekitiriColor.terracotta)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(section.items.indices, id: \.self) { i in
                    SummaryItemView(item: section.items[i], onEvidence: onEvidence)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SummaryItemView: View {
    let item: SummaryItem
    var onEvidence: (SummaryEvidenceSource) -> Void = { _ in }

    var body: some View {
        switch item {
        case .text(let text): content(text)
        case .checkbox(let text, let checked):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(checked ? .accentColor : .secondary).font(.system(size: 14)).offset(y: 2)
                content(text).strikethrough(checked)
            }.fixedSize(horizontal: false, vertical: true)
        case .bullet(let text): bullet(text)
        case .claim(let text, let sources, let isBullet):
            VStack(alignment: .leading, spacing: 5) {
                if isBullet { bullet(text) } else { content(text) }
                if !sources.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(sources) { source in
                            Button { onEvidence(source) } label: {
                                Label(source.timestampText ?? "Transcript", systemImage: "text.quote")
                            }
                            .buttonStyle(.plain).font(SekitiriType.body(10))
                            .foregroundStyle(SekitiriColor.terracotta)
                            .accessibilityLabel("Show transcript source \(source.timestampText ?? "")")
                        }
                    }
                }
            }
        }
    }

    private func content(_ text: String) -> some View {
        Text(SummaryParser.inline(text))
            .font(.system(size: 16, design: .serif))
            .foregroundColor(SekitiriColor.ink).lineSpacing(4)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("•").foregroundColor(.secondary)
            content(text)
        }.fixedSize(horizontal: false, vertical: true)
    }
}
