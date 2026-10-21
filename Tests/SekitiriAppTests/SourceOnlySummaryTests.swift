import Foundation
import Testing
@testable import SekitiriApp

@Suite("Lightweight source notes")
struct SourceOnlySummaryTests {
    @Test("Source-only notes never invoke a language model")
    func noGeneration() async throws {
        var calls = 0
        let result = try await SourceSelectionSummary.run(
            transcript: "**[0:01] Maya:** We decided to retain the existing plan. I will send the report before Friday.",
            modelID: "source-notes", tone: "Concise", maxCharacters: 4_000,
            sourceOnly: true, progress: { _ in }
        ) { _, _, _ in
            calls += 1
            Issue.record("Source-only notes must not load or invoke a model")
            return "invalid JSON"
        }
        #expect(calls == 0)
        #expect(result.passCount == 0)
        #expect(result.document.modelID == "source-notes")
        #expect(result.document.sections.decisions.count == 1)
        #expect(result.document.actionItems.count == 1)
    }

    @Test("Context is capped, deduplicated, salient and displayed in chronological order")
    func boundedContext() {
        let quotes = ["Good morning everyone.", "Can you hear me?", "Please unmute your microphone."]
            + (1...12).map { "Battery degradation measurement phase \($0) indicates steady performance." }
            + ["Battery degradation measurement phase 1 indicates steady performance.", "The distant planet Neptune has unusual atmospheric properties."]
        let sources = quotes.enumerated().map { index, quote in
            StructuredSummaryPipeline.LabeledSource(label: "S\(index + 1)", evidence: .init(id: "original-\(index)", lineIndex: index, timestampSeconds: index, timestampText: "00:00", speaker: "Maya", quote: quote))
        }
        let result = SourceSelectionSummary.sourceContext(from: sources, excluding: [])
        #expect(result.count == 8)
        #expect(Set(result.map { $0.0.quote }).count == 8)
        #expect(result.allSatisfy { $0.0.quote.contains("Battery degradation") })
        #expect(result.map { $0.1.lineIndex } == result.map { $0.1.lineIndex }.sorted())
        #expect(result.allSatisfy { $0.0.type == .fact && $0.0.owner == nil && $0.0.due == nil })
    }

    @Test("Large transcripts cap supplementary context without dropping a late commitment")
    func lateCoreSurvivesContextCap() async throws {
        let background = (1...1_000).map { "**[0:\($0)] Maya:** Observation \($0) documents water coverage and soil conditions across the assessment area." }
        let transcript = (background + ["**[20:00] Maya:** I will send the critical report before Friday."]).joined(separator: "\n")
        let result = try await SourceSelectionSummary.run(
            transcript: transcript, modelID: "source-notes", tone: "Concise", maxCharacters: 50,
            sourceOnly: true, progress: { _ in }
        ) { _, _, _ in
            Issue.record("Source-only processing cannot require a token window or a model")
            return "invalid JSON"
        }
        #expect(result.document.actionItems.count == 1)
        #expect(result.document.actionItems[0].text.contains("critical report"))
        #expect(result.document.actionItems[0].dueDateText == "before Friday")
        let context = (result.document.sections.atAGlance + result.document.sections.keyPoints).filter { $0.text.hasPrefix("Observation") }
        #expect(context.count <= 8)
        #expect(context.count == 8)
        #expect(result.document.sources.count == 1_001)
        #expect(result.passCount == 0)
    }

    @Test("Source-only notes preserve the conservative correction review policy")
    func correctionReviewWithoutModel() async throws {
        let result = try await SourceSelectionSummary.run(
            transcript: "**[0:01] Maya:** I will prepare recruitment questions before Friday.\n**[0:20] Maya:** My earlier commitment to prepare recruitment questions is withdrawn.",
            modelID: "source-notes", tone: "Concise", maxCharacters: 4_000,
            sourceOnly: true, progress: { _ in }
        ) { _, _, _ in
            Issue.record("Corrections must not invoke a model in source-only mode")
            return "invalid JSON"
        }
        #expect(result.document.modelID == "source-notes+source-draft")
        #expect(result.document.actionItems.isEmpty)
        #expect(result.document.sections.openQuestionsAndRisks.count == 2)
        #expect(result.passCount == 0)
    }
}
