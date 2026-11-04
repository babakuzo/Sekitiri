import Foundation

/// The single transcript model used by every transcript view.
///
/// Sources, in order of preference:
/// 1. `transcript.json` written by the pipeline (timestamps, speakers and
///    optional per-word confidence),
/// 2. the Markdown rendering (`**[mm:ss] Speaker:** text`, `[h:mm:ss]`, and
///    the legacy `[Speaker N]` header layout),
/// 3. plain paragraphs.
///
/// Parsing never drops text: lines that match no known layout are kept as
/// paragraphs. Segment ids are their index, so they are stable across reloads
/// and safe to use as scroll targets. Parse once when a transcript loads.
struct TranscriptDocument: Equatable, Sendable {
    struct Segment: Identifiable, Equatable, Sendable {
        let id: Int
        /// Raw label as written by the pipeline ("me", "them", "Speaker 1").
        /// Nil for a paragraph without a speaker.
        let speaker: String?
        let start: TimeInterval?
        let end: TimeInterval?
        let text: String
        /// Ranges of `text` covered by words with confidence below 0.5.
        let lowConfidenceRanges: [Range<String.Index>]

        var hasLowConfidence: Bool { !lowConfidenceRanges.isEmpty }
    }

    enum Format: Equatable, Sendable { case json, markdown, plain }

    var segments: [Segment]
    /// Notices written into the transcript (for example "Incomplete transcript").
    var notices: [String]
    var format: Format
    /// Folder the transcript was read from. Speaker names live beside it.
    var directory: URL?

    static let empty = TranscriptDocument(segments: [], notices: [], format: .plain, directory: nil)

    var isEmpty: Bool { segments.isEmpty }

    /// Plain text for the clipboard or export, using display names.
    func plainText(names: SpeakerNames) -> String {
        segments.map { segment in
            var prefix = ""
            if let start = segment.start { prefix += "[\(Self.clock(start))] " }
            if let speaker = segment.speaker { prefix += "\(names.display(speaker)): " }
            return prefix + segment.text
        }
        .joined(separator: "\n\n")
    }

    /// Index of the segment playing at `time`, if any.
    func segmentID(at time: TimeInterval) -> Int? {
        var low = 0, high = segments.count - 1, result: Int?
        while low <= high {
            let mid = (low + high) / 2
            guard let start = segments[mid].start else {
                // Untimed paragraphs can't be located; fall back to a scan.
                return segments.last(where: { ($0.start ?? .infinity) <= time })?.id
            }
            if start <= time { result = segments[mid].id; low = mid + 1 } else { high = mid - 1 }
        }
        return result
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Loading

extension TranscriptDocument {
    /// Loads the best transcript for a meeting.
    ///
    /// - Parameters:
    ///   - session: the capture folder under the recordings root, if known.
    ///     Modern sessions (with `transcription-settings.json`) hold the
    ///     authoritative transcript.
    ///   - vaultFolder: the copied meeting folder in the notes vault, used
    ///     when the session folder is gone or predates the current pipeline.
    static func load(session: URL?, vaultFolder: URL?) -> TranscriptDocument? {
        let fm = FileManager.default
        let existingSession = session.flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil }
        let modern = existingSession.map {
            fm.fileExists(atPath: $0.appendingPathComponent("transcription-settings.json").path)
        } ?? false
        var directories: [URL] = modern
            ? [existingSession, vaultFolder].compactMap { $0 }
            : [vaultFolder, existingSession].compactMap { $0 }
        directories = directories.reduce(into: []) { result, url in
            if !result.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) { result.append(url) }
        }
        for directory in directories {
            if let document = load(in: directory, preferDiarizedMarkdown: !modern) { return document }
        }
        return nil
    }

    /// Loads a transcript from one folder.
    static func load(in directory: URL, preferDiarizedMarkdown: Bool = false) -> TranscriptDocument? {
        let fm = FileManager.default
        let diarized = directory.appendingPathComponent("transcript.diarized.md")
        if preferDiarizedMarkdown, fm.fileExists(atPath: diarized.path),
           let text = try? String(contentsOf: diarized, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var document = parseMarkdown(text)
            document.directory = directory
            return document
        }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("transcript.json")),
           var document = parseJSON(data), !document.isEmpty {
            document.directory = directory
            return document
        }
        if let text = try? String(contentsOf: directory.appendingPathComponent("transcript.md"), encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var document = parseMarkdown(text)
            document.directory = directory
            return document
        }
        return nil
    }
}

// MARK: - JSON

extension TranscriptDocument {
    private struct JSONTranscript: Decodable {
        struct Word: Decodable {
            let text: String
            let confidence: Float?
        }
        struct Segment: Decodable {
            let speaker: String
            let start_ms: Int
            let end_ms: Int
            let text: String
            let words: [Word]?
        }
        let segments: [Segment]
        let issues: [String]?
    }

    static func parseJSON(_ data: Data) -> TranscriptDocument? {
        guard let transcript = try? JSONDecoder().decode(JSONTranscript.self, from: data) else { return nil }
        let segments = transcript.segments.enumerated().map { index, segment in
            Segment(
                id: index,
                speaker: segment.speaker,
                start: TimeInterval(segment.start_ms) / 1000,
                end: TimeInterval(segment.end_ms) / 1000,
                text: segment.text,
                lowConfidenceRanges: lowConfidenceRanges(in: segment.text, words: segment.words ?? [])
            )
        }
        return TranscriptDocument(segments: segments, notices: transcript.issues ?? [], format: .json, directory: nil)
    }

