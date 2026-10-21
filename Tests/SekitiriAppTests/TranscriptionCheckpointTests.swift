import AVFoundation
import Foundation
import Testing
@testable import SekitiriApp

@Suite("Resumable authoritative transcription")
struct TranscriptionCheckpointTests {
    private func withRecording(_ body: (URL, URL, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.caf")
        let second = directory.appendingPathComponent("second.caf")
        try writeAudio(first, seconds: 30)
        try writeAudio(second, seconds: 30)
        try body(directory, first, second)
    }

    private func writeAudio(_ url: URL, seconds: Double) throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
            channels: 1, interleaved: false
        ))
        let frames = AVAudioFrameCount(seconds * 16_000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.floatChannelData?[0])
        samples.initialize(repeating: 0, count: Int(frames))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func open(_ cache: URL, _ sources: [URL], model: String = "v3", language: String = "auto") throws -> TranscriptionCheckpoint {
        try TranscriptionCheckpoint.open(
            at: cache, sources: sources, engine: "parakeet-v3", model: model, language: language
        )
    }

    @Test("Closed-file prefix reuse preserves completed work as recording grows")
    func growsWithoutRetranscribing() throws {
        try withRecording { directory, first, second in
            let cache = TranscriptionCheckpoint.url(in: directory, track: "mic")
            var checkpoint = try open(cache, [first])
            let window = try #require(TranscriptionWindow.next(after: 0, available: 30, final: false))
            try checkpoint.append([TranscriptSegment(start: 2, end: 3, text: "Bonjour, let's begin.")], for: window, savingTo: cache)

            let restored = try open(cache, [first, second])
            #expect(restored.sources.count == 2)
            #expect(restored.duration == 60)
            #expect(restored.completedThrough == 26)
            #expect(restored.segments.map(\.text) == ["Bonjour, let's begin."])
            #expect(TranscriptionWindow.next(after: restored.completedThrough, available: restored.duration, final: false)?.coreStart == 26)
        }
    }

    @Test("Changing model, language or source identity invalidates the cache")
    func invalidatesConfigurationAndAudio() throws {
        try withRecording { directory, first, second in
            let cache = TranscriptionCheckpoint.url(in: directory, track: "mic")
            var checkpoint = try open(cache, [first])
            let window = try #require(TranscriptionWindow.next(after: 0, available: 30, final: false))
            try checkpoint.append([], for: window, savingTo: cache)
            #expect(try open(cache, [first], model: "different-model").completedThrough == 0)
            #expect(try open(cache, [first], language: "fr").completedThrough == 0)
            #expect(try open(cache, [second]).completedThrough == 0)
            #expect(try open(cache, [second, first]).completedThrough == 0)

            let oldDate = try #require(try FileManager.default.attributesOfItem(atPath: first.path)[.modificationDate] as? Date)
            try FileManager.default.setAttributes([.modificationDate: oldDate.addingTimeInterval(2)], ofItemAtPath: first.path)
            #expect(try open(cache, [first]).completedThrough == 0)
        }
    }

    @Test("Background recognition waits for complete core and right context")
    func waitsForContext() {
        #expect(TranscriptionWindow.next(after: 0, available: 27.9, final: false) == nil)
        #expect(TranscriptionWindow.next(after: 26, available: 53.9, final: false) == nil)
        #expect(TranscriptionWindow.next(after: 0, available: 28, final: false)
            == TranscriptionWindow(coreStart: 0, coreEnd: 26, readStart: 0, readEnd: 28))
        #expect(TranscriptionWindow.next(after: 26, available: 54, final: false)
            == TranscriptionWindow(coreStart: 26, coreEnd: 52, readStart: 24, readEnd: 54))
        #expect(TranscriptionWindow.next(after: 26, available: 26, final: true) == nil)
        #expect(TranscriptionWindow.next(after: .nan, available: 30, final: true) == nil)
        #expect(TranscriptionWindow.next(after: 0, available: .infinity, final: true) == nil)
    }

    @Test("Stopping with a tiny final tail commits that tail once")
    func finalTinyTail() throws {
        try withRecording { directory, first, _ in
            try writeAudio(first, seconds: 26.05)
            let cache = TranscriptionCheckpoint.url(in: directory, track: "mic")
            var checkpoint = try open(cache, [first])
            let firstWindow = try #require(TranscriptionWindow.next(after: 0, available: checkpoint.duration, final: true))
            try checkpoint.append([], for: firstWindow, savingTo: cache)
            let tail = try #require(TranscriptionWindow.next(after: checkpoint.completedThrough, available: checkpoint.duration, final: true))
            #expect(abs(tail.coreEnd - 26.05) < 0.0001)
            #expect(tail.readStart == 24)
            try checkpoint.append([TranscriptSegment(start: 26.01, end: 26.04, text: "Oui.")], for: tail, savingTo: cache)
            let restored = try open(cache, [first])
            #expect(abs(restored.completedThrough - 26.05) < 0.0001)
            #expect(restored.segments.map(\.text) == ["Oui."])
            #expect(TranscriptionWindow.next(after: restored.completedThrough, available: restored.duration, final: true) == nil)
        }
    }

    @Test("Corrupt JSON and invalid cached window bounds restart safely")
    func corruptCache() throws {
        try withRecording { directory, first, _ in
            let cache = directory.appendingPathComponent("cache.json")
            try Data("not valid json".utf8).write(to: cache)
            #expect(try open(cache, [first]).completedThrough == 0)
            var checkpoint = try open(cache, [first])
            let window = try #require(TranscriptionWindow.next(after: 0, available: 30, final: false))
            try checkpoint.append([], for: window, savingTo: cache)
            var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as? [String: Any])
            var windows = try #require(json["windows"] as? [[String: Any]])
            var bounds = try #require(windows[0]["window"] as? [String: Any])
            bounds["readEnd"] = 500
            windows[0]["window"] = bounds
            json["windows"] = windows
            try JSONSerialization.data(withJSONObject: json).write(to: cache)
            #expect(try open(cache, [first]).completedThrough == 0)
        }
    }

    @Test("Nonfinite timestamps and malformed windows never advance durable progress")
    func rejectsInvalidResults() throws {
        try withRecording { directory, first, _ in
            let cache = directory.appendingPathComponent("cache.json")
            let goodWindow = try #require(TranscriptionWindow.next(after: 0, available: 30, final: false))
            for segment in [
                TranscriptSegment(start: .nan, end: 2, text: "invalid"),
                TranscriptSegment(start: 1, end: .infinity, text: "invalid"),
                TranscriptSegment(start: 2, end: 1, text: "invalid"),
                TranscriptSegment(start: -1, end: 2, text: "invalid"),
            ] {
                var checkpoint = try open(cache, [first])
                #expect(throws: (any Error).self) { try checkpoint.append([segment], for: goodWindow, savingTo: cache) }
                #expect(checkpoint.completedThrough == 0)
            }
            for window in [
                TranscriptionWindow(coreStart: 0, coreEnd: 26, readStart: .nan, readEnd: 28),
                TranscriptionWindow(coreStart: 0, coreEnd: 26, readStart: 0, readEnd: .infinity),
                TranscriptionWindow(coreStart: 0, coreEnd: 26, readStart: 0, readEnd: 31),
                TranscriptionWindow(coreStart: 2, coreEnd: 26, readStart: 0, readEnd: 28),
            ] {
                var checkpoint = try open(cache, [first])
                #expect(throws: (any Error).self) { try checkpoint.append([], for: window, savingTo: cache) }
                #expect(checkpoint.completedThrough == 0)
            }
        }
    }

    @Test("A failed atomic save does not advance in-memory progress")
    func failedPersistence() throws {
        try withRecording { directory, first, _ in
            let parentFile = directory.appendingPathComponent("file-not-directory")
            try Data().write(to: parentFile)
            let cache = parentFile.appendingPathComponent("cache.json")
            var checkpoint = try open(cache, [first])
            let window = try #require(TranscriptionWindow.next(after: 0, available: 30, final: false))
            #expect(throws: (any Error).self) { try checkpoint.append([], for: window, savingTo: cache) }
            #expect(checkpoint.completedThrough == 0)
            #expect(checkpoint.windows.isEmpty)
        }
    }

    @Test("Missing audio can retain validated prior text for incomplete display")
    func recoversPartialText() throws {
        try withRecording { directory, first, second in
            let cache = directory.appendingPathComponent("cache.json")
            var checkpoint = try open(cache, [first, second])
            let window = try #require(TranscriptionWindow.next(after: 0, available: 60, final: false))
            try checkpoint.append([TranscriptSegment(start: 1, end: 2, text: "Keep this evidence.")], for: window, savingTo: cache)
            try FileManager.default.removeItem(at: second)
            #expect(throws: (any Error).self) { try open(cache, [first, second]) }
            let recovered = TranscriptionCheckpoint.recoverPartial(at: cache, engine: "parakeet-v3", model: "v3", language: "auto")
            #expect(recovered?.segments.map(\.text) == ["Keep this evidence."])
            #expect(TranscriptionCheckpoint.recoverPartial(at: cache, engine: "parakeet-v3", model: "wrong", language: "auto") == nil)
            try Data("broken".utf8).write(to: cache)
            #expect(TranscriptionCheckpoint.recoverPartial(at: cache, engine: "parakeet-v3", model: "v3", language: "auto") == nil)
        }
    }
}
