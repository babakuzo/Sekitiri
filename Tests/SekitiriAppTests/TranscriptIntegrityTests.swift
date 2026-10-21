import Foundation
import Testing
@testable import SekitiriApp

@Suite("Transcript integrity and recovery")
struct TranscriptIntegrityTests {
    private func session(files: [String: String] = ["mic": "mic.caf"], extra: [String: Any] = [:]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var metadata: [String: Any] = ["files": files]
        metadata.merge(extra) { _, new in new }
        try JSONSerialization.data(withJSONObject: metadata).write(to: directory.appendingPathComponent("meta.json"))
        return directory
    }

    private func transcript(issues: [String] = []) -> Transcript {
        Transcript(engine: "test", model: "test", created_at: "2026-10-20T12:00:00Z",
                   segments: [.init(speaker: "me", start_ms: 0, end_ms: 900, text: "Send the draft tomorrow.")],
                   trackOutcomes: [.init(file: "mic.caf", status: .complete, segmentCount: 1)], issues: issues)
    }

    @Test("Malformed manifests never hide missing tracks or unsafe paths")
    func malformedMetadata() throws {
        for (files, extra) in [
            ([String: String](), [String: Any]()),
            (["mic": "../secret.caf"], [:]),
            (["mic": "same.caf", "system": "same.caf"], [:]),
            (["mic": "mic.caf"], ["start_offset_ms": ["mic": -1]]),
            (["mic": "mic.caf"], ["start_offset_ms": ["mic": 1.5]]),
            (["mic": "mic.caf"], ["start_offset_ms": ["mic": true]]),
            (["mic": "mic.caf"], ["invalid_tracks": 7]),
        ] {
            let directory = try session(files: files, extra: extra)
            defer { try? FileManager.default.removeItem(at: directory) }
            #expect(throws: (any Error).self) { try SessionMeta.read(from: directory) }
        }
    }

    @Test("Capture errors survive manifest loading and prevent completion")
    func captureErrors() throws {
        let directory = try session(extra: ["invalid_tracks": ["system.caf"], "capture_errors": ["System capture stopped early."]])
        defer { try? FileManager.default.removeItem(at: directory) }
        let meta = try SessionMeta.read(from: directory)
        #expect(meta.issues.count == 2)
        let partial = transcript(issues: meta.issues)
        try partial.write(to: directory)
        #expect(!TranscriptIntegrity.isComplete(at: directory))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(TranscriptIntegrity.markerFilename).path))
        let text = try String(contentsOf: directory.appendingPathComponent("transcript.md"), encoding: .utf8)
        #expect(text.contains("Incomplete transcript"))
        #expect(text.contains("Send the draft tomorrow."))
    }

