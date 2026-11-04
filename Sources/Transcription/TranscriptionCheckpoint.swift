import AVFoundation
import Foundation

/// One authoritative piece of the transcript, with extra audio on both sides
/// for recognition context. Only words belonging to the core are committed.
struct TranscriptionWindow: Codable, Equatable, Sendable {
    /// Context plus core stays under Parakeet's 15 s encoder window, so each
    /// window is decoded in one pass with no internal chunk seam.
    static let coreDuration: TimeInterval = 12.9
    static let contextDuration: TimeInterval = 1
    /// Pause-aligned windows never end earlier than this.
    static let minimumCore: TimeInterval = 6
    /// Checkpoints written before pause-aligned windows used 26 s cores and
    /// 2 s context; they remain valid and resumable.
    static let legacyMaximumCore: TimeInterval = 26
    static let legacyMaximumRead: TimeInterval = 30
    let coreStart: TimeInterval
    let coreEnd: TimeInterval
    let readStart: TimeInterval
    let readEnd: TimeInterval

    static func next(after completed: TimeInterval, available: TimeInterval, final: Bool,
                     core: TimeInterval = coreDuration, context: TimeInterval = contextDuration) -> Self? {
        guard completed.isFinite, available.isFinite, completed >= 0,
              available - completed > 0.000_1 else { return nil }
        let coreEnd = min(completed + core, available)
        if !final && available + 0.000_1 < completed + core + context { return nil }
        return Self(coreStart: completed, coreEnd: coreEnd,
                    readStart: max(0, completed - context),
                    readEnd: min(available, coreEnd + context))
    }
}

/// Durable, per-track progress. Appending newly closed audio files preserves
/// earlier work; changing a source, language or model invalidates it. The cache
/// is never a completion marker and never replaces the original recording.
struct TranscriptionCheckpoint: Codable {
    struct Source: Codable, Equatable {
        let path: String
        let bytes: UInt64
        let modified: Date
        let frames: Int64
        let sampleRate: Double

        init(_ url: URL) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let audio = try AVAudioFile(forReading: url)
            guard audio.length > 0, audio.processingFormat.sampleRate.isFinite,
                  audio.processingFormat.sampleRate > 0 else {
                throw CheckpointError.invalidAudio(url.lastPathComponent)
            }
            path = url.standardizedFileURL.path
            bytes = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            modified = attributes[.modificationDate] as? Date ?? .distantPast
            frames = audio.length
            sampleRate = audio.processingFormat.sampleRate
        }
    }
    struct CompletedWindow: Codable {
        let window: TranscriptionWindow
        let segments: [TranscriptSegment]
    }
    enum CheckpointError: LocalizedError {
        case invalidAudio(String)
        case invalidResult
        var errorDescription: String? {
            switch self {
            case .invalidAudio(let file): return "No readable audio frames in \(file)."
            case .invalidResult: return "Transcription returned invalid timestamps. The audio was preserved for retry."
            }
        }
    }

    private static let pipelineVersion = 1
    let version: Int
    let engine: String
    let model: String
    let language: String
    var sources: [Source]
    var windows: [CompletedWindow]

    var completedThrough: TimeInterval { windows.last?.window.coreEnd ?? 0 }
    var segments: [TranscriptSegment] { windows.flatMap(\.segments) }
    var duration: TimeInterval { sources.reduce(0) { $0 + Double($1.frames) / $1.sampleRate } }

    static func open(at url: URL, sources sourceURLs: [URL], engine: String, model: String, language: String) throws -> Self {
        let sources = try sourceURLs.map(Source.init)
        if let data = try? Data(contentsOf: url),
           var cached = try? JSONDecoder().decode(Self.self, from: data),
           cached.version == pipelineVersion, cached.engine == engine,
           cached.model == model, cached.language == language,
           sources.starts(with: cached.sources), cached.validWindows {
            cached.sources = sources
            return cached
        }
        return Self(version: pipelineVersion, engine: engine, model: model,
                    language: language, sources: sources, windows: [])
    }

    /// Read previously committed text for explicitly incomplete presentation if
    /// a recording source is now missing or unreadable. This does not verify the
    /// current audio and must never authorize completion or further cache reuse.
    static func recoverPartial(at url: URL, engine: String, model: String, language: String) -> Self? {
        guard let data = try? Data(contentsOf: url),
              let cached = try? JSONDecoder().decode(Self.self, from: data),
              cached.version == pipelineVersion, cached.engine == engine,
              cached.model == model, cached.language == language,
              !cached.sources.isEmpty,
              cached.sources.allSatisfy({ $0.frames > 0 && $0.sampleRate.isFinite && $0.sampleRate > 0 }),
              cached.validWindows else { return nil }
        return cached
    }

    mutating func append(_ segments: [TranscriptSegment], for window: TranscriptionWindow, savingTo url: URL) throws {
        var candidate = self
        candidate.windows.append(CompletedWindow(window: window, segments: segments))
        guard candidate.validWindows else { throw CheckpointError.invalidResult }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(candidate).write(to: url, options: .atomic)
        self = candidate
    }

    private var validWindows: Bool {
        var end: TimeInterval = 0
        for entry in windows {
            let window = entry.window
            guard window.coreStart.isFinite, window.coreEnd.isFinite,
                  window.readStart.isFinite, window.readEnd.isFinite,
                  abs(window.coreStart - end) < 0.000_1,
                  window.coreEnd > window.coreStart, window.coreEnd <= duration + 0.001,
                  window.coreEnd - window.coreStart <= TranscriptionWindow.legacyMaximumCore + 0.001,
                  window.readStart >= 0, window.readStart <= window.coreStart,
                  window.readEnd >= window.coreEnd, window.readEnd <= duration + 0.001,
                  window.readEnd - window.readStart <= TranscriptionWindow.legacyMaximumRead + 0.001,
                  Self.valid(entry.segments, in: window) else { return false }
            end = window.coreEnd
        }
        return true
    }

    private static func valid(_ segments: [TranscriptSegment], in window: TranscriptionWindow) -> Bool {
        var lastStart = -Double.infinity
        for segment in segments {
            guard segment.start.isFinite, segment.end.isFinite,
                  segment.start >= window.readStart - 0.001,
                  segment.end <= window.readEnd + 0.001,
                  segment.start >= lastStart, segment.end >= segment.start,
                  !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            lastStart = segment.start
        }
        return true
    }

    static func url(in directory: URL, track: String) -> URL {
        directory.appendingPathComponent("transcription-cache", isDirectory: true)
            .appendingPathComponent("\(track).json")
    }
}
