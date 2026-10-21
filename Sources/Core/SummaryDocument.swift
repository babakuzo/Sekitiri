import CryptoKit
import Foundation

/// The canonical, versioned representation of a generated meeting summary.
///
/// `summary.md` remains a human-readable compatibility artifact. New code
/// should treat `summary.json` as the source of truth so action completion and
/// transcript provenance are not coupled to Markdown formatting.
struct CanonicalSummaryDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var generatedAt: Date
    var modelID: String
    var tone: String
    var sourceFingerprint: String
    var sources: [SummaryEvidenceSource]
    var sections: CanonicalSummarySections
    var actionItems: [CanonicalActionItem]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        generatedAt: Date,
        modelID: String,
        tone: String,
        sourceFingerprint: String,
        sources: [SummaryEvidenceSource],
        sections: CanonicalSummarySections,
        actionItems: [CanonicalActionItem]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.modelID = modelID
        self.tone = tone
        self.sourceFingerprint = sourceFingerprint
        self.sources = sources
        self.sections = sections
        self.actionItems = actionItems
    }
}

struct CanonicalSummarySections: Codable, Equatable, Sendable {
    var atAGlance: [SummaryClaim]
    var decisions: [SummaryClaim]
    var keyPoints: [SummaryClaim]
    var openQuestionsAndRisks: [SummaryClaim]
    var narrative: [SummaryClaim]
}

struct SummaryClaim: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var text: String
    var evidenceSourceIDs: [String]
}

struct CanonicalActionItem: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var text: String
    var owner: String?
    var dueDateText: String?
    var isCompleted: Bool
    var evidenceSourceIDs: [String]
}

struct SummaryEvidenceSource: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var lineIndex: Int
    var timestampSeconds: Int?
    var timestampText: String?
    var speaker: String?
    var quote: String
}

enum CanonicalSummaryBuilder {
    static func evidenceSources(from transcript: String) -> [SummaryEvidenceSource] {
        EvidenceParser.sources(from: transcript)
    }

    /// Only explicit source IDs supplied by extraction are retained. Lexical
    /// overlap between a legacy summary and transcript is not provenance.
    static func reconcile(_ document: CanonicalSummaryDocument, previous: CanonicalSummaryDocument?) -> CanonicalSummaryDocument {
        var result = document
        let valid = Set(document.sources.map(\.id))
        func validated(_ claims: [SummaryClaim]) -> [SummaryClaim] {
            claims.map { claim in
                var claim = claim
                claim.evidenceSourceIDs = claim.evidenceSourceIDs.filter { valid.contains($0) }
                return claim
            }
        }
        result.sections.atAGlance = validated(result.sections.atAGlance)
        result.sections.decisions = validated(result.sections.decisions)
        result.sections.keyPoints = validated(result.sections.keyPoints)
        result.sections.openQuestionsAndRisks = validated(result.sections.openQuestionsAndRisks)
        result.sections.narrative = validated(result.sections.narrative)
        result.actionItems = ActionItemReconciler.reconcile(result.actionItems.map { action in
            var action = action
            action.evidenceSourceIDs = action.evidenceSourceIDs.filter { valid.contains($0) }
            return action
        }, with: previous?.actionItems ?? [])
        return result
    }

    static func build(
        markdown: String,
        transcript: String,
        modelID: String,
        tone: String,
        generatedAt: Date = Date(),
        previous: CanonicalSummaryDocument? = nil
    ) -> CanonicalSummaryDocument {
        let sources = EvidenceParser.sources(from: transcript)
        let parsed = MarkdownSummaryParser.parse(markdown)

        func claims(_ values: [String], namespace: String) -> [SummaryClaim] {
            values.enumerated().map { index, text in
                SummaryClaim(
                    id: StableSummaryID.make(namespace: namespace, value: text, ordinal: index),
                    text: text,
                    evidenceSourceIDs: []
                )
            }
        }

        let draftActions = parsed.actionItems.enumerated().map { index, action in
            let parts = ActionItemParser.parts(from: action.text)
            return CanonicalActionItem(
                id: StableSummaryID.make(namespace: "action", value: ActionItemParser.signature(parts), ordinal: index),
                text: action.text,
                owner: nil,
                dueDateText: nil,
                isCompleted: action.isCompleted,
                evidenceSourceIDs: []
            )
        }
        let actions = ActionItemReconciler.reconcile(draftActions, with: previous?.actionItems ?? [])

        return CanonicalSummaryDocument(
            generatedAt: generatedAt,
            modelID: modelID,
            tone: tone,
            sourceFingerprint: StableSummaryID.digest(SummaryText.normalize(transcript)),
            sources: sources,
            sections: CanonicalSummarySections(
                atAGlance: claims(parsed.atAGlance, namespace: "glance"),
                decisions: claims(parsed.decisions, namespace: "decision"),
                keyPoints: claims(parsed.keyPoints, namespace: "key-point"),
                openQuestionsAndRisks: claims(parsed.openQuestionsAndRisks, namespace: "risk"),
                narrative: claims(parsed.narrative, namespace: "narrative")
            ),
            actionItems: actions
        )
    }

