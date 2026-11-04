import Foundation
import Testing
@testable import SekitiriApp

@Suite("Transcript document parsing")
struct TranscriptDocumentTests {
    @Test("Markdown keeps timed lines, h:mm:ss stamps and unmatched text")
    func markdownNeverDropsText() {
        let markdown = """
        # 2026.01.02-1030

        engine: parakeet (v3)

        > **Incomplete transcript — some recorded audio could not be verified.**

        **[0:05] me:** Hello there.

        **[1:02:03] Speaker 1:** Long meeting
        continues on a wrapped line.

        A stray paragraph without a speaker.
        """
        let document = TranscriptDocument.parseMarkdown(markdown)
        #expect(document.segments.map(\.text) == [
            "Hello there.",
            "Long meeting continues on a wrapped line.",
            "A stray paragraph without a speaker.",
        ])
        #expect(document.segments.map(\.id) == [0, 1, 2])
        #expect(document.segments[0].start == 5)
        #expect(document.segments[1].start == 3723)
        #expect(document.segments[1].speaker == "Speaker 1")
        #expect(document.segments[2].speaker == nil)
        #expect(document.notices.count == 1)
    }

    @Test("Legacy speaker headers attribute the following text")
    func legacySpeakerHeaders() {
        let document = TranscriptDocument.parseMarkdown("[Speaker 1]\nFirst thought.\n\n**[Speaker 2]**\nReply.")
        #expect(document.segments.map(\.speaker) == ["Speaker 1", "Speaker 2"])
        #expect(document.segments.map(\.text) == ["First thought.", "Reply."])
    }

    @Test("JSON segments map words with low confidence onto the text")
    func jsonLowConfidence() throws {
        let json = """
        {"engine":"parakeet","model":"v3","created_at":"x","segments":[
          {"speaker":"them","start_ms":1500,"end_ms":3000,"text":"Ship it Friday",
           "words":[{"text":"Ship","start_ms":1500,"end_ms":1700,"confidence":0.9},
                    {"text":"it","start_ms":1700,"end_ms":1800,"confidence":0.3},
                    {"text":"Friday","start_ms":1800,"end_ms":3000}]},
          {"speaker":"me","start_ms":4000,"end_ms":5000,"text":"Agreed."}
        ],"track_outcomes":[],"issues":[]}
        """
        let document = try #require(TranscriptDocument.parseJSON(Data(json.utf8)))
        #expect(document.segments.count == 2)
        let first = document.segments[0]
        #expect(first.start == 1.5)
        #expect(first.lowConfidenceRanges.map { String(first.text[$0]) } == ["it"])
        #expect(!document.segments[1].hasLowConfidence)
        #expect(document.segmentID(at: 4.2) == 1)
        #expect(document.segmentID(at: 0.5) == nil)
    }

    @Test("Speaker display names prefer the sidecar, then friendly defaults")
    func speakerNames() {
        var names = SpeakerNames()
        #expect(names.display("me") == "You")
        #expect(names.display("them") == "Others")
        names.names = ["Speaker 1": "Alice", "Others": "Acme"]
        #expect(names.display("Speaker 1") == "Alice")
        #expect(names.display("them") == "Acme")
    }
}
