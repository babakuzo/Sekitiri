import Foundation
import Testing
@testable import SekitiriApp

@Suite("Source-only meeting summaries")
struct SourceSelectionSummaryTests {
    private func source(_ label: String, _ quote: String, speaker: String = "Alex", line: Int = 0) -> StructuredSummaryPipeline.LabeledSource {
        .init(label: label, evidence: .init(id: "original-\(label)", lineIndex: line, timestampSeconds: line * 10, timestampText: "00:00", speaker: speaker, quote: quote))
    }
    private func selection(decisions: [String] = [], actions: [String] = [], facts: [String] = [], proposals: [String] = [], unresolved: [String] = [], corrections: [String] = []) throws -> String {
        String(decoding: try JSONEncoder().encode(SourceSelectionSummary.Selection(decisions: decisions, actions: actions, facts: facts, proposals: proposals, unresolved: unresolved, corrections: corrections)), as: UTF8.self)
    }

    @Test("Selections copy source wording instead of accepting rewritten claims")
    func exactSourceWording() throws {
        let quote = "Je m’engage à envoyer le rapport avant vendredi."
        let sources = [source("S1", quote, speaker: "Élodie")]
        let records = try SourceSelectionSummary.recordsFromSelection(selection(actions: ["S1"]), sources: sources)
        #expect(records.count == 1)
        #expect(records[0].0.text == quote)
        #expect(records[0].0.quote == quote)
        #expect(records[0].0.owner == "Élodie")
        #expect(records[0].0.due == "avant vendredi")
        #expect(records[0].1.id == "original-S1")
    }

