import Foundation
import Testing
@testable import SekitiriApp

@Suite("Notes require verified source transcripts")
struct MeetingNotesIntegrityTests {
    @Test("Partial and mismatched transcripts are rejected before model selection")
    func incompleteTranscriptCannotSummarize() async throws {
        for capturedIssue in [true, false] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try JSONSerialization.data(withJSONObject: ["files": ["mic": "mic.caf"]])
                .write(to: directory.appendingPathComponent("meta.json"))
            let value = Transcript(engine: "test", model: "test", created_at: "now",
                                   segments: [.init(speaker: "me", start_ms: 0, end_ms: 900, text: "Send the draft.")],
                                   trackOutcomes: [.init(file: "mic.caf", status: .complete, segmentCount: 1)],
                                   issues: capturedIssue ? ["Some recording audio was lost."] : [])
            try value.write(to: directory)
            if !capturedIssue {
                try Data("a truncated transcript".utf8).write(to: directory.appendingPathComponent("transcript.md"))
            }
            do {
                // An invalid engine is deliberate: this test can never load
                // weights or contact a model service if the guard regresses.
                try await MeetingNotesService.summarize(session: directory, engine: "unavailable-test-engine")
                Issue.record("Incomplete source unexpectedly reached notes generation.")
            } catch {
                #expect(error.localizedDescription.contains("A complete transcript is required"))
            }
        }
    }
}
