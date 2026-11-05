import FluidAudio
import Foundation
import Testing
@testable import SekitiriApp

@Suite("Transcript quality")
struct TranscriptQualityTests {
    private let frame = Double(VadManager.chunkSize) / AudioWindowReader.sampleRate

    @Test("Windows end inside the longest pause after the minimum length")
    func pauseCutPrefersLongestPause() {
        // 0.256 s frames: speech, a short pause at ~7 s, a longer pause at ~10 s.
        var probabilities = [Float](repeating: 0.9, count: 50)
        for index in 27...28 { probabilities[index] = 0.1 }
        for index in 38...42 { probabilities[index] = 0.05 }
        let cut = ParakeetEngine.pauseCut(probabilities: probabilities, frameDuration: frame,
                                          from: 100, searchEnd: 100 + TranscriptionWindow.coreDuration)
        #expect(cut > 100 + 38 * frame && cut < 100 + 43 * frame)
    }

    @Test("Without any pause the window ends at the least speech-like frame")
    func pauseCutFallsBackToMinimum() {
        var probabilities = [Float](repeating: 0.95, count: 50)
        probabilities[30] = 0.6
        let cut = ParakeetEngine.pauseCut(probabilities: probabilities, frameDuration: frame,
                                          from: 0, searchEnd: TranscriptionWindow.coreDuration)
        #expect(abs(cut - 30.5 * frame) < 0.0001)
        #expect(cut >= TranscriptionWindow.minimumCore && cut <= TranscriptionWindow.coreDuration)
    }

    @Test("Pauses before the minimum core length are ignored")
    func pauseCutRespectsMinimum() {
        var probabilities = [Float](repeating: 0.9, count: 50)
        for index in 2...10 { probabilities[index] = 0.01 }
        let cut = ParakeetEngine.pauseCut(probabilities: probabilities, frameDuration: frame,
                                          from: 0, searchEnd: TranscriptionWindow.coreDuration)
        #expect(cut >= TranscriptionWindow.minimumCore)
    }

    @Test("Word confidence is the mean of its sub-word tokens")
    func wordConfidence() {
        let timings = [
            TokenTiming(token: "▁Bon", tokenId: 1, startTime: 0, endTime: 0.2, confidence: 0.9),
            TokenTiming(token: "jour", tokenId: 2, startTime: 0.2, endTime: 0.4, confidence: 0.5),
            TokenTiming(token: "▁Maya.", tokenId: 3, startTime: 0.5, endTime: 0.8, confidence: 0.3),
        ]
        let words = ParakeetEngine.words(from: timings)
        #expect(words.map(\.text) == ["Bonjour", "Maya."])
        #expect(abs((words[0].confidence ?? 0) - 0.7) < 0.0001)
        #expect(words[0].start == 0 && words[0].end == 0.4)
        let segments = ParakeetEngine.segments(from: words)
        #expect(segments.count == 1)
        #expect(segments[0].words?.count == 2)
    }

    @Test("Microphone text repeating simultaneous system audio is suppressed")
    func echoSuppressed() {
        let them = Transcript.Segment(speaker: "them", start_ms: 10_000, end_ms: 13_000,
                                      text: "We should ship the budget review on Friday.")
        let echo = Transcript.Segment(speaker: "me", start_ms: 10_150, end_ms: 13_100,
                                      text: "we should ship the budget review on friday")
        let reply = Transcript.Segment(speaker: "me", start_ms: 13_500, end_ms: 15_000,
                                       text: "Friday works for me, I'll send the review.")
        let result = EchoSuppression.split([them, echo, reply])
        #expect(result.kept.map(\.text) == [them.text, reply.text])
        #expect(result.suppressed.count == 1)
    }

    @Test("Short or distant repeats are never suppressed")
    func echoKeepsUserSpeech() {
        let them = Transcript.Segment(speaker: "them", start_ms: 0, end_ms: 2_000, text: "Sounds good to me.")
        let shortAgreement = Transcript.Segment(speaker: "me", start_ms: 100, end_ms: 900, text: "Sounds good.")
        let laterRepeat = Transcript.Segment(speaker: "me", start_ms: 9_000, end_ms: 11_000,
                                             text: "Sounds good to me.")
        #expect(EchoSuppression.split([them, shortAgreement, laterRepeat]).suppressed.isEmpty)
    }

