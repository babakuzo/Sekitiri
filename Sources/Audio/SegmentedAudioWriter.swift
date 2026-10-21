import AVFoundation
import Foundation

/// Writes independently playable AAC/CAF segments while capture is active.
/// A crash can damage at most the current segment; every earlier segment has
/// already been closed with a complete packet table. On a clean stop the
/// segments are joined into the legacy `mic.caf` / `system.caf` file expected
/// by the rest of Sekitiri.
final class SegmentedAudioWriter: @unchecked Sendable {
    enum WriterError: Error, LocalizedError {
        case noSegments
        case incompatibleSegment(URL)
        case unreadableSegment(URL)

        var errorDescription: String? {
            switch self {
            case .noSegments: return "No recorded audio was available."
            case .incompatibleSegment(let url): return "Audio format changed in \(url.lastPathComponent)."
            case .unreadableSegment(let url): return "Recorded segment \(url.lastPathComponent) is missing or empty."
            }
        }
    }

    static let defaultSegmentDuration: TimeInterval = 30

    let trackName: String
    let segmentDirectory: URL

    private let lock = NSLock()
    private let settings: [String: Any]
    private let commonFormat: AVAudioCommonFormat
    private let interleaved: Bool
    private let segmentFrameLimit: AVAudioFramePosition
    private var currentFile: AVAudioFile?
    private var currentFrames: AVAudioFramePosition = 0
    private var nextIndex = 1
    private var urls: [URL] = []
    private var closedURLs: [URL] = []
    private var closed = false

    init(
        sessionDirectory: URL,
        trackName: String,
        settings: [String: Any],
        commonFormat: AVAudioCommonFormat,
        interleaved: Bool,
        sampleRate: Double,
        segmentDuration: TimeInterval = defaultSegmentDuration
    ) throws {
        self.trackName = trackName
        self.settings = settings
        self.commonFormat = commonFormat
        self.interleaved = interleaved
        self.segmentFrameLimit = max(1, AVAudioFramePosition(sampleRate * segmentDuration))
        segmentDirectory = sessionDirectory
            .appendingPathComponent("segments", isDirectory: true)
            .appendingPathComponent(trackName, isDirectory: true)
        try FileManager.default.createDirectory(at: segmentDirectory, withIntermediateDirectories: true)
    }

    var segmentURLs: [URL] {
        lock.withLock { urls }
    }

    /// Only files with a finalized packet table are safe for concurrent ASR.
    var closedSegmentURLs: [URL] {
        lock.withLock { closedURLs }
    }

    var isClosed: Bool { lock.withLock { closed } }

    func write(from buffer: AVAudioPCMBuffer) throws {
        try lock.withLock {
            guard !closed else { throw CancellationError() }
            guard buffer.frameLength > 0 else { return }
            if currentFile == nil || (currentFrames > 0 && currentFrames + AVAudioFramePosition(buffer.frameLength) > segmentFrameLimit) {
                try rotate()
            }
            guard let currentFile else { throw WriterError.noSegments }
            try currentFile.write(from: buffer)
            currentFrames += AVAudioFramePosition(buffer.frameLength)
        }
    }

    /// Closes the active segment. Safe to call repeatedly and concurrently
    /// with Stop because the same lock protects writes and finalisation.
    @discardableResult
    func close() -> [URL] {
        lock.withLock {
            guard !closed else { return urls }
            closed = true
            finishCurrentSegment()
            return urls
        }
    }

    func discard() {
        let files = close()
        for file in files { try? FileManager.default.removeItem(at: file) }
        try? FileManager.default.removeItem(at: segmentDirectory)
    }

    /// Creates the legacy single-track file. Segment files are intentionally
    /// retained until the merged file has been validated, then removed.
    static func finalize(
        segments: [URL],
        to destination: URL,
        removeSegmentsOnSuccess: Bool = true
    ) throws {
        guard !segments.isEmpty else { throw WriterError.noSegments }
        // Silently filtering missing files would publish an incomplete recording.
        for segment in segments {
            guard FileManager.default.fileExists(atPath: segment.path),
                  let audio = try? AVAudioFile(forReading: segment), audio.length > 0
            else { throw WriterError.unreadableSegment(segment) }
        }
        let existing = segments

        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.deletingPathExtension().lastPathComponent).assembling-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: temporary) }

        let first = try AVAudioFile(forReading: existing[0])
        let processingFormat = first.processingFormat
        let output = try AVAudioFile(
            forWriting: temporary,
            settings: first.fileFormat.settings,
            commonFormat: processingFormat.commonFormat,
            interleaved: processingFormat.isInterleaved
        )

        for url in existing {
            let source = try AVAudioFile(forReading: url)
            guard source.processingFormat.sampleRate == processingFormat.sampleRate,
                  source.processingFormat.channelCount == processingFormat.channelCount
            else { throw WriterError.incompatibleSegment(url) }
            let capacity: AVAudioFrameCount = 16_384
            guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: capacity) else {
                throw WriterError.incompatibleSegment(url)
            }
            while source.framePosition < source.length {
                buffer.frameLength = 0
                try source.read(into: buffer, frameCount: capacity)
                guard buffer.frameLength > 0 else { break }
                try output.write(from: buffer)
            }
        }
        output.close()

        guard try AVAudioFile(forReading: temporary).length > 0 else { throw WriterError.noSegments }
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: temporary, to: destination)
        if removeSegmentsOnSuccess {
            for url in existing { try? fm.removeItem(at: url) }
            let parents = Set(existing.map { $0.deletingLastPathComponent() })
            for parent in parents { try? fm.removeItem(at: parent) }
        }
    }

    static func discoveredSegments(in sessionDirectory: URL, trackName: String) -> [URL] {
        let directory = sessionDirectory
            .appendingPathComponent("segments", isDirectory: true)
            .appendingPathComponent(trackName, isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? [])
        .filter { $0.pathExtension.lowercased() == "caf" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func finishCurrentSegment() {
        guard let currentFile else { return }
        currentFile.close()
        self.currentFile = nil
        if currentFrames > 0, let url = urls.last { closedURLs.append(url) }
    }

    private func rotate() throws {
        finishCurrentSegment()
        let url = segmentDirectory.appendingPathComponent(String(format: "%06d.caf", nextIndex))
        currentFile = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: commonFormat,
            interleaved: interleaved
        )
        urls.append(url)
        nextIndex += 1
        currentFrames = 0
    }
}
