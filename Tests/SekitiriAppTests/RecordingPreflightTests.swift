import AVFoundation
import Foundation
import Testing
@testable import SekitiriApp

@Suite("Warnings before and during a recording")
struct RecordingPreflightTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Time left is described coarsely")
    func describesTimeLeft() {
        #expect(RecordingPreflight.describe(30) == "less than a minute")
        #expect(RecordingPreflight.describe(7 * 60) == "about 7 minutes")
        #expect(RecordingPreflight.describe(43 * 60) == "about 40 minutes")
        #expect(RecordingPreflight.describe(3600) == "about an hour")
        #expect(RecordingPreflight.describe(6.2 * 3600) == "about 6 hours")
    }

    @Test("Free space converts to recording time, never negative")
    func convertsSpaceToTime() {
        #expect(RecordingPreflight.recordingTimeLeft(freeBytes: RecordingPreflight.bytesPerRecordingHour) == 3600)
        #expect(RecordingPreflight.recordingTimeLeft(freeBytes: 1_200_000_000) == 36_000)
        #expect(RecordingPreflight.recordingTimeLeft(freeBytes: -5) == 0)
        // The warning while recording starts well before the disk is full.
        #expect(RecordingPreflight.recordingTimeLeft(freeBytes: RecordingPreflight.lowSpaceWhileRecording) > 8 * 3600)
    }

    @Test("Free space is read from the nearest folder that exists")
    func readsFreeSpaceForMissingFolder() throws {
        let work = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let missing = work.appendingPathComponent("not/yet/created")
        let free = try #require(RecordingPreflight.freeSpace(at: missing))
        #expect(free > 0)
    }

    @Test("A recovered recording is described by its name and length")
    func describesRecoveredRecording() throws {
        let work = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let session = work.appendingPathComponent("2026.11.18-0900")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let meta: [String: Any] = ["title": "Calendar name", "title_override": "Design Review", "duration_seconds": 2830]
        try JSONSerialization.data(withJSONObject: meta).write(to: session.appendingPathComponent("meta.json"))

        let recovered = RecoveredRecording(directory: session)
        #expect(recovered.id == "2026.11.18-0900")
        #expect(recovered.title == "Design Review")
        #expect(recovered.minutes == 47)
        #expect(RecoveredRecording.message(for: [recovered])
                == "Sekitiri closed while “Design Review” was recording. Everything up to that point (47 minutes) was saved and is being transcribed now.")

        let unnamed = RecoveredRecording(directory: work.appendingPathComponent("no-meta"))
        #expect(unnamed.title == "Untitled meeting")
        #expect(unnamed.savedLength == "less than a minute")
        #expect(RecoveredRecording.message(for: [recovered, unnamed])
                == "Sekitiri closed during recording. “Design Review” (47 minutes) and “Untitled meeting” (less than a minute) were saved and are being transcribed now.")
    }

    @Test("The computer audio test tells sound from silence")
    func measuresPeakLevel() throws {
        let work = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        func write(_ name: String, amplitude: Float) throws {
            let folder = work.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = try AVAudioFile(forWriting: folder.appendingPathComponent("000000.caf"), settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
            buffer.frameLength = 4_800
            for frame in 0..<4_800 {
                buffer.floatChannelData![0][frame] = amplitude * sin(Float(frame) * 2 * .pi * 440 / 48_000)
            }
            try file.write(from: buffer)
        }
        try write("silent", amplitude: 0)
        try write("sound", amplitude: 0.4)
        #expect(RecordingPreflight.peakLevel(under: work.appendingPathComponent("silent")) == 0)
        #expect(RecordingPreflight.peakLevel(under: work.appendingPathComponent("sound")) > 0.3)
    }
}
