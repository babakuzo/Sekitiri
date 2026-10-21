import Foundation
import Testing
@testable import SekitiriApp

@Suite("Local summary baseline")
struct SummaryPipelineTests {
    @Test("Lightweight source notes are the default while saved model choices remain explicit")
    func modelCatalogue() {
        #expect(ModelItem.builtIns.map(\.id) == ["source-notes", "afm", "qwen3.5-2b"])
        #expect(!ModelItem.sourceNotes.requiresDownload)
        #expect(ModelItem.initialSelection(savedID: nil) == .sourceNotes)
        #expect(ModelItem.initialSelection(savedID: "unknown") == .sourceNotes)
        #expect(ModelItem.initialSelection(savedID: "afm") == .appleIntelligence)
        #expect(ModelItem.initialSelection(savedID: "qwen3.5-2b") == .qwen35)
        #expect(ModelItem.qwen35.requiresDownload)
        #expect(!ModelItem.appleIntelligence.requiresDownload)
    }

    @Test("Transcript preprocessing removes file metadata but preserves evidence")
    func preprocessing() throws {
        let fixture = try fixtureText("short-meeting.md")
        let prepared = SummaryInput.prepare("# Transcript\nengine: parakeet-v3\n\n" + fixture)
        #expect(!prepared.contains("engine: parakeet-v3"))
        #expect(prepared.contains("Maya"))
        #expect(prepared.contains("18 September"))
    }

    @Test("High-confidence cross-track duplicates are removed")
    func duplicatePreprocessing() {
        let raw = """
        **[0:10] Speaker 0:** We will prepare the release checklist before Friday morning.
        **[0:11] me:** We will prepare the release checklist before Friday morning.
        **[0:12] Speaker 1:** I will own the separate legal review.
        """
        let prepared = SummaryInput.prepare(raw)
        #expect(prepared.components(separatedBy: "release checklist").count - 1 == 1)
        #expect(prepared.contains("separate legal review"))
    }

    @Test("Required headings must be complete and ordered")
    func headingValidation() {
        let valid = SummaryTonePrompts.requiredHeadings
            .map { "\($0)\n_(none)_" }
            .joined(separator: "\n\n")
        #expect(SummaryInput.hasRequiredHeadings(valid))
        #expect(!SummaryInput.hasRequiredHeadings(valid.replacingOccurrences(of: "## Decisions", with: "## What we discussed")))
        #expect(!SummaryInput.hasRequiredHeadings(String(valid.reversed())))
    }

    @Test("Model heading drift is canonicalised before repair")
    func headingCanonicalisation() {
        let drifted = """
        # Overview
        - The release is targeted for Friday.
        ### Outcomes
        - The team chose the staged rollout.
        ## Next steps
        - [ ] Maya — prepare the checklist
        ## Key takeaways
        - Legal review remains open.
        ## Questions & Risks
        - Dependency on legal approval.
        ## Conclusion
        - The team aligned on a staged release.
        """
        let canonical = SummaryInput.canonicalizeSummary(drifted)
        #expect(SummaryInput.hasRequiredHeadings(canonical))
        #expect(canonical.contains("## At a glance"))
        #expect(canonical.contains("## Open Questions and Risks"))
    }

    @Test("Saved legacy prompts receive the current output contract")
    func legacyPromptContract() {
        let prompt = SummaryTonePrompts.inferencePrompt(userPrompt: "Write polished notes. Format the notes with ## Key Takeaway and ## Open Questions.", tone: "Concise")
        #expect(!prompt.contains("## Key Takeaway"))
        #expect(prompt.contains("## At a glance"))
        #expect(prompt.contains("## Open Questions and Risks"))
        #expect(prompt.contains("Do not use alternate heading names"))
        #expect(prompt.contains("highest priority"))
        #expect(prompt.contains("style guidance only"))
    }

    @Test("Malformed model output is saved with deterministic empty sections")
    func recoveryFormatter() {
        let recovered = SummaryInput.recoverSummaryStructure("The meeting covered a possible Wednesday change.")
        #expect(SummaryInput.hasRequiredHeadings(recovered))
        #expect(recovered.contains("possible Wednesday change"))
        #expect(recovered.contains("## Decisions\n_(none)_"))
        #expect(!recovered.contains("## Summary\n_(none)_"))
    }

