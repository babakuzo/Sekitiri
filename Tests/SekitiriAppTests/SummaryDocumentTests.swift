import Foundation
import Testing
@testable import SekitiriApp

@Suite("Canonical summary records and rendering")
struct SummaryDocumentTests {
    private let transcript = "**[00:12] Léa:** Je préparerai le contrat vendredi.\n**[00:25] Sam:** I will send the release checklist tomorrow."
    private let markdown = """
    ## At a glance
    The team agreed on the next release.
    ## Decisions
    * **Schedule:** Keep the Friday release.
    + Confirm the contract first.
    ## Action Items
    * [ ] Léa — préparer le contrat vendredi.
    + [X] Sam — send the release checklist tomorrow.
    3. Check legal approval.
    ## Key Points
    1. **Legal:** Approval is pending.
    ## Open Questions and Risks
    _(none)_
    ## Summary
    The next steps are assigned.
    """

    @Test("Mixed bullet and checkbox forms become actions without inferred attribution")
    func variedMarkdown() {
        let document = CanonicalSummaryBuilder.build(markdown: markdown, transcript: transcript, modelID: "legacy", tone: "Detailed")
        #expect(document.actionItems.count == 3)
        #expect(document.actionItems.map(\.isCompleted) == [false, true, false])
        #expect(document.actionItems.allSatisfy { $0.owner == nil && $0.dueDateText == nil && $0.evidenceSourceIDs.isEmpty })
        #expect(document.sections.decisions.count == 2)
        #expect(document.sections.decisions.allSatisfy { $0.evidenceSourceIDs.isEmpty })
        #expect(SummaryParser.hasPendingActions(markdown))
        let sections = SummaryParser.parse(markdown)
        let decisions = sections.first { $0.title == "Decisions" }
        #expect(decisions?.items.count == 2)
        if case .bullet(let text)? = decisions?.items.first { #expect(text == "**Schedule:** Keep the Friday release.") }
        else { Issue.record("Star bullet was not recognized") }
        #expect(String(SummaryParser.inline("**Schedule:** Keep the release.").characters) == "Schedule: Keep the release.")
    }

    @Test("A legacy migration is nondestructive; edits synchronize JSON and Markdown")
    func persistenceRoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = "---\nid: test\nengine: afm\n---\n\n# Test meeting\n\n" + markdown
        let url = folder.appendingPathComponent("summary.md")
        try original.write(to: url, atomically: true, encoding: .utf8)
        var document = try SummaryDocumentStore.loadOrMigrate(from: folder, transcript: transcript)
        #expect(try String(contentsOf: url, encoding: .utf8) == original)
        document.actionItems[0].isCompleted = true
        try SummaryDocumentStore.save(document, to: folder)
        let restored = try #require(try SummaryDocumentStore.load(from: folder))
        #expect(restored.actionItems == document.actionItems)
        let exported = try String(contentsOf: url, encoding: .utf8)
        #expect(exported.hasPrefix("---\nid: test\nengine: afm\n---\n\n# Test meeting"))
        #expect(exported.contains("- [x] Léa"))
        let parsed = CanonicalSummaryBuilder.build(markdown: exported, transcript: transcript, modelID: "legacy", tone: "Detailed")
        #expect(parsed.actionItems.map(\.text) == restored.actionItems.map(\.text))
        #expect(parsed.actionItems.map(\.isCompleted) == restored.actionItems.map(\.isCompleted))
    }

    @Test("Regeneration preserves completed actions and rejects unknown source IDs")
    func reconcileRecords() throws {
        var previous = CanonicalSummaryBuilder.build(markdown: markdown, transcript: transcript, modelID: "test", tone: "Detailed")
        previous.actionItems[0].isCompleted = true
        var draft = previous
        draft.actionItems[0].id = "new-generated-id"
        draft.actionItems[0].isCompleted = false
        let source = try #require(draft.sources.first)
        draft.actionItems[0].evidenceSourceIDs = [source.id, "invented-source"]
        draft.sections.decisions[0].evidenceSourceIDs = ["invented-source"]
        let result = SummaryDocumentStore.replacement(document: draft, previous: previous)
        #expect(result.actionItems[0].id == previous.actionItems[0].id)
        #expect(result.actionItems[0].isCompleted)
        #expect(result.actionItems[0].evidenceSourceIDs == [source.id])
        #expect(result.sections.decisions[0].evidenceSourceIDs.isEmpty)
    }

