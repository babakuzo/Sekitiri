import AVFoundation
import FluidAudio
import Foundation

/// Reads a bounded interval from consecutive, finalized recording files. The
/// same decoded-frame timeline is used during recording and finalisation.
enum AudioWindowReader {
    static let sampleRate = 16_000.0
    static let maximumDuration: TimeInterval = 60

    enum ReadError: Error, CustomStringConvertible {
        case invalidWindow
        case unreadable(URL)
        case shortRead(URL)

        var description: String {
            switch self {
            case .invalidWindow: return "Invalid or oversized transcription audio window."
            case .unreadable(let url): return "Cannot read audio from \(url.lastPathComponent)."
            case .shortRead(let url): return "Incomplete audio read from \(url.lastPathComponent)."
            }
        }
    }

    static func duration(of sourceURLs: [URL]) throws -> TimeInterval {
        try sourceURLs.reduce(0) { total, url in
            let file = try AVAudioFile(forReading: url)
            guard file.processingFormat.sampleRate > 0 else { throw ReadError.unreadable(url) }
            return total + Double(file.length) / file.processingFormat.sampleRate
        }
    }

    /// Conversion buffers never contain more than the requested bounded window.
    /// Empty files are allowed between finalized segments; absent files and short
    /// reads are errors so the caller cannot publish partial speech as complete.
    static func read(sourceURLs: [URL], start: TimeInterval, duration: TimeInterval) throws -> [Float] {
        guard start.isFinite, duration.isFinite, start >= 0, duration > 0,
              duration <= maximumDuration else { throw ReadError.invalidWindow }
        let end = start + duration
        let converter = AudioConverter()
        var result: [Float] = []
        result.reserveCapacity(Int((duration * sampleRate).rounded(.up)))
        var fileStart: TimeInterval = 0
        for url in sourceURLs {
            try Task.checkCancellation()
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let rate = file.processingFormat.sampleRate
            guard rate > 0 else { throw ReadError.unreadable(url) }
            let fileDuration = Double(file.length) / rate
            let fileEnd = fileStart + fileDuration
            defer { fileStart = fileEnd }
            let overlapStart = max(start, fileStart)
            let overlapEnd = min(end, fileEnd)
            guard overlapEnd > overlapStart else { continue }
            let first = min(file.length, AVAudioFramePosition(((overlapStart - fileStart) * rate).rounded()))
            let last = min(file.length, AVAudioFramePosition(((overlapEnd - fileStart) * rate).rounded()))
            guard last > first else { continue }
            let count = AVAudioFrameCount(last - first)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else {
                throw ReadError.unreadable(url)
            }
            file.framePosition = first
            // AVAudioFile can return a partial read before EOF (including CAF
            // decoder packet boundaries). Accumulate until the requested range
            // is filled instead of treating a single partial read as data loss.
            guard let destination = buffer.floatChannelData,
                  let chunk = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat, frameCapacity: min(count, 8192)
                  ) else { throw ReadError.unreadable(url) }
            var copied: AVAudioFrameCount = 0
            while copied < count {
                try Task.checkCancellation()
                try file.read(into: chunk, frameCount: min(chunk.frameCapacity, count - copied))
                guard chunk.frameLength > 0, let channels = chunk.floatChannelData else {
                    throw ReadError.shortRead(url)
                }
                for channel in 0..<Int(file.processingFormat.channelCount) {
                    destination[channel].advanced(by: Int(copied)).update(
                        from: channels[channel], count: Int(chunk.frameLength)
                    )
                }
                copied += chunk.frameLength
            }
            buffer.frameLength = copied
            result.append(contentsOf: try converter.resampleBuffer(buffer))
        }
        // Never silently satisfy a window whose tail is not finalized yet.
        guard end <= fileStart + 1 / sampleRate else { throw ReadError.invalidWindow }
        return result
    }
}