    @Test("Final formatter removes cut-off bullets and bullet-shaped summaries")
    func finalFormatter() {
        let malformed = """
        ## At a glance
        - The team reviewed the launch plan.
        - A second glance item that should not survive.
        ## Decisions
        - Keep the Friday launch.
        ## Action Items
        - [ ] Maya — send the checklist.
        ## Key Points
        - The legal review remains open.
        - The unfinished point ends with the
        ## Open Questions and Risks
        - Confirm the final approval.
        ## Summary
        - The team reviewed the launch plan. - Maya will send the checklist.
        """
        let final = SummaryInput.finalizeSummary(malformed, tone: "Concise")
        #expect(final.contains("## At a glance\nThe team reviewed the launch plan."))
        #expect(!final.contains("second glance item"))
        #expect(!final.contains("unfinished point"))
        #expect(final.contains("## Summary\nThe team reviewed the launch plan. Maya will send the checklist."))
        #expect(SummaryInput.hasRequiredHeadings(final))
    }

    @Test("Distinct bilingual lines are not treated as duplicates")
    func preservesDistinctLanguageEvidence() {
        let raw = """
        **[0:10] Speaker 0:** We will send the signed contract by Friday.
        **[0:11] Speaker 1:** Nous enverrons le contrat signé vendredi.
        """
        let prepared = SummaryInput.prepare(raw)
        #expect(prepared.contains("signed contract"))
        #expect(prepared.contains("contrat signé"))
    }

    @Test("Every sanitized benchmark has a complete expected-facts checklist")
    func fixtureChecklists() throws {
        let data = try fixtureData("expected-facts.json")
        let checklists = try JSONDecoder().decode([String: ExpectedFacts].self, from: data)
        #expect(Set(checklists.keys) == ["short-meeting", "noisy-diarized-meeting", "representative-one-hour-meeting"])
        for facts in checklists.values {
            #expect(!facts.decisions.isEmpty)
            #expect(!facts.owners.isEmpty)
            #expect(!facts.dates.isEmpty)
            #expect(!facts.actionItems.isEmpty)
            #expect(!facts.risks.isEmpty)
            #expect(!facts.unsupportedClaims.isEmpty)
        }
    }

    @Test("Missing-model and insufficient-disk errors are actionable")
    func actionableErrors() {
        let missing = LocalSummaryRuntimeError.notDownloaded.localizedDescription
        let disk = LocalSummaryRuntimeError.insufficientDisk(required: 3_500_000_000, available: 1_000_000_000).localizedDescription
        #expect(missing.contains("Settings"))
        #expect(missing.contains("Download"))
        #expect(disk.contains("3.5 GB"))
        #expect(disk.contains("free"))
    }

    @Test("Opt-in Qwen smoke and warm real-transcript benchmark")
    func qwenBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SEKITIRI_RUN_MODEL_BENCHMARK"] == "1" else { return }

        try await LocalSummaryRuntime.shared.download { _ in }
        let engine = NativeMLXEngine()
        let prompt = SummaryTonePrompts.default(for: "Concise")
        let short = SummaryInput.prepare(try fixtureText("short-meeting.md"))
        let shortResult = try await engine.summarize(
            transcript: short,
            prompt: prompt,
            tone: "Concise",
            progress: { _ in }
        )
        #expect(SummaryInput.hasRequiredHeadings(shortResult.text))
        let shortSummary = shortResult.text.lowercased()
        for fact in ["paris", "leon", "18 september", "legal"] {
            #expect(shortSummary.contains(fact), "Short summary omitted expected fact: \(fact)")
        }

        guard let transcriptPath = environment["SEKITIRI_BENCHMARK_TRANSCRIPT"] else { return }
        let transcript = SummaryInput.prepare(try String(contentsOfFile: transcriptPath, encoding: .utf8))
        let clock = ContinuousClock()
        let started = clock.now
        let result = try await engine.summarize(
            transcript: transcript,
            prompt: SummaryTonePrompts.default(for: "Detailed"),
            tone: "Detailed",
            progress: { _ in }
        )
        let elapsed = started.duration(to: clock.now)
        #expect(elapsed < .seconds(90), "Warm 61 KB summary took \(elapsed)")
        #expect(result.passCount == 1, "Expected one normal generation pass, got \(result.passCount)")
        #expect(SummaryInput.hasRequiredHeadings(result.text))
    }

    private func fixtureText(_ name: String) throws -> String {
        String(decoding: try fixtureData(name), as: UTF8.self)
    }

    private func fixtureData(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }
}

private struct ExpectedFacts: Decodable {
    let decisions: [String]
    let owners: [String]
    let dates: [String]
    let actionItems: [String]
    let risks: [String]
    let unsupportedClaims: [String]
}
