import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Turns an existing recording (any audio or video file macOS can read) into a
/// session that is transcribed and summarised like one Sekitiri recorded.
///
/// The file becomes the session's computer-audio track: everyone in it is
/// treated as another participant, and speaker separation can tell them apart.
/// The original is never modified; a copy is converted to the same AAC format
/// the recorder writes, so playback and audio deletion work unchanged.
enum AudioImport {
    enum ImportError: LocalizedError {
        case noAudio(String)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .noAudio(let name): return "\(name) has no audio to transcribe."
            case .unreadable(let name): return "\(name) couldn’t be read as audio."
            }
        }
    }

    /// Anything with a sound track: audio files and videos alike.
    static let contentTypes: [UTType] = [.audio, .movie]

    private static let sampleRate = 48_000.0

    /// Copies `source` into a new session folder under `root` and returns it.
    /// The folder is named for when the file was made, so it sorts with the
    /// meeting's date. Nothing is left behind if conversion fails.
    static func importFile(_ source: URL, into root: URL) async throws -> URL {
        let name = source.lastPathComponent
        let asset = AVURLAsset(url: source)
        let track: AVAssetTrack
        let duration: TimeInterval
        do {
            guard let first = try await asset.loadTracks(withMediaType: .audio).first else {
                throw ImportError.noAudio(name)
            }
            track = first
            duration = try await asset.load(.duration).seconds
        } catch let error as ImportError {
            throw error
        } catch {
            throw ImportError.unreadable(name)
        }

        let dates = try? source.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let started = dates?.creationDate ?? dates?.contentModificationDate ?? Date()
        let directory = try RecordingSession.makeDirectory(in: root, startedAt: started)
        do {
            try await Task.detached(priority: .userInitiated) {
                try convert(track, of: asset, named: name, to: directory.appendingPathComponent("system.caf"))
            }.value
            // Written last: a folder with meta.json is picked up for
            // transcription, so it must never point at half-converted audio.
            try writeMeta(in: directory, source: source, started: started,
                          duration: duration.isFinite ? duration : 0)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return directory
    }

    /// Decodes the audio track to 48 kHz mono and encodes it as AAC in CAF,
    /// matching the recorder's own tracks.
    private static func convert(_ track: AVAssetTrack, of asset: AVAsset, named name: String,
                                to destination: URL) throws {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 1, interleaved: false)
        else { throw ImportError.unreadable(name) }
        reader.add(output)
        guard reader.startReading() else { throw ImportError.unreadable(name) }

        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".import.caf")
        var frames: AVAudioFramePosition = 0
        do {
            let file = try AVAudioFile(forWriting: temporary, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            while let sample = output.copyNextSampleBuffer() {
                let count = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
                guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { continue }
                buffer.frameLength = count
                let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                    sample, at: 0, frameCount: Int32(count), into: buffer.mutableAudioBufferList)
                guard status == noErr else { throw ImportError.unreadable(name) }
                try file.write(from: buffer)
                frames += AVAudioFramePosition(count)
            }
        }
        guard reader.status == .completed, frames > 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw reader.status == .completed ? ImportError.noAudio(name) : ImportError.unreadable(name)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private static func writeMeta(in directory: URL, source: URL, started: Date, duration: TimeInterval) throws {
        let iso = ISO8601DateFormatter()
        let meta: [String: Any] = [
            "started": iso.string(from: started),
            "ended": iso.string(from: started.addingTimeInterval(duration)),
            "duration_seconds": Int(duration.rounded()),
            "files": ["system": "system.caf"],
            "start_offset_ms": ["system": 0],
            "capture_errors": [String](),
            "invalid_tracks": [String](),
            "title": source.deletingPathExtension().lastPathComponent,
            "imported_from": source.lastPathComponent,
        ]
        let data = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("meta.json"), options: .atomic)
    }
}