    @Test("Diarized speakers are assigned per word and split segments")
    func speakerAttributionSplits() {
        let words = [
            Transcript.Word(text: "Hello", start_ms: 1_000, end_ms: 1_300),
            Transcript.Word(text: "there.", start_ms: 1_300, end_ms: 1_600),
            Transcript.Word(text: "Hi", start_ms: 2_100, end_ms: 2_300),
            Transcript.Word(text: "Sam.", start_ms: 2_300, end_ms: 2_600),
        ]
        let segment = Transcript.Segment(speaker: "them", start_ms: 1_000, end_ms: 2_600,
                                         text: "Hello there. Hi Sam.", words: words)
        let spans = [
            SpeakerSpan(speaker: "Speaker 1", start: 0.4, end: 1.3),
            SpeakerSpan(speaker: "Speaker 2", start: 1.5, end: 2.5),
        ]
        // Track offset of 0.5 s: transcript time 1.0 s is track time 0.5 s.
        let result = SpeakerAttribution.assign(segment, spans: spans, offset: 0.5, fallback: "them")
        #expect(result.map(\.speaker) == ["Speaker 1", "Speaker 2"])
        #expect(result.map(\.text) == ["Hello there.", "Hi Sam."])
        #expect(result[1].start_ms == 2_100)
    }

    @Test("Transcript JSON keeps words and stays readable without them")
    func transcriptSchema() throws {
        let segment = Transcript.Segment(speaker: "me", start_ms: 0, end_ms: 500, text: "Oui.",
                                         words: [Transcript.Word(text: "Oui.", start_ms: 0, end_ms: 500, confidence: 0.4)])
        let transcript = Transcript(engine: "parakeet-ultra", model: "m", created_at: "t", segments: [segment])
        let decoded = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(transcript))
        #expect(decoded.segments[0].words?.first?.confidence == 0.4)
        let legacy = #"{"engine":"e","model":"m","created_at":"t","segments":[{"speaker":"me","start_ms":0,"end_ms":1,"text":"Hi"}]}"#
        let old = try JSONDecoder().decode(Transcript.self, from: Data(legacy.utf8))
        #expect(old.segments[0].words == nil)
        #expect(old.suppressedSegments.isEmpty)
    }

    @Test("Vocabulary replacements keep word timing and punctuation")
    func vocabularyReplacement() throws {
        let words = [
            TranscriptWord(text: "in", start: 0, end: 0.2, confidence: 0.6),
            TranscriptWord(text: "video", start: 0.2, end: 0.5, confidence: 0.4),
            TranscriptWord(text: "shipped.", start: 0.6, end: 0.9, confidence: 0.9),
        ]
        // The library's memberwise initializer is internal; results are Codable.
        let json = #"{"originalWord":"in video","originalScore":-9,"replacementWord":"NVIDIA","replacementScore":-2,"shouldReplace":true,"reason":"test"}"#
        let replacement = try JSONDecoder().decode(VocabularyRescorer.RescoringResult.self, from: Data(json.utf8))
        let output = ParakeetEngine.applying([replacement], to: words)
        #expect(output.map(\.text) == ["NVIDIA", "shipped."])
        #expect(output[0].start == 0 && output[0].end == 0.5)
    }

    @Test("A replacement that no longer fits after an earlier one is skipped, not a crash")
    func vocabularyReplacementPastEnd() throws {
        let words = ["the", "nvidia", "cards"].enumerated().map {
            TranscriptWord(text: $1, start: Double($0), end: Double($0) + 0.5, confidence: 0.9)
        }
        func result(_ original: String, _ replacement: String) throws -> VocabularyRescorer.RescoringResult {
            let json = #"{"originalWord":"\#(original)","originalScore":-9,"replacementWord":"\#(replacement)","replacementScore":-2,"shouldReplace":true,"reason":"test"}"#
            return try JSONDecoder().decode(VocabularyRescorer.RescoringResult.self, from: Data(json.utf8))
        }
        // After "nvidia" (index 1), only one word remains for a two-word match.
        let output = ParakeetEngine.applying([try result("nvidia", "NVIDIA"), try result("cards are", "Cardsare")], to: words)
        #expect(output.map(\.text) == ["the", "NVIDIA", "cards"])
    }

    @Test("Vocabulary combines glossary and attendee names without emails")
    func vocabularyTerms() {
        let terms = Config.transcriptionVocabulary(attendees: ["Ada Lovelace", "ops@example.com", "Al"])
        #expect(terms.contains("Ada Lovelace"))
        #expect(terms.contains("Lovelace"))
        #expect(!terms.contains { $0.contains("@") })
        #expect(!terms.contains("Al"))
    }
}
