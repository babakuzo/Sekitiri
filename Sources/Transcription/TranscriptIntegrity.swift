import CryptoKit
import CoreFoundation
import Foundation

/// Validated capture manifest shared by transcription and recovery.
struct SessionMeta {
    struct Track: Sendable {
        let file: String
        let speaker: String
        let offsetMs: Int
    }

    let tracks: [Track]
    let issues: [String]

    enum MetaError: Error, CustomStringConvertible {
        case unreadable(URL)
        case invalid(String)

        var description: String {
            switch self {
            case .unreadable(let url): return "Could not read capture metadata at \(url.path)."
            case .invalid(let message): return "Invalid capture metadata: \(message)"
            }
        }
    }

    static func read(from directory: URL) throws -> SessionMeta {
        let url = directory.appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = json["files"] as? [String: String]
        else { throw MetaError.unreadable(url) }
        guard !files.isEmpty, Set(files.keys).isSubset(of: ["mic", "system"]) else {
            throw MetaError.invalid("No supported audio tracks were declared.")
        }
        var offsets: [String: Int] = [:]
        if let raw = json["start_offset_ms"] {
            guard let values = raw as? [String: Any] else { throw MetaError.invalid("Track offsets must be integers.") }
            for (key, value) in values {
                guard let number = value as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite,
                      number.doubleValue >= 0, number.doubleValue <= Double(Int.max / 2),
                      number.doubleValue.rounded() == number.doubleValue
                else { throw MetaError.invalid("Invalid start offset for \(key).") }
                offsets[key] = number.intValue
            }
        }
        var tracks: [Track] = []
        for (key, speaker) in [("mic", "me"), ("system", "them")] {
            guard let filename = files[key] else { continue }
            guard !filename.isEmpty, filename == (filename as NSString).lastPathComponent,
                  filename != ".", filename != "..", !filename.contains("\\"),
                  !filename.contains("\0"), !tracks.contains(where: { $0.file == filename })
            else { throw MetaError.invalid("Unsafe or duplicate track filename for \(key).") }
            tracks.append(Track(file: filename, speaker: speaker, offsetMs: offsets[key] ?? 0))
        }
        var issues: [String] = []
        for key in ["invalid_tracks", "capture_errors", "capture_error"] {
            guard let raw = json[key] else { continue }
            if let values = raw as? [String] { issues += values }
            else if let message = raw as? String { issues.append(message) }
            else if let values = raw as? [String: String] {
                issues += values.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value)" }
            } else { throw MetaError.invalid("Malformed \(key).") }
        }
        return SessionMeta(tracks: tracks, issues: issues.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }
}

struct SpeakerSpan: Sendable {
    let speaker: String
    let start: TimeInterval
    let end: TimeInterval
}

/// JSON is the canonical transcript. A separate commit record certifies that
/// both it and readable Markdown were saved successfully for this generation.
struct Transcript: Codable {
    struct Word: Codable, Sendable, Equatable {
        let text: String
        let start_ms: Int
        let end_ms: Int
        var confidence: Float?
    }

    struct Segment: Codable, Sendable {
        let speaker: String
        let start_ms: Int
        let end_ms: Int
        let text: String
        /// Word timings and recognizer confidence. Absent in transcripts
        /// written before words were retained.
        var words: [Word]? = nil
    }

    /// Microphone text removed because it repeated what was simultaneously
    /// heard on the system track (speaker playback picked up by the mic).
    /// Kept for transparency; never shown in Markdown or summaries.
    struct SuppressedSegment: Codable, Sendable {
        let segment: Segment
        let reason: String
    }

    struct TrackOutcome: Codable, Sendable {
        enum Status: String, Codable { case complete, missing, failed, invalid }
        let file: String
        let status: Status
        let segmentCount: Int
        var message: String? = nil
    }

    let engine: String
    let model: String
    let created_at: String
    let segments: [Segment]
    var trackOutcomes: [TrackOutcome] = []
    var issues: [String] = []
    var suppressedSegments: [SuppressedSegment] = []
    var generationID: String? = UUID().uuidString
    var schemaVersion: Int? = 2

    enum CodingKeys: String, CodingKey {
        case engine, model, created_at, segments
        case trackOutcomes = "track_outcomes"
        case issues
        case suppressedSegments = "suppressed_segments"
        case generationID = "generation_id"
        case schemaVersion = "schema_version"
    }

