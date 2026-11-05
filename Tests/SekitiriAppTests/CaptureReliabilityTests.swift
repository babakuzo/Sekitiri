import AVFoundation
import CoreAudio
import Foundation
import Testing
@testable import SekitiriApp

@Suite("Capture reliability")
struct CaptureReliabilityTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writer(in directory: URL) throws -> (SegmentedAudioWriter, AVAudioFormat) {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ))
        let writer = try SegmentedAudioWriter(
            sessionDirectory: directory, trackName: "mic", settings: format.settings,
            commonFormat: format.commonFormat, interleaved: false,
            sampleRate: format.sampleRate, segmentDuration: 100 / format.sampleRate
        )
        return (writer, format)
    }

    @Test("Tearing down system audio at stop is not reported as an interruption")
    func systemAudioTeardownIsNotAnInterruption() {
        let device = AudioObjectID(42)
        let unknown = AudioObjectID(kAudioObjectUnknown)
        // A live device dying mid-recording is a real interruption
        #expect(SystemAudioRecorder.isInterruption(recording: true, listening: device, current: device, alive: false))
        // A spurious callback while the device is fine is not
        #expect(!SystemAudioRecorder.isInterruption(recording: true, listening: device, current: device, alive: true))
        // Callbacks that land after stop has destroyed the device are not
        #expect(!SystemAudioRecorder.isInterruption(recording: false, listening: device, current: unknown, alive: false))
        #expect(!SystemAudioRecorder.isInterruption(recording: false, listening: device, current: device, alive: false))
        // Nor is one from a previous device after the recorder has moved on
        #expect(!SystemAudioRecorder.isInterruption(recording: true, listening: device, current: AudioObjectID(43), alive: false))
    }

    @Test("Only local command-line tools can use the control server")
    func controlServerRejectsBrowsers() {
        #expect(RecordingControlServer.isLocalTool("POST /stop HTTP/1.1\r\nHost: 127.0.0.1:8393\r\nUser-Agent: curl/8.7.1\r\n\r\n"))
        #expect(RecordingControlServer.isLocalTool("GET /status HTTP/1.1\r\nHost: localhost:8393\r\n\r\n"))
        // Any web page can send this; browsers always attach Origin.
        #expect(!RecordingControlServer.isLocalTool("POST /stop HTTP/1.1\r\nHost: 127.0.0.1:8393\r\nOrigin: https://example.com\r\n\r\n"))
        // DNS rebinding: an attacker's name resolving to loopback.
        #expect(!RecordingControlServer.isLocalTool("POST /stop HTTP/1.1\r\nHost: evil.example:8393\r\n\r\n"))
    }

    @Test("A mic sending exact zeros is told apart from a quiet one")
    func micDigitalSilence() {
        var zeros = [Float](repeating: 0, count: 4096)
        #expect(zeros.withUnsafeBufferPointer { MicRecorder.peak(of: $0.baseAddress!, count: $0.count) } == 0)
        // A quiet room is far below the activity threshold but never exactly zero
        zeros[2000] = -0.0002
        let quiet = zeros.withUnsafeBufferPointer { MicRecorder.peak(of: $0.baseAddress!, count: $0.count) }
        #expect(quiet > 0 && quiet < 0.008)

        let start = Date()
        #expect(!AppModel.micIsSendingNothing(since: start, now: start.addingTimeInterval(29)))
        #expect(AppModel.micIsSendingNothing(since: start, now: start.addingTimeInterval(30)))
    }

    @Test("Only closed files are exposed and stop retains the final partial segment")
    func closedSnapshotsAndAssembly() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (writer, format) = try writer(in: directory)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 60))
        buffer.frameLength = 60
        for index in 0..<60 { buffer.floatChannelData![0][index] = Float(index) / 100 }
        try writer.write(from: buffer)
        #expect(writer.closedSegmentURLs.isEmpty)
        try writer.write(from: buffer)
        #expect(writer.closedSegmentURLs.count == 1)
        #expect(try AVAudioFile(forReading: writer.closedSegmentURLs[0]).length == 60)
        writer.close()
        writer.close()
        #expect(writer.closedSegmentURLs.count == 2)
        let snapshot = writer.closedSegmentURLs
        let destination = directory.appendingPathComponent("mic.caf")
        try SegmentedAudioWriter.finalize(segments: snapshot, to: destination, removeSegmentsOnSuccess: false)
        #expect(try AVAudioFile(forReading: destination).length == 120)
        #expect(snapshot.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test("Empty input never produces a successful recording")
    func emptyInput() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (writer, format) = try writer(in: directory)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 60))
        buffer.frameLength = 0
        try writer.write(from: buffer)
        #expect(writer.close().isEmpty)
        #expect(throws: SegmentedAudioWriter.WriterError.self) {
            try SegmentedAudioWriter.finalize(segments: [], to: directory.appendingPathComponent("mic.caf"))
        }
    }

    @Test("A missing segment cannot be silently omitted during assembly")
    func missingSegment() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: SegmentedAudioWriter.WriterError.self) {
            try SegmentedAudioWriter.finalize(
                segments: [directory.appendingPathComponent("missing.caf")],
                to: directory.appendingPathComponent("mic.caf")
            )
        }
    }

    @Test("Track start offsets preserve actual capture delay")
    func trackOffsets() {
        let started = Date(timeIntervalSince1970: 1_000)
        #expect(RecordingSession.startOffsetMilliseconds(firstBufferAt: started.addingTimeInterval(1.25), startedAt: started) == 1_250)
        #expect(RecordingSession.startOffsetMilliseconds(firstBufferAt: nil, startedAt: started) == 0)
        #expect(RecordingSession.startOffsetMilliseconds(firstBufferAt: started.addingTimeInterval(-1), startedAt: started) == 0)
    }

    @Test("Crash recovery preserves capture failures and offsets and detects missing requested audio")
    func interruptedCaptureMetadata() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let checkpoint: [String: Any] = [
            "started": "2026-10-20T10:00:00Z", "heartbeat": "2026-10-20T10:00:10Z",
            "files": ["mic": "mic.caf", "system": "system.caf"],
            "start_offset_ms": ["mic": 150, "system": 750],
            "capture_errors": ["System audio disconnected"],
            "invalid_tracks": ["system.caf (capture interrupted)"]
        ]
        try JSONSerialization.data(withJSONObject: checkpoint).write(to: directory.appendingPathComponent("active.json"))
        let recovered = RecordingSession.recoverInterruptedSessions(in: root)
        #expect(recovered.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
                == [directory.resolvingSymlinksInPath().standardizedFileURL.path])
        let data = try Data(contentsOf: directory.appendingPathComponent("meta.json"))
        let metadata = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((metadata["start_offset_ms"] as? [String: Int])?["system"] == 750)
        #expect((metadata["capture_errors"] as? [String])?.contains("System audio disconnected") == true)
        let invalid = try #require(metadata["invalid_tracks"] as? [String])
        #expect(invalid.contains("system.caf (capture interrupted)"))
        #expect(invalid.contains { $0.contains("mic.caf") })
        #expect(invalid.contains { $0.contains("system.caf") })
    }
}