    @Test("Completion is committed last and interrupted writes remain resumable")
    func commitOrderAndInterruptedWrite() throws {
        let directory = try session()
        defer { try? FileManager.default.removeItem(at: directory) }
        let value = transcript()
        var written: [String] = []
        try value.write(to: directory) { data, url in
            written.append(url.lastPathComponent)
            if url.lastPathComponent != TranscriptIntegrity.markerFilename {
                #expect(!TranscriptIntegrity.isComplete(at: directory))
            }
            try data.write(to: url, options: .atomic)
        }
        #expect(written == ["transcript.md", "transcript.json", TranscriptIntegrity.markerFilename])
        #expect(TranscriptIntegrity.isComplete(at: directory))
        enum Interrupted: Error { case stopped }
        #expect(throws: Interrupted.self) {
            try value.write(to: directory) { data, url in
                if url.lastPathComponent == "transcript.json" { throw Interrupted.stopped }
                try data.write(to: url, options: .atomic)
            }
        }
        #expect(!TranscriptIntegrity.isComplete(at: directory))
        // A resumed attempt replaces the interrupted generation completely.
        try transcript().write(to: directory)
        #expect(TranscriptIntegrity.isComplete(at: directory))
    }

    @Test("Partial tracks and invalid timelines cannot be certified")
    func incompleteTrackAndTimeline() throws {
        let directory = try session(files: ["mic": "mic.caf", "system": "system.caf"])
        defer { try? FileManager.default.removeItem(at: directory) }
        var partial = transcript()
        partial.trackOutcomes.append(.init(file: "system.caf", status: .failed, segmentCount: 0, message: "Decoder failed."))
        try partial.write(to: directory)
        #expect(!TranscriptIntegrity.isComplete(at: directory))
        // A missing expected outcome is rejected even if every listed track succeeded.
        try transcript().write(to: directory)
        #expect(!TranscriptIntegrity.isComplete(at: directory))
        let invalid = Transcript(engine: "test", model: "test", created_at: "now",
                                 segments: [.init(speaker: "me", start_ms: 20, end_ms: 1, text: "Broken timing")],
                                 trackOutcomes: [.init(file: "mic.caf", status: .complete, segmentCount: 1)])
        #expect(!invalid.isComplete)
        let empty = Transcript(engine: "test", model: "test", created_at: "now", segments: [])
        #expect(!empty.isComplete)
    }

    @Test("A mismatched saved artifact cannot reuse an old completion record")
    func mismatchedArtifacts() throws {
        let directory = try session()
        defer { try? FileManager.default.removeItem(at: directory) }
        try transcript().write(to: directory)
        try Data("truncated".utf8).write(to: directory.appendingPathComponent("transcript.md"))
        #expect(!TranscriptIntegrity.isComplete(at: directory))
        try transcript().write(to: directory)
        #expect(TranscriptIntegrity.isComplete(at: directory))
    }

    @Test("Deleting original audio does not invalidate committed text")
    func deletedAudioRemainsComplete() throws {
        let directory = try session()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("mic.caf")
        try Data("placeholder audio".utf8).write(to: audio)
        try transcript().write(to: directory)
        try FileManager.default.removeItem(at: audio)
        #expect(TranscriptIntegrity.isComplete(at: directory))
        try FileManager.default.removeItem(at: directory.appendingPathComponent(TranscriptIntegrity.markerFilename))
        let legacy: [String: Any] = ["engine": "old", "model": "old", "created_at": "now",
                                     "segments": [["speaker": "me", "start_ms": 0, "end_ms": 900, "text": "Hello"]]]
        try JSONSerialization.data(withJSONObject: legacy).write(to: directory.appendingPathComponent("transcript.json"))
        #expect(TranscriptIntegrity.isComplete(at: directory))
    }

    @Test("Removing schema fields cannot disguise failed modern track outcomes as legacy")
    func malformedModernCannotDowngrade() throws {
        let directory = try session()
        defer { try? FileManager.default.removeItem(at: directory) }
        let malformed: [String: Any] = ["engine": "test", "model": "test", "created_at": "now",
                                        "segments": [["speaker": "me", "start_ms": 0, "end_ms": 900, "text": "Hello"]],
                                        "track_outcomes": [["file": "mic.caf", "status": "failed", "segmentCount": 1]]]
        try JSONSerialization.data(withJSONObject: malformed).write(to: directory.appendingPathComponent("transcript.json"))
        try Data("Hello".utf8).write(to: directory.appendingPathComponent("transcript.md"))
        #expect(!TranscriptIntegrity.isComplete(at: directory))
    }

    @Test("Legacy JSON remains readable but missing speakers require repair")
    func legacyCompatibility() throws {
        let directory = try session()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy: [String: Any] = ["engine": "old", "model": "old", "created_at": "now",
                                     "segments": [["speaker": "me", "start_ms": 0, "end_ms": 900, "text": "Hello"]]]
        try JSONSerialization.data(withJSONObject: legacy).write(to: directory.appendingPathComponent("transcript.json"))
        try Data("# Older transcript\nHello".utf8).write(to: directory.appendingPathComponent("transcript.md"))
        #expect(TranscriptIntegrity.isComplete(at: directory))
        enum Interrupted: Error { case stopped }
        #expect(throws: Interrupted.self) {
            try transcript().write(to: directory) { _, _ in throw Interrupted.stopped }
        }
        // Even untouched legacy artifacts cannot appear complete while their
        // replacement was interrupted, or summaries could use stale content.
        #expect(!TranscriptIntegrity.isComplete(at: directory))
        try FileManager.default.removeItem(at: directory.appendingPathComponent(TranscriptIntegrity.pendingFilename))
        try JSONSerialization.data(withJSONObject: ["files": ["mic": "mic.caf", "system": "system.caf"]])
            .write(to: directory.appendingPathComponent("meta.json"))
        #expect(!TranscriptIntegrity.isComplete(at: directory))
    }
}