    init(engine: String, model: String, created_at: String, segments: [Segment],
         trackOutcomes: [TrackOutcome] = [], issues: [String] = [],
         suppressedSegments: [SuppressedSegment] = []) {
        self.engine = engine
        self.model = model
        self.created_at = created_at
        self.segments = segments
        self.trackOutcomes = trackOutcomes
        self.issues = issues
        self.suppressedSegments = suppressedSegments
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        engine = try values.decode(String.self, forKey: .engine)
        model = try values.decode(String.self, forKey: .model)
        created_at = try values.decode(String.self, forKey: .created_at)
        segments = try values.decode([Segment].self, forKey: .segments)
        trackOutcomes = try values.decodeIfPresent([TrackOutcome].self, forKey: .trackOutcomes) ?? []
        issues = try values.decodeIfPresent([String].self, forKey: .issues) ?? []
        suppressedSegments = try values.decodeIfPresent([SuppressedSegment].self, forKey: .suppressedSegments) ?? []
        generationID = try values.decodeIfPresent(String.self, forKey: .generationID)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion)
    }

    var validationIssues: [String] {
        var result = issues
        if trackOutcomes.isEmpty { result.append("No audio tracks were successfully verified.") }
        for track in trackOutcomes where track.status != .complete {
            result.append(track.message ?? "\(track.file): \(track.status.rawValue)")
        }
        if Set(trackOutcomes.map(\.file)).count != trackOutcomes.count
            || trackOutcomes.contains(where: { $0.segmentCount < 0 }) {
            result.append("Track results are invalid.")
        }
        if !Self.validSegments(segments) { result.append("Transcript timestamps or text are invalid.") }
        return result
    }

    var isComplete: Bool { validationIssues.isEmpty }

    func write(to directory: URL, writeFile: (Data, URL) throws -> Void = { data, url in
        try data.write(to: url, options: .atomic)
    }) throws {
        // Invalidate a previous commit before replacing either artifact. A
        // crash at any following step leaves a recoverable pending session.
        // The pending flag also protects a legacy JSON file while its first
        // modern replacement is being saved.
        let pending = directory.appendingPathComponent(TranscriptIntegrity.pendingFilename)
        try Data().write(to: pending, options: .atomic)
        let marker = directory.appendingPathComponent(TranscriptIntegrity.markerFilename)
        if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let markdown = Data(rendered(title: directory.lastPathComponent).utf8)
        let json = try encoder.encode(self)
        try writeFile(markdown, directory.appendingPathComponent("transcript.md"))
        try writeFile(json, directory.appendingPathComponent("transcript.json"))
        try FileManager.default.removeItem(at: pending)
        if isComplete, let generationID {
            let commit = TranscriptIntegrity.Commit(
                generationID: generationID,
                transcriptHash: TranscriptIntegrity.hash(json),
                markdownHash: TranscriptIntegrity.hash(markdown)
            )
            try writeFile(try encoder.encode(commit), marker)
        }
    }

    static func validSegments(_ segments: [Segment]) -> Bool {
        var previous = -1
        for segment in segments {
            guard segment.start_ms >= 0, segment.end_ms >= segment.start_ms,
                  segment.start_ms >= previous,
                  !segment.speaker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            previous = segment.start_ms
        }
        return true
    }

    private func rendered(title: String) -> String {
        var lines = ["# \(title)", "", "engine: \(engine) (\(model))", ""]
        if !isComplete {
            lines += ["> **Incomplete transcript — some recorded audio could not be verified.**",
                      "> Summaries and automatic processing are paused. Retry transcription after checking the recording."]
            lines += validationIssues.map { "> \($0.replacingOccurrences(of: "\n", with: " "))" }
            lines.append("")
        }
        for segment in segments {
            lines += ["**[\(Self.clock(segment.start_ms))] \(segment.speaker):** \(segment.text)", ""]
        }
        return lines.joined(separator: "\n")
    }

    private static func clock(_ milliseconds: Int) -> String {
        let total = max(0, milliseconds) / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

enum TranscriptIntegrity {
    static let markerFilename = "transcript.complete.json"
    static let pendingFilename = "transcript.pending"
    struct Commit: Codable {
        let generationID: String
        let transcriptHash: String
        let markdownHash: String
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isComplete(at directory: URL) -> Bool { incompletenessReason(at: directory) == nil }

    static func incompletenessReason(at directory: URL) -> String? {
        guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent(pendingFilename).path) else {
            return "The transcript was interrupted while saving. Retry transcription."
        }
        let decoder = JSONDecoder()
        guard let json = try? Data(contentsOf: directory.appendingPathComponent("transcript.json")),
              let transcript = try? decoder.decode(Transcript.self, from: json),
              let markdown = try? Data(contentsOf: directory.appendingPathComponent("transcript.md")),
              !markdown.isEmpty else { return "The transcript has not finished saving. Retry transcription." }
        guard Transcript.validSegments(transcript.segments) else { return "The transcript contains invalid timestamps or text. Retry transcription." }
        // A legacy transcript predates completion records. Validate what can
        // still be established without requiring original audio to be retained.
        if transcript.schemaVersion == nil, transcript.generationID == nil {
            guard !transcript.segments.isEmpty, transcript.issues.isEmpty,
                  transcript.trackOutcomes.isEmpty,
                  let meta = try? SessionMeta.read(from: directory), meta.issues.isEmpty else {
                return "This older transcript could not be verified. Retry transcription."
            }
            let speakers = Set(transcript.segments.map(\.speaker))
            for track in meta.tracks {
                let present = speakers.contains(track.speaker)
                    || (track.speaker == "them" && speakers.contains(where: { $0.hasPrefix("Speaker ") }))
                if !present { return "This older transcript may be missing \(track.file). Retry transcription." }
            }
            return nil
        }
        guard transcript.schemaVersion == 2, transcript.isComplete,
              let generation = transcript.generationID,
              let data = try? Data(contentsOf: directory.appendingPathComponent(markerFilename)),
              let commit = try? decoder.decode(Commit.self, from: data),
              commit.generationID == generation,
              commit.transcriptHash == hash(json), commit.markdownHash == hash(markdown) else {
            return "The transcript is incomplete or its saved files do not match. Retry transcription."
        }
        if let meta = try? SessionMeta.read(from: directory) {
            guard meta.issues.isEmpty, Set(meta.tracks.map(\.file)) == Set(transcript.trackOutcomes.map(\.file)) else {
                return "The recording contains a capture issue or an unprocessed audio track."
            }
        } else { return "Capture metadata could not be verified. Retry transcription." }
        return nil
    }
}
