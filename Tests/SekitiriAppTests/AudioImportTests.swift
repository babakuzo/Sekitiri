import AVFoundation
import Foundation
import Testing
@testable import SekitiriApp

@Suite("Importing existing recordings")
struct AudioImportTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A 3-second stereo 44.1 kHz WAV tone, unlike the recorder's own format.
    private func toneFile(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("Client call.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100 * 3)!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 {
            for frame in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![channel][frame] = 0.3 * sin(Float(frame) * 2 * .pi * 440 / 44_100)
            }
        }
        try file.write(from: buffer)
        return url
    }

    @Test("An imported file becomes a session the pipeline can transcribe")
    func importsAsSession() async throws {
        let work = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let root = work.appendingPathComponent("Recordings")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = try toneFile(in: work)
        let original = try Data(contentsOf: source)

        let session = try await AudioImport.importFile(source, into: root)

        #expect(session.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
        let meta = try SessionMeta.read(from: session)
        #expect(meta.tracks.map(\.file) == ["system.caf"])
        #expect(meta.tracks.map(\.speaker) == ["them"])
        #expect(meta.issues.isEmpty)
        let converted = try AVAudioFile(forReading: session.appendingPathComponent("system.caf"))
        #expect(converted.fileFormat.sampleRate == 48_000)
        #expect(converted.fileFormat.channelCount == 1)
        #expect(abs(Double(converted.length) / 48_000 - 3) < 0.1)
        let json = try JSONSerialization.jsonObject(
            with: Data(contentsOf: session.appendingPathComponent("meta.json"))) as? [String: Any]
        #expect(json?["title"] as? String == "Client call")
        #expect(json?["duration_seconds"] as? Int == 3)
        #expect(MeetingNotesService.hasAudio(in: session))
        // The original is never modified.
        #expect(try Data(contentsOf: source) == original)
    }

    @Test("A file without audio is refused and leaves nothing behind")
    func refusesNonAudio() async throws {
        let work = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let root = work.appendingPathComponent("Recordings")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let notes = work.appendingPathComponent("notes.mp3")
        try Data("not audio".utf8).write(to: notes)

        await #expect(throws: AudioImport.ImportError.self) {
            _ = try await AudioImport.importFile(notes, into: root)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