    /// Maps word confidences onto the segment text without changing it. Words
    /// are matched in order; a word that can't be located is skipped.
    private static func lowConfidenceRanges(in text: String, words: [JSONTranscript.Word]) -> [Range<String.Index>] {
        guard words.contains(where: { ($0.confidence ?? 1) < 0.5 }) else { return [] }
        var ranges: [Range<String.Index>] = []
        var cursor = text.startIndex
        for word in words {
            let token = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty, cursor < text.endIndex,
                  let range = text.range(of: token, options: [.caseInsensitive], range: cursor..<text.endIndex)
            else { continue }
            if let confidence = word.confidence, confidence < 0.5 { ranges.append(range) }
            cursor = range.upperBound
        }
        return ranges
    }
}

// MARK: - Markdown

extension TranscriptDocument {
    // `**[1:02] Speaker:** text` or `[1:02:03] Speaker: text`
    private static let timedLine = try! NSRegularExpression(
        pattern: #"^\*{0,2}\[(\d{1,2}:\d{2}(?::\d{2})?)\]\s*([^:\n]+?):\*{0,2}\s*(.*)$"#
    )
    // `[Speaker 1]` or `**[Speaker 1]**` on its own line (legacy diarized layout)
    private static let speakerHeader = try! NSRegularExpression(pattern: #"^\*{0,2}\[([^\]]+)\]\*{0,2}$"#)

    static func parseMarkdown(_ raw: String) -> TranscriptDocument {
        var segments: [Segment] = []
        var notices: [String] = []
        var headerSpeaker: String?
        var paragraph: [String] = []
        var continuingTimedSegment = false
        var sawContent = false

        func append(speaker: String?, start: TimeInterval?, text: String) {
            segments.append(Segment(id: segments.count, speaker: speaker, start: start, end: nil,
                                    text: text, lowConfidenceRanges: []))
        }
        func flushParagraph() {
            let text = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            paragraph = []
            if !text.isEmpty { append(speaker: headerSpeaker, start: nil, text: text) }
        }

        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let nsRange = NSRange(trimmed.startIndex..., in: trimmed)

            if trimmed.isEmpty {
                flushParagraph()
                continuingTimedSegment = false
                continue
            }
            // Metadata the pipeline writes above the first segment.
            if !sawContent, trimmed.hasPrefix("# ") || trimmed.hasPrefix("engine:") { continue }
            if trimmed.hasPrefix(">") {
                let notice = trimmed.drop(while: { $0 == ">" || $0 == " " })
                    .replacingOccurrences(of: "**", with: "")
                if !notice.isEmpty { notices.append(notice) }
                continue
            }
            sawContent = true

            if let match = timedLine.firstMatch(in: trimmed, range: nsRange),
               let time = Range(match.range(at: 1), in: trimmed),
               let speaker = Range(match.range(at: 2), in: trimmed),
               let text = Range(match.range(at: 3), in: trimmed) {
                flushParagraph()
                append(speaker: String(trimmed[speaker]).trimmingCharacters(in: .whitespaces),
                       start: seconds(from: String(trimmed[time])),
                       text: String(trimmed[text]))
                continuingTimedSegment = true
                continue
            }
            if let match = speakerHeader.firstMatch(in: trimmed, range: nsRange),
               let label = Range(match.range(at: 1), in: trimmed),
               seconds(from: String(trimmed[label])) == nil {
                flushParagraph()
                headerSpeaker = String(trimmed[label]).trimmingCharacters(in: .whitespaces)
                continuingTimedSegment = false
                continue
            }
            if continuingTimedSegment, let last = segments.popLast() {
                // A wrapped line that belongs to the previous timed segment.
                segments.append(Segment(id: last.id, speaker: last.speaker, start: last.start, end: last.end,
                                        text: last.text + " " + trimmed, lowConfidenceRanges: []))
                continue
            }
            paragraph.append(trimmed)
        }
        flushParagraph()
        let hasTimes = segments.contains { $0.start != nil }
        return TranscriptDocument(segments: segments, notices: notices,
                                  format: hasTimes || segments.contains { $0.speaker != nil } ? .markdown : .plain,
                                  directory: nil)
    }

    /// "m:ss" or "h:mm:ss" → seconds.
    static func seconds(from clock: String) -> TimeInterval? {
        let parts = clock.split(separator: ":").map { Int($0) }
        guard parts.count == 2 || parts.count == 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        let values = parts.compactMap { $0 }
        return values.count == 3
            ? TimeInterval(values[0] * 3600 + values[1] * 60 + values[2])
            : TimeInterval(values[0] * 60 + values[1])
    }
}

// MARK: - Speaker names

/// User-chosen display names stored in a `speakers.json` sidecar next to the
/// transcript (`{"Speaker 1": "Alice", "them": "Acme team"}`). Transcript
/// files are never rewritten.
struct SpeakerNames: Equatable, Sendable {
    static let filename = "speakers.json"
    var names: [String: String] = [:]

    func display(_ raw: String) -> String {
        if let name = names[raw]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        let fallback = Self.defaultName(raw)
        if let name = names[fallback]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        return fallback
    }

    static func defaultName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "me": return "You"
        case "them": return "Others"
        default: return raw
        }
    }

    static func load(from directory: URL?) -> SpeakerNames {
        guard let directory,
              let data = try? Data(contentsOf: directory.appendingPathComponent(filename)),
              let names = try? JSONDecoder().decode([String: String].self, from: data) else { return SpeakerNames() }
        return SpeakerNames(names: names)
    }

    func save(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let cleaned = names.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        try encoder.encode(cleaned).write(to: directory.appendingPathComponent(Self.filename), options: .atomic)
    }
}
