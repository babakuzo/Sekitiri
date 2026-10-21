import Foundation
import Testing
@testable import SekitiriApp

@Suite("Evidence-first summary extraction")
struct StructuredSummaryTests {
    private func source(_ label: String = "S1", quote: String = "I will send the report before Friday.", speaker: String = "Maya") -> StructuredSummaryPipeline.LabeledSource {
        .init(label: label, evidence: .init(id: "source-\(label)", lineIndex: 0, timestampSeconds: 10, timestampText: "00:10", speaker: speaker, quote: quote))
    }

    @Test("Rejects invented source identifiers and unsupported evidence")
    func evidenceValidation() {
        let record = StructuredSummaryPipeline.Record(type: .action, text: "Send the report.", source: "S999", quote: "I will send the report", owner: "Maya", due: nil)
        #expect(throws: StructuredSummaryPipeline.ExtractionError.self) {
            try StructuredSummaryPipeline.validate([record], against: [source()])
        }
        var fabricated = record
        fabricated.source = "S1"
        fabricated.quote = "I will approve the budget"
        #expect(throws: StructuredSummaryPipeline.ExtractionError.self) {
            try StructuredSummaryPipeline.validate([fabricated], against: [source()])
        }
    }

    @Test("Owners and deadlines need literal support, including French")
    func explicitActionMetadata() throws {
        let french = source(quote: "Je vais envoyer le rapport avant vendredi.", speaker: "Élodie")
        var record = StructuredSummaryPipeline.Record(type: .action, text: "Envoyer le rapport.", source: "S1", quote: "Je vais envoyer le rapport avant vendredi.", owner: "Élodie", due: "avant vendredi")
        let validated = try StructuredSummaryPipeline.validate([record], against: [french])
        #expect(validated.first?.0.owner == "Élodie")
        #expect(validated.first?.0.due == "avant vendredi")
        record.due = "2026-10-23"
        #expect(throws: StructuredSummaryPipeline.ExtractionError.self) {
            try StructuredSummaryPipeline.validate([record], against: [french])
        }
        record.due = nil
        record.owner = "Alice"
        #expect(throws: StructuredSummaryPipeline.ExtractionError.self) {
            try StructuredSummaryPipeline.validate([record], against: [french])
        }
    }

    @Test("Incomplete JSON and commentary never become saved notes")
    func invalidJSON() {
        for output in ["{\"records\":[", "Here are your notes: {\"records\":[]}", "<think>guess</think>{\"records\":[]}"] {
            #expect(throws: StructuredSummaryPipeline.ExtractionError.self) { try StructuredSummaryPipeline.decode(output) }
        }
    }

    @Test("Valid JSON fences are accepted without inventing missing fields")
    func fencedJSON() throws {
        #expect(try StructuredSummaryPipeline.decode("```json\n{\"records\":[]}\n```").isEmpty)
        #expect(throws: StructuredSummaryPipeline.ExtractionError.self) {
            try StructuredSummaryPipeline.decode("{\"records\":[{\"type\":\"action\",\"text\":\"Send\"}]}")
        }
    }

    @Test("All passages remain in bounded extraction chunks")
    func boundedChunks() throws {
        let sources = (1...20).map { source("S\($0)") }
        let chunks = try StructuredSummaryPipeline.chunk(sources, maxCharacters: 160)
        #expect(chunks.count > 1)
        #expect(chunks.flatMap { $0 }.map(\.label) == sources.map(\.label))
        #expect(chunks.allSatisfy { $0.map(\.promptText).joined(separator: "\n").count <= 160 })
    }

    @Test("Canonical output preserves proposals and actions without Markdown repair")
    func canonicalResult() async throws {
        let transcript = "**[0:10] Maya:** I will send the report before Friday.\n**[0:20] Jules:** We could switch to Wednesday."
        let output = """
        {"records":[
          {"type":"action","text":"Send the report.","source":"S1","quote":"I will send the report before Friday.","owner":"Maya","due":"before Friday"},
          {"type":"proposal","text":"Switching to Wednesday was proposed.","source":"S2","quote":"We could switch to Wednesday.","owner":null,"due":null}
        ]}
        """
        let result = try await StructuredSummaryPipeline.run(transcript: transcript, modelID: "fixture", tone: "Concise", progress: { _ in }) { _, _, _ in output }
        #expect(result.passCount == 1)
        #expect(result.document.sections.decisions.isEmpty)
        #expect(result.document.actionItems.count == 1)
        #expect(result.document.actionItems.first?.owner == "Maya")
        #expect(result.document.actionItems.first?.dueDateText == "before Friday")
        #expect(result.document.sections.keyPoints.first?.text == "Proposal: Switching to Wednesday was proposed.")
        #expect(result.document.actionItems.first?.evidenceSourceIDs == [result.document.sources[0].id])
        let markdown = CanonicalSummaryBuilder.markdown(from: result.document)
        #expect(SummaryInput.hasRequiredHeadings(markdown))
        #expect(markdown.contains("- [ ] Maya"))
    }

    @Test("Identical task wording preserves distinct owners and deadlines")
    func distinctCommitments() async throws {
        let transcript = "**[0:10] Maya:** I will send the report before Friday.\n**[0:20] Jules:** I will send the report before Monday."
        let records = [
            StructuredSummaryPipeline.Record(type: .action, text: "Send the report.", source: "S1", quote: "I will send the report before Friday.", owner: "Maya", due: "before Friday"),
            .init(type: .action, text: "Send the report.", source: "S2", quote: "I will send the report before Monday.", owner: "Jules", due: "before Monday"),
        ]
        let output = String(decoding: try JSONEncoder().encode(StructuredSummaryPipeline.Envelope(records: records)), as: UTF8.self)
        let result = try await StructuredSummaryPipeline.run(transcript: transcript, modelID: "fixture", tone: "Concise", progress: { _ in }) { _, _, _ in output }
        #expect(result.document.actionItems.count == 2)
        #expect(Set(result.document.actionItems.compactMap(\.owner)) == ["Maya", "Jules"])
        #expect(Set(result.document.actionItems.map(\.id)).count == 2)
    }

    @Test("Malformed extraction is re-run from sources, never repaired from the draft")
    func retryUsesSources() async throws {
        var calls = 0
        let transcript = "**[0:10] Maya:** I will send the report before Friday.\n**[0:20] Jules:** We could switch to Wednesday."
        let result = try await StructuredSummaryPipeline.run(transcript: transcript, modelID: "fixture", tone: "Concise", progress: { _ in }) { _, input, _ in
            calls += 1
            #expect(!input.contains("truncated draft"))
            if calls == 1 { return "truncated draft" }
            return "{\"records\":[]}"
        }
        #expect(calls == 3)
        #expect(result.passCount == 3)
        #expect(result.document.actionItems.isEmpty)
    }
}