    @Test("Unknown or missing selection arrays fail without partial notes")
    func strictSelectionSchema() {
        for output in ["{\"actions\":[\"S1\"]}", "{\"decisions\":[]", "Here are the notes."] {
            #expect(throws: StructuredSummaryPipeline.ExtractionError.self) {
                try SourceSelectionSummary.recordsFromSelection(output, sources: [source("S1", "I will send the report.")])
            }
        }
        #expect(throws: StructuredSummaryPipeline.ExtractionError.self) {
            try SourceSelectionSummary.recordsFromSelection(selection(actions: ["S1", "S999"]), sources: [source("S1", "I will send the report.")])
        }
    }

    @Test("Several sentences from one utterance remain in candidate order")
    func deterministicTies() throws {
        let sources = [source("S2", "The first observation is useful."), source("S10", "The second observation is useful."), source("S1", "The third observation is useful.")]
        let raw = try selection(facts: ["S1", "S10", "S2", "S10"])
        for _ in 0..<20 {
            let records = try SourceSelectionSummary.recordsFromSelection(raw, sources: sources)
            #expect(records.map { $0.0.source } == ["S2", "S10", "S1"])
        }
    }

    @Test("Unsupported commitment selections become unresolved, never tasks")
    func falseTaskGuard() throws {
        let quotes = [
            "The budget is 450 euros.",
            "We decided to retain the existing plan.",
            "Could someone prepare a report?",
            "Someone should investigate the supplier.",
            "Maybe we could send the proposal.",
            "I will not send the proposal.",
            "I will never send the proposal.",
            "I will send the proposal if approval arrives.",
            "Alex will not send the proposal.",
            "Je ne vais pas préparer le rapport.",
            "Nous n’allons pas envoyer la proposition.",
            "Je m’engage à ne pas acheter cet outil.",
        ]
        for quote in quotes {
            let records = try SourceSelectionSummary.recordsFromSelection(selection(actions: ["S1"]), sources: [source("S1", quote)])
            #expect(records.map { $0.0.type } == [.question])
            #expect(records[0].0.owner == nil)
            #expect(records[0].0.due == nil)
        }
    }

    @Test("Explicit first-person, collective and named commitments are supported")
    func positiveTaskGuard() {
        for quote in ["I will send the report.", "I’ll prepare the draft.", "We will review the figures.", "We are going to send the report.", "Je vais envoyer le rapport.", "Nous allons vérifier les chiffres.", "Je m’engage à préparer le rapport.", "Nous nous engageons à relire le dossier.", "Léa Martin will send the report.", "Léa Martin est responsable de la revue.", "The report is assigned to Léa Martin."] {
            #expect(SourceSelectionSummary.hasExplicitCommitment(quote, participants: []))
        }
        #expect(SourceSelectionSummary.explicitOwner("We will send the report.", speaker: "Alex", participants: ["Alex"]) == nil)
        #expect(SourceSelectionSummary.explicitOwner("Nous allons vérifier les chiffres.", speaker: "Alex", participants: []) == nil)
        #expect(SourceSelectionSummary.explicitOwner("Léa Martin will send the report.", speaker: "Alex", participants: []) == "Léa Martin")
        #expect(SourceSelectionSummary.explicitOwner("The report is assigned to Léa Martin.", speaker: "Alex", participants: []) == "Léa Martin")
        #expect(SourceSelectionSummary.explicitOwner("O’Connor will send the report.", speaker: "Alex", participants: []) == "O’Connor")
    }

    @Test("Deadline extraction preserves literal dates without assigning ordering clauses")
    func literalDeadlineOnly() {
        #expect(SourceSelectionSummary.explicitDeadline("I will send this before publishing.") == nil)
        #expect(SourceSelectionSummary.explicitDeadline("I will send it by email before Friday.") == "before Friday")
        #expect(SourceSelectionSummary.explicitDeadline("I will increase sales by 15 percent.") == nil)
        #expect(SourceSelectionSummary.explicitDeadline("I will raise the budget by 450 euros.") == nil)
        #expect(SourceSelectionSummary.explicitDeadline("I will send it by 2026-10-23.") == "by 2026-10-23")
        #expect(SourceSelectionSummary.explicitDeadline("I will send it by 23 October.") == "by 23 October")
        #expect(SourceSelectionSummary.explicitDeadline("I will send it by 2 pm.") == "by 2 pm")
        #expect(SourceSelectionSummary.explicitDeadline("I will send it by email before publishing.") == nil)
        #expect(SourceSelectionSummary.explicitDeadline("Je vais l'envoyer d’ici vendredi.") == "d’ici vendredi")
        #expect(SourceSelectionSummary.explicitDeadline("Je vais l'envoyer avant vendredi 23 octobre.") == "avant vendredi 23 octobre")
        #expect(SourceSelectionSummary.explicitDeadline("I will send this by Monday 26 October.") == "by Monday 26 October")
    }

    @Test("Undecided statements cannot become current decisions")
    func undecidedDemotion() throws {
        for quote in ["The delivery date is not decided.", "Nous n'avons pris aucune décision."] {
            let records = try SourceSelectionSummary.recordsFromSelection(selection(decisions: ["S1"]), sources: [source("S1", quote)])
            #expect(records.map { $0.0.type } == [.question])
        }
    }

    @Test("Cancellation after the final selection cannot publish a summary")
    func finalCancellation() async {
        let task = Task {
            do {
                _ = try await SourceSelectionSummary.run(transcript: "**[0:01] Alex:** The existing report is available.", modelID: "fixture", tone: "Concise", maxCharacters: 2_000, progress: { _ in }) { _, _, _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return try selection()
                }
                Issue.record("A cancelled selection must not publish notes")
            } catch { #expect(error is CancellationError) }
        }
        await task.value
    }

    @Test("Only exact known source renderings can recover a non-ID selection")
    func strictLiteralRecovery() throws {
        let sources = [source("S1", "I will send the report before Friday.", speaker: "Maya")]
        #expect(try SourceSelectionSummary.resolveSelection("S1: I will send the report before Friday.", sources: sources) == "S1")
        #expect(try SourceSelectionSummary.resolveSelection("[S1] Maya: I will send the report before Friday.", sources: sources) == "S1")
        #expect(try SourceSelectionSummary.resolveSelection("Maya: I will send the report before Friday.", sources: sources) == "S1")
        for invalid in ["S1: I will send the report before Monday.", "S999: I will send the report before Friday.", "S1: i will send the report before Friday.", "I will send the report before Friday."] {
            #expect(throws: StructuredSummaryPipeline.ExtractionError.self) {
                try SourceSelectionSummary.resolveSelection(invalid, sources: sources)
            }
        }
        #expect(throws: StructuredSummaryPipeline.ExtractionError.self) {
            try SourceSelectionSummary.resolveSelection("Maya: I will send the report before Friday.", sources: sources + [source("S2", "I will send the report before Friday.", speaker: "Maya")])
        }
    }

    @Test("Source rules preserve decisions, tasks and uncertainty when a model returns nothing")
    func ruleCoreSurvivesOmissions() async throws {
        let transcript = """
        **[0:01] Maya:** We decided to retain the existing plan.
        **[0:10] Élodie:** Je m’engage à envoyer le rapport avant vendredi.
        **[0:20] Amir:** We will review the figures before Monday.
        **[0:30] Bea:** The delivery date remains undecided.
        """
        let result = try await SourceSelectionSummary.run(transcript: transcript, modelID: "fixture", tone: "Concise", maxCharacters: 2_000, progress: { _ in }) { _, _, _ in try selection() }
        #expect(result.document.sections.decisions.count == 1)
        #expect(result.document.actionItems.count == 2)
        #expect(result.document.actionItems[0].owner == "Élodie")
        #expect(result.document.actionItems[0].dueDateText == "avant vendredi")
        #expect(result.document.actionItems[1].owner == nil)
        #expect(result.document.actionItems[1].dueDateText == "before Monday")
        #expect(result.document.sections.openQuestionsAndRisks.count == 1)
    }

    @Test("Malformed model output yields a clearly marked complete source draft")
    func draftFallback() async throws {
        let transcript = "**[0:01] Maya:** I will send the report before Friday. The date of the next meeting is not decided."
        let result = try await SourceSelectionSummary.run(transcript: transcript, modelID: "fixture", tone: "Concise", maxCharacters: 2_000, progress: { _ in }) { _, _, _ in "invalid JSON" }
        #expect(result.document.modelID == "fixture+source-draft")
        #expect(result.document.actionItems.count == 1)
        #expect(result.document.sections.openQuestionsAndRisks.count == 1)
        #expect(result.document.actionItems[0].evidenceSourceIDs == [result.document.sources[0].id])
    }

    @Test("Source rules do not promote conditional or negative statements")
    func conservativeRules() throws {
        let quotes = [
            "If we receive approval, we will send the report.",
            "I will send the report if approval arrives.",
            "We will review the proposal unless the customer withdraws.",
            "Je vais envoyer le rapport si le client confirme.",
            "Would we agree to launch next week?",
            "We could agree to revise the budget.",
            "Nous n’allons pas envoyer la proposition.",
            "I will not send the report.",
            "The budget is 450 euros.",
        ]
        let records = try SourceSelectionSummary.coreRecords(from: quotes.enumerated().map { source("S\($0.offset + 1)", $0.element, line: $0.offset) })
        #expect(records.allSatisfy { ![.action, .decision, .correction].contains($0.0.type) })
        #expect(!SourceSelectionSummary.hasExplicitCorrection("We could cancel the earlier agreement."))
        #expect(!SourceSelectionSummary.hasExplicitCorrection("If approval changes, the earlier task is cancelled."))
        #expect(!SourceSelectionSummary.hasExplicitCorrection("The earlier task is not cancelled."))
        #expect(SourceSelectionSummary.hasExplicitDecision("We have now decided to move office hours to Wednesday instead."))
        #expect(SourceSelectionSummary.hasExplicitCorrection("My earlier commitment is withdrawn."))
        #expect(SourceSelectionSummary.hasExplicitCorrection("Nous remplaçons notre décision précédente."))
    }

    @Test("A malformed model selection still yields a review draft for source-linked corrections")
    func correctionDraftSurvivesModelFailure() async throws {
        let result = try await SourceSelectionSummary.run(transcript: "**[0:01] Maya:** I will send the report before Friday. My earlier commitment is withdrawn.", modelID: "fixture", tone: "Concise", maxCharacters: 2_000, progress: { _ in }) { _, _, _ in "invalid JSON" }
        #expect(result.document.modelID == "fixture+source-draft")
        #expect(result.document.actionItems.isEmpty)
        #expect(result.document.sections.openQuestionsAndRisks.count == 2)
    }

    @Test("Correction chronology distinguishes sentences inside a single utterance")
    func sameUtteranceCorrection() async throws {
        let transcript = "**[0:01] Alex:** I will send the report before Friday. That commitment is now withdrawn."
        let result = try await SourceSelectionSummary.run(transcript: transcript, modelID: "fixture", tone: "Concise", maxCharacters: 2_000, progress: { _ in }) { instructions, _, _ in
            if instructions == StructuredSummaryPipeline.reconciliationInstructions {
                return "{\"superseded\":[{\"record\":\"R1\",\"by\":\"R2\"}]}"
            }
            return try selection(actions: ["S1"], corrections: ["S2"])
        }
        #expect(result.document.actionItems.isEmpty)
        #expect(result.document.sections.openQuestionsAndRisks.count == 2)
        #expect(result.document.modelID == "fixture+source-draft")
        #expect(result.document.sources.count == 1)
        #expect(result.document.sources[0].lineIndex == 0)
        #expect(result.document.sections.openQuestionsAndRisks[0].evidenceSourceIDs == [result.document.sources[0].id])
    }
}
