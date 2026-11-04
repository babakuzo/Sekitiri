import Foundation

/// Removes microphone text that only repeats what the system track played at
/// the same moment: meeting audio from speakers picked up by the mic.
///
/// Deliberately conservative (screenpipe/OpenOats-style): a mic segment needs
/// at least four words, and at least 80% of them must appear in system speech
/// overlapping it in time. Removed text is returned, never discarded, so the
/// decision stays auditable in transcript.json.
enum EchoSuppression {
    static let minimumWords = 4
    static let containment = 0.8
    static let tolerance: TimeInterval = 1.0

    static func split(_ segments: [Transcript.Segment])
        -> (kept: [Transcript.Segment], suppressed: [Transcript.SuppressedSegment]) {
        let system = segments.filter { $0.speaker != "me" }
        guard !system.isEmpty else { return (segments, []) }
        var kept: [Transcript.Segment] = []
        var suppressed: [Transcript.SuppressedSegment] = []
        for segment in segments {
            guard segment.speaker == "me", isEcho(segment, system: system) else {
                kept.append(segment)
                continue
            }
            suppressed.append(.init(segment: segment, reason: "echo of system audio"))
        }
        return (kept, suppressed)
    }

    static func isEcho(_ mic: Transcript.Segment, system: [Transcript.Segment]) -> Bool {
        let micWords = tokens(mic.text)
        guard micWords.count >= minimumWords else { return false }
        let lower = mic.start_ms - Int(tolerance * 1000)
        let upper = mic.end_ms + Int(tolerance * 1000)
        var heard: [String: Int] = [:]
        for segment in system where segment.end_ms >= lower && segment.start_ms <= upper {
            if let words = segment.words, !words.isEmpty {
                for word in words where word.end_ms >= lower && word.start_ms <= upper {
                    for token in tokens(word.text) { heard[token, default: 0] += 1 }
                }
            } else {
                for token in tokens(segment.text) { heard[token, default: 0] += 1 }
            }
        }
        guard !heard.isEmpty else { return false }
        var matched = 0
        for token in micWords where (heard[token] ?? 0) > 0 {
            heard[token]! -= 1
            matched += 1
        }
        return Double(matched) / Double(micWords.count) >= containment
    }

    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}

/// Assigns diarized speakers word by word, splitting a transcript segment
/// wherever the speaker changes (the approach used by WhisperKit SpeakerKit
/// and Vibe). Segments without word timings fall back to the speaker with the
/// greatest overlap.
enum SpeakerAttribution {
    /// A word outside every span joins the nearest span within this distance;
    /// otherwise it continues the previous word's speaker.
    static let nearestTolerance: TimeInterval = 0.5

    static func assign(_ segment: Transcript.Segment, spans: [SpeakerSpan], offset: TimeInterval,
                       fallback: String) -> [Transcript.Segment] {
        guard !spans.isEmpty else { return [segment] }
        guard let words = segment.words, !words.isEmpty else {
            let start = Double(segment.start_ms) / 1000 - offset
            let end = Double(segment.end_ms) / 1000 - offset
            return [relabel(segment, as: overlapSpeaker(start: start, end: end, spans: spans) ?? fallback)]
        }
        var previous: String?
        var runs: [(speaker: String, words: [Transcript.Word])] = []
        for word in words {
            let middle = (Double(word.start_ms) + Double(word.end_ms)) / 2000 - offset
            let speaker = speakerAt(middle, spans: spans) ?? previous ?? fallback
            previous = speaker
            if let last = runs.last, last.speaker == speaker {
                runs[runs.count - 1].words.append(word)
            } else {
                runs.append((speaker, [word]))
            }
        }
        return runs.map { run in
            Transcript.Segment(speaker: run.speaker, start_ms: run.words.first!.start_ms,
                               end_ms: run.words.last!.end_ms,
                               text: run.words.map(\.text).joined(separator: " "), words: run.words)
        }
    }

    static func speakerAt(_ time: TimeInterval, spans: [SpeakerSpan]) -> String? {
        if let inside = spans.first(where: { $0.start <= time && time <= $0.end }) { return inside.speaker }
        let nearest = spans.min { distance(time, $0) < distance(time, $1) }
        return nearest.flatMap { distance(time, $0) <= nearestTolerance ? $0.speaker : nil }
    }

    private static func distance(_ time: TimeInterval, _ span: SpeakerSpan) -> TimeInterval {
        time < span.start ? span.start - time : max(0, time - span.end)
    }

    private static func overlapSpeaker(start: TimeInterval, end: TimeInterval, spans: [SpeakerSpan]) -> String? {
        let best = spans
            .map { ($0, max(0, min(end, $0.end) - max(start, $0.start))) }
            .max { $0.1 < $1.1 }
        return best.flatMap { $0.1 > 0 ? $0.0.speaker : nil }
    }

    private static func relabel(_ segment: Transcript.Segment, as speaker: String) -> Transcript.Segment {
        Transcript.Segment(speaker: speaker, start_ms: segment.start_ms, end_ms: segment.end_ms,
                           text: segment.text, words: segment.words)
    }
}