@Suite("Meeting correction ledger")
struct SummaryCorrectionLedgerTests {
    private func item(
        _ kind: StructuredSummaryPipeline.RecordKind,
        _ text: String,
        line: Int,
        owner: String? = nil,
        due: String? = nil
    ) -> (StructuredSummaryPipeline.Record, SummaryEvidenceSource) {
        let source = SummaryEvidenceSource(id: "source-\(line)", lineIndex: line, timestampSeconds: line * 10, timestampText: "00:\(line)", speaker: owner ?? "Camille", quote: text)
        return (.init(type: kind, text: text, source: "S\(line + 1)", quote: text, owner: owner, due: due), source)
    }

    @Test("A later explicit revision suppresses the earlier decision, not its replacement")
    func reversal() async throws {
        let values = [
            item(.decision, "Office hours are Thursday.", line: 0),
            item(.decision, "Office hours are Wednesday.", line: 20),
            item(.correction, "Thursday is cancelled; we agreed Wednesday instead.", line: 20),
        ]
        let result = try await StructuredSummaryPipeline.reconcile(values, progress: { _ in }) { instructions, input, _ in
            #expect(instructions.contains("same person"))
            #expect(input.contains("Thursday"))
            #expect(input.contains("Wednesday"))
            return "{\"superseded\":[{\"record\":\"R1\",\"by\":\"R3\"}]}"
        }
        #expect(result.passes == 1)
        #expect(result.records.map { $0.0.text } == [values[1].0.text, values[2].0.text])
    }

