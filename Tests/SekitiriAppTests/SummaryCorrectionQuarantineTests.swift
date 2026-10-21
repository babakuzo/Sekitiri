import Foundation
import Testing
@testable import SekitiriApp

@Suite("Conservative review after corrections")
struct SummaryCorrectionQuarantineTests {
    private func records(_ rows: [(String, String)]) throws -> [(StructuredSummaryPipeline.Record, SummaryEvidenceSource)] {
        let sources = rows.enumerated().map { index, row in
            StructuredSummaryPipeline.LabeledSource(label: "S\(index + 1)", evidence: .init(id: "original-\(index)", lineIndex: index, timestampSeconds: index * 10, timestampText: "00:00", speaker: row.0, quote: row.1))
        }
        return try SourceSelectionSummary.coreRecords(from: sources)
    }

    @Test("Related earlier choices are reviewed while later replacements remain current")
    func replacementsRemainActive() throws {
        let input = try records([
            ("Maya", "We decided to hold training sessions on Tuesday."),
            ("Bea", "We agreed to set the funding ceiling at 100 euros."),
            ("Maya", "The Tuesday training sessions are cancelled."),
            ("Maya", "We have now decided to hold training sessions on Thursday instead."),
            ("Bea", "The earlier funding ceiling is replaced by 200 euros."),
            ("Bea", "We have decided to set the funding ceiling at 200 euros."),
        ])
        let result = SourceSelectionSummary.quarantineRelatedEarlierClaims(input)
        let active = result.records.filter { $0.0.type == .decision }.map { $0.0.text }
        #expect(result.didQuarantine)
        #expect(active.count == 2)
        #expect(active.contains { $0.contains("Thursday") })
        #expect(active.contains { $0.contains("200 euros") })
        #expect(!active.contains { $0.contains("Tuesday") || $0.contains("100 euros") })
        #expect(result.records.filter { $0.0.type == .risk }.allSatisfy { $0.0.text.hasPrefix("Needs review") })
    }

    @Test("Same-owner unrelated tasks survive a personal withdrawal")
    func unrelatedTask() throws {
        let result = SourceSelectionSummary.quarantineRelatedEarlierClaims(try records([
            ("Alex", "I will prepare recruitment questions before Friday."),
            ("Alex", "I will send the financial report before Friday."),
            ("Alex", "My earlier commitment to prepare recruitment questions is withdrawn."),
        ]))
        #expect(result.records.filter { $0.0.type == .action }.map { $0.0.text } == ["I will send the financial report before Friday."])
        #expect(result.records.filter { $0.0.type == .risk }.count == 1)
    }

    @Test("A personal withdrawal does not cancel another person's matching task")
    func ownerSensitiveWithdrawal() throws {
        let result = SourceSelectionSummary.quarantineRelatedEarlierClaims(try records([
            ("Alex", "I will prepare recruitment questions before Friday."),
            ("Bea", "I will prepare recruitment questions before Friday."),
            ("Alex", "My earlier commitment to prepare recruitment questions is withdrawn."),
        ]))
        let active = result.records.filter { $0.0.type == .action }
        #expect(active.count == 1)
        #expect(active[0].0.owner == "Bea")
        #expect(result.records.filter { $0.0.type == .risk }.count == 1)
    }

    @Test("Dates, amounts, currency and generic report wording do not match unrelated topics")
    func ignoresNonTopicOverlap() throws {
        let result = SourceSelectionSummary.quarantineRelatedEarlierClaims(try records([
            ("Alex", "I will send the financial report before Friday."),
            ("Bea", "We agreed to set the ticket price at 10 euros."),
            ("Alex", "My earlier Friday commitment to prepare the environmental report is withdrawn."),
            ("Bea", "The earlier budget of 450 euros is cancelled."),
        ]))
        #expect(!result.didQuarantine)
        #expect(result.records.filter { $0.0.type == .action }.count == 1)
        #expect(result.records.filter { $0.0.type == .decision }.count == 1)
    }

    @Test("An ambiguous same-topic revision requires review rather than a current task")
    func ambiguousTopicNeedsReview() throws {
        let original = "I will finalize the forecast document before Friday."
        let result = SourceSelectionSummary.quarantineRelatedEarlierClaims(try records([
            ("Alex", original),
            ("Alex", "My earlier forecast review is withdrawn."),
        ]))
        #expect(result.didQuarantine)
        #expect(result.records.filter { $0.0.type == .action }.isEmpty)
        let review = try #require(result.records.first { $0.0.type == .risk })
        #expect(review.0.quote == original)
        #expect(review.0.text.hasPrefix("Needs review"))
        #expect(result.references[review.0.text] == ["original-0", "original-1"])
    }

    @Test("Source-linked review does not ask a model to delete obligations")
    func noModelDeletionPass() async throws {
        let transcript = "**[0:01] Alex:** I will prepare recruitment questions before Friday.\n**[0:20] Alex:** My earlier commitment to prepare recruitment questions is withdrawn."
        let emptySelection = "{\"decisions\":[],\"actions\":[],\"facts\":[],\"proposals\":[],\"unresolved\":[],\"corrections\":[]}"
        let result = try await SourceSelectionSummary.run(transcript: transcript, modelID: "fixture", tone: "Concise", maxCharacters: 2_000, progress: { _ in }) { instructions, _, _ in
            #expect(instructions == SourceSelectionSummary.instructions)
            return emptySelection
        }
        #expect(result.document.actionItems.isEmpty)
        #expect(result.document.modelID == "fixture+source-draft")
        let review = try #require(result.document.sections.openQuestionsAndRisks.first { $0.text.hasPrefix("Needs review") })
        #expect(review.evidenceSourceIDs == result.document.sources.map(\.id))
        #expect(result.document.sections.atAGlance.allSatisfy { !$0.text.contains("recruitment") })
    }
}