    /// Renders the compatibility file from canonical data. Evidence references
    /// and stable identifiers deliberately stay in JSON and never pollute the
    /// human-readable meeting notes.
    static func markdown(from document: CanonicalSummaryDocument) -> String {
        func body(_ claims: [SummaryClaim], bullets: Bool) -> String {
            guard !claims.isEmpty else { return "_(none)_" }
            return claims.map { bullets ? "- \($0.text)" : $0.text }.joined(separator: "\n")
        }
        let actions = document.actionItems.isEmpty
            ? "_(none)_"
            : document.actionItems.map { "- [\($0.isCompleted ? "x" : " ")] \($0.text)" }.joined(separator: "\n")
        return [
            "## At a glance\n\(body(document.sections.atAGlance, bullets: false))",
            "## Decisions\n\(body(document.sections.decisions, bullets: true))",
            "## Action Items\n\(actions)",
            "## Key Points\n\(body(document.sections.keyPoints, bullets: true))",
            "## Open Questions and Risks\n\(body(document.sections.openQuestionsAndRisks, bullets: true))",
            "## Summary\n\(body(document.sections.narrative, bullets: false))",
        ].joined(separator: "\n\n")
    }
}

private enum MarkdownSummaryParser {
    struct ParsedAction {
        var text: String
        var isCompleted: Bool
    }

    struct Parsed {
        var atAGlance: [String] = []
        var decisions: [String] = []
        var actionItems: [ParsedAction] = []
        var keyPoints: [String] = []
        var openQuestionsAndRisks: [String] = []
        var narrative: [String] = []
    }

    static func parse(_ markdown: String) -> Parsed {
        enum Section {
            case none, glance, decisions, actions, keyPoints, risks, narrative
        }
        var result = Parsed()
        var section = Section.none
        for rawLine in SummaryInput.canonicalizeSummary(markdown).components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            switch line {
            case "## At a glance": section = .glance
            case "## Decisions": section = .decisions
            case "## Action Items": section = .actions
            case "## Key Points": section = .keyPoints
            case "## Open Questions and Risks": section = .risks
            case "## Summary": section = .narrative
            default:
                guard !line.isEmpty, line != "_(none)_" else { continue }
                let value = stripListPrefix(line)
                guard !value.isEmpty else { continue }
                switch section {
                case .glance: result.atAGlance.append(value)
                case .decisions: result.decisions.append(value)
                case .actions:
                    let checked = value.range(of: #"^\[[xX]\]"#, options: .regularExpression) != nil
                    let text = value.replacingOccurrences(
                        of: #"^\[[ xX]\]\s*"#,
                        with: "",
                        options: .regularExpression
                    )
                    result.actionItems.append(ParsedAction(text: text, isCompleted: checked))
                case .keyPoints: result.keyPoints.append(value)
                case .risks: result.openQuestionsAndRisks.append(value)
                case .narrative: result.narrative.append(value)
                case .none: continue
                }
            }
        }
        return result
    }