    @Test("A stale action view cannot overwrite a newer generated summary")
    func staleActionSnapshot() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = CanonicalSummaryBuilder.build(markdown: markdown, transcript: transcript, modelID: "old", tone: "Detailed")
        try SummaryDocumentStore.save(original, to: folder)
        let staleActionID = try #require(original.actionItems.first?.id)
        var newer = original
        newer.modelID = "new"
        newer.sections.keyPoints = [SummaryClaim(id: "new-fact", text: "The new generation retains additional evidence.", evidenceSourceIDs: [])]
        try SummaryDocumentStore.commitReplacement(newer, to: folder, transcript: transcript, metadataPrefix: "---\nengine: new\n---\n\n# Meeting\n\n")
        let edited = try SummaryDocumentStore.toggleAction(id: staleActionID, in: folder, transcript: transcript)
        #expect(edited.modelID == "new")
        #expect(edited.sections.keyPoints.first?.id == "new-fact")
        #expect(edited.actionItems[0].isCompleted)
        #expect(try String(contentsOf: folder.appendingPathComponent("summary.md"), encoding: .utf8).contains("engine: new"))
        var nextDraft = newer
        nextDraft.actionItems[0].isCompleted = false
        let committed = try SummaryDocumentStore.commitReplacement(nextDraft, to: folder, transcript: transcript, metadataPrefix: "")
        #expect(committed.actionItems[0].isCompleted)
        #expect(throws: SummaryDocumentStore.StoreError.self) {
            try SummaryDocumentStore.toggleAction(id: "removed-action", in: folder, transcript: transcript)
        }
    }

    @Test("Changed transcript inputs reject a new summary without replacing saved notes")
    func changedSourceRejectsCommit() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = CanonicalSummaryBuilder.build(markdown: markdown, transcript: transcript, modelID: "old", tone: "Detailed")
        try SummaryDocumentStore.save(original, to: folder)
        var replacement = original
        replacement.modelID = "new"
        #expect(throws: SummaryDocumentStore.StoreError.self) {
            try SummaryDocumentStore.commitReplacement(replacement, to: folder, transcript: transcript, metadataPrefix: "", validateSource: {
                try SummaryDocumentStore.verifySourceSnapshot(expected: "original transcript", current: "edited transcript")
            })
        }
        #expect(try SummaryDocumentStore.load(from: folder)?.modelID == "old")
        #expect(try String(contentsOf: folder.appendingPathComponent("summary.md"), encoding: .utf8).contains("**Schedule:**"))
    }

    @Test("Changed deadlines do not inherit completion from a different commitment")
    func changedCommitment() {
        var previous = CanonicalSummaryBuilder.build(markdown: markdown, transcript: transcript, modelID: "test", tone: "Detailed")
        previous.actionItems = [CanonicalActionItem(id: "old", text: "Send the release checklist", owner: "Sam", dueDateText: "tomorrow", isCompleted: true, evidenceSourceIDs: [])]
        var draft = previous
        draft.actionItems = [CanonicalActionItem(id: "new", text: "Send the release checklist", owner: "Sam", dueDateText: "next month", isCompleted: false, evidenceSourceIDs: [])]
        let result = SummaryDocumentStore.replacement(document: draft, previous: previous)
        #expect(!result.actionItems[0].isCompleted)
        #expect(result.actionItems[0].id == "new")
    }

    @Test("Long bilingual source utterances remain bounded with distinct references")
    func longSourcePassages() {
        let quote = String(repeating: "Le contrat sera signé vendredi and the release remains planned. ", count: 150)
        let sources = CanonicalSummaryBuilder.evidenceSources(from: "**[01:15] Léa:** " + quote)
        #expect(sources.count > 1)
        #expect(sources.allSatisfy { $0.quote.count <= 1_800 && $0.lineIndex == 0 && $0.timestampSeconds == 75 && $0.speaker == "Léa" })
        #expect(Set(sources.map(\.id)).count == sources.count)
        #expect(sources.map(\.quote).joined(separator: " ") == quote.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test("Frontmatter is hidden while horizontal rules do not consume the rest of a summary")
    func frontmatter() {
        let sections = SummaryParser.parse("---\nengine: afm\n---\n# Meeting\n## Decisions\n* Keep Friday.\n---\n## Key Points\n+ Legal is pending.")
        #expect(sections.map(\.title) == ["Decisions", "Key Points"])
        #expect(sections.allSatisfy { $0.items.count == 1 })
    }
}