    @Test("A withdrawn task is removed without creating a replacement or removing another task")
    func withdrawalAndUnrelatedTask() async throws {
        let values = [
            item(.action, "Prepare an interview script.", line: 0, owner: "Camille"),
            item(.action, "Send the financial report.", line: 1, owner: "Camille"),
            item(.correction, "I withdraw my commitment to prepare the interview script.", line: 12, owner: "Camille"),
        ]
        let result = try await StructuredSummaryPipeline.reconcile(values, progress: { _ in }) { _, _, _ in
            "{\"superseded\":[{\"record\":\"R1\",\"by\":\"R3\"}]}"
        }
        #expect(result.records.filter { $0.0.type == .action }.map { $0.0.text } == ["Send the financial report."])
        #expect(result.records.contains { $0.0.type == .correction })
    }

    @Test("A conditional proposal cannot trigger supersession")
    func conditionalProposal() async throws {
        let values = [
            item(.decision, "Launch in June.", line: 1),
            item(.proposal, "If approval arrives, we could move the launch to May.", line: 5),
        ]
        let result = try await StructuredSummaryPipeline.reconcile(values, progress: { _ in }) { _, _, _ in
            Issue.record("A proposal must not start a correction reconciliation pass")
            return "{\"superseded\":[]}"
        }
        #expect(result.records.count == 2)
        #expect(result.passes == 0)
    }

    @Test("Unknown IDs, earlier corrections and same-passage replacements fail closed")
    func invalidSupersession() {
        let old = item(.action, "Send the report.", line: 5, owner: "Amir")
        let change = item(.correction, "I withdraw that commitment.", line: 4, owner: "Amir")
        let earlier = [StructuredSummaryPipeline.LedgerEntry(id: "R1", record: old.0, source: old.1)]
        var corrections = [StructuredSummaryPipeline.LedgerEntry(id: "R2", record: change.0, source: change.1)]
        for operation in [
            StructuredSummaryPipeline.Supersession(record: "R999", by: "R2"),
            .init(record: "R1", by: "R999"),
            .init(record: "R1", by: "R2"),
        ] {
            #expect(throws: StructuredSummaryPipeline.ExtractionError.self) {
                try StructuredSummaryPipeline.validateSupersessions([operation], earlier: earlier, corrections: corrections)
            }
        }
        corrections[0].source.lineIndex = 5
        #expect(throws: StructuredSummaryPipeline.ExtractionError.self) {
            try StructuredSummaryPipeline.validateSupersessions([.init(record: "R1", by: "R2")], earlier: earlier, corrections: corrections)
        }
    }

    @Test("Reconciliation is ID-only and incomplete output is never applied")
    func strictReconciliationOutput() {
        for text in ["{\"superseded\":[", "The old plan is cancelled.", "{\"superseded\":[{\"record\":\"R1\"}]}"] {
            #expect(throws: StructuredSummaryPipeline.ExtractionError.self) { try StructuredSummaryPipeline.decodeReconciliation(text) }
        }
    }

    @Test("Every earlier record is considered against every later correction batch")
    func fullBatchCoverage() async throws {
        var values: [(StructuredSummaryPipeline.Record, SummaryEvidenceSource)] = []
        for index in 0..<12 {
            values.append(item(.action, "Prepare report \(index). " + String(repeating: "Context detail. ", count: 15), line: index, owner: "Camille"))
        }
        for index in 0..<10 {
            values.append(item(.correction, "I withdraw report \(index). " + String(repeating: "Explicit correction. ", count: 15), line: index + 30))
        }
        var pairs = Set<String>()
        let result = try await StructuredSummaryPipeline.reconcile(values, progress: { _ in }) { _, input, _ in
            let object = try #require(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
            let earlier = try #require(object["earlier"] as? [[String: Any]])
            let changes = try #require(object["corrections"] as? [[String: Any]])
            for old in earlier {
                for change in changes {
                    let oldID = try #require(old["id"] as? String)
                    let newID = try #require(change["id"] as? String)
                    pairs.insert(oldID + ":" + newID)
                }
            }
            return "{\"superseded\":[]}"
        }
        #expect(result.passes > 1)
        #expect(pairs.count == 12 * 10)
        #expect(result.records.count == values.count)
    }
}