    private static func stripListPrefix(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"^\s*(?:[-*+]\s+|\d+[.)]\s+)"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum EvidenceParser {
    static func sources(from transcript: String) -> [SummaryEvidenceSource] {
        transcript.components(separatedBy: .newlines).enumerated().flatMap { lineIndex, rawLine -> [SummaryEvidenceSource] in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("engine:"), line != "_(none)_" else { return [] }
            let parsed = parseTimestampedLine(line)
            let quote = parsed?.quote ?? line
            return passages(quote).enumerated().map { passageIndex, quote in
                let identity = [String(lineIndex), String(passageIndex), parsed?.timestampText ?? "", parsed?.speaker ?? "", SummaryText.normalize(quote)].joined(separator: "|")
                return SummaryEvidenceSource(
                    id: "src-\(StableSummaryID.digest(identity).prefix(20))",
                    lineIndex: lineIndex,
                    timestampSeconds: parsed?.seconds,
                    timestampText: parsed?.timestampText,
                    speaker: parsed?.speaker,
                    quote: quote
                )
            }
        }
    }

    /// Bounds an unusually long ASR utterance without discarding its original
    /// line/timestamp attribution or cutting in the middle of a word.
    private static func passages(_ quote: String) -> [String] {
        var result: [String] = []
        var remaining = quote[...]
        while remaining.count > 1_800 {
            let limit = remaining.index(remaining.startIndex, offsetBy: 1_800)
            let window = remaining[..<limit]
            let split = window.lastIndex(where: { $0.isWhitespace }) ?? limit
            result.append(String(remaining[..<split]).trimmingCharacters(in: .whitespacesAndNewlines))
            remaining = remaining[split...].drop(while: { $0.isWhitespace })
        }
        if !remaining.isEmpty { result.append(String(remaining)) }
        return result
    }

    private struct ParsedLine {
        var seconds: Int
        var timestampText: String
        var speaker: String
        var quote: String
    }

    private static func parseTimestampedLine(_ line: String) -> ParsedLine? {
        let patterns = [
            #"^\*\*\[(\d+):(\d+)\]\s+([^:]+):\*\*\s*(.+)$"#,
            #"^\[(\d+):(\d+)\]\s+([^:]+):\s*(.+)$"#,
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  match.numberOfRanges == 5,
                  let minuteRange = Range(match.range(at: 1), in: line),
                  let secondRange = Range(match.range(at: 2), in: line),
                  let speakerRange = Range(match.range(at: 3), in: line),
                  let quoteRange = Range(match.range(at: 4), in: line),
                  let minute = Int(line[minuteRange]),
                  let second = Int(line[secondRange]) else { continue }
            return ParsedLine(
                seconds: minute * 60 + second,
                timestampText: String(format: "%02d:%02d", minute, second),
                speaker: String(line[speakerRange]).trimmingCharacters(in: .whitespaces),
                quote: String(line[quoteRange]).trimmingCharacters(in: .whitespaces)
            )
        }
        return nil
    }
}

private enum ActionItemParser {
    struct Parts {
        var text: String
        var owner: String?
        var dueDateText: String?
    }

    static func parts(from raw: String) -> Parts {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let owner: String? = {
            guard let range = text.range(of: #"^.{1,80}?\s+[—–-]\s+"#, options: .regularExpression) else { return nil }
            return String(text[..<range.upperBound])
                .replacingOccurrences(of: #"\s+[—–-]\s+$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }()
        let dueDate: String? = {
            guard let range = text.range(
                of: #"\b(?:by|before|on)\s+(?:tomorrow|today|next\s+\w+|\d{1,2}(?:st|nd|rd|th)?\s+[A-Za-z]+(?:\s+\d{4})?|[A-Za-z]+\s+\d{1,2}(?:st|nd|rd|th)?(?:,?\s+\d{4})?)\b"#,
                options: [.regularExpression, .caseInsensitive]
            ) else { return nil }
            return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }()
        return Parts(text: text, owner: owner, dueDateText: dueDate)
    }

    static func signature(_ parts: Parts) -> String {
        [parts.owner, parts.dueDateText, parts.text]
            .compactMap { $0 }
            .map(SummaryText.normalize)
            .joined(separator: "|")
    }
}

private enum ActionItemReconciler {
    static func reconcile(_ drafts: [CanonicalActionItem], with previous: [CanonicalActionItem]) -> [CanonicalActionItem] {
        var unused = Set(previous.indices)
        return drafts.map { draft in
            let exact = unused.sorted().first { index in
                SummaryText.normalize(previous[index].text) == SummaryText.normalize(draft.text)
                    && previous[index].owner.map(SummaryText.normalize) == draft.owner.map(SummaryText.normalize)
                    && previous[index].dueDateText.map(SummaryText.normalize) == draft.dueDateText.map(SummaryText.normalize)
            }
            let best = exact ?? unused.sorted().compactMap { index -> (Int, Double)? in
                let score = similarity(draft, previous[index])
                return score >= 0.85 ? (index, score) : nil
            }.max { lhs, rhs in lhs.1 < rhs.1 }?.0

            guard let best else { return draft }
            unused.remove(best)
            var reconciled = draft
            reconciled.id = previous[best].id
            reconciled.isCompleted = previous[best].isCompleted
            return reconciled
        }
    }

    private static func similarity(_ lhs: CanonicalActionItem, _ rhs: CanonicalActionItem) -> Double {
        if let leftOwner = lhs.owner, let rightOwner = rhs.owner,
           SummaryText.normalize(leftOwner) != SummaryText.normalize(rightOwner) { return 0 }
        if lhs.dueDateText.map(SummaryText.normalize) != rhs.dueDateText.map(SummaryText.normalize) { return 0 }
        let left = SummaryText.words(lhs.text)
        let right = SummaryText.words(rhs.text)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let lexical = Double(2 * left.intersection(right).count) / Double(left.count + right.count)
        let ownerBonus = sameOptional(lhs.owner, rhs.owner) ? 0.12 : 0
        let dueBonus = sameOptional(lhs.dueDateText, rhs.dueDateText) ? 0.08 : 0
        return min(1, lexical + ownerBonus + dueBonus)
    }

    private static func sameOptional(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        return SummaryText.normalize(lhs) == SummaryText.normalize(rhs)
    }
}

private enum SummaryText {
    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "in", "is", "it", "of", "on", "or", "the", "to", "was", "we", "will", "with"
    ]

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func words(_ text: String) -> Set<String> {
        Set(normalize(text).split(separator: " ").map(String.init).filter { $0.count > 1 && !stopWords.contains($0) })
    }
}

private enum StableSummaryID {
    static func make(namespace: String, value: String, ordinal: Int) -> String {
        "\(namespace)-\(digest("\(namespace)|\(SummaryText.normalize(value))|\(ordinal)").prefix(20))"
    }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
