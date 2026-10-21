import AVFoundation
import Foundation
import Testing
@testable import SekitiriApp

private actor CoordinatorTestEngine: WindowedTranscriptionEngine {
    nonisolated let name = "test-local"
    nonisolated let model = "synthetic"
    private var failureCore: Double?
    private var blocked = false
    private var blockNextWindow = false
    private var gate: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private let cancellationEvents: AsyncStream<Void>
    private let cancellationContinuation: AsyncStream<Void>.Continuation
    private(set) var calls: [Double] = []
    private(set) var releasedDuringDecode = false
    private(set) var releases = 0

    init(failureCore: Double? = nil, blockNextWindow: Bool = false) {
        self.failureCore = failureCore
        self.blockNextWindow = blockNextWindow
        let cancellation = AsyncStream<Void>.makeStream()
        cancellationEvents = cancellation.stream
        cancellationContinuation = cancellation.continuation
    }

    func prepare() async throws {}
    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] { [] }
    func release() async {
        releases += 1
        if blocked { releasedDuringDecode = true }
    }
    func clearFailure() { failureCore = nil }

    func waitUntilDecoding() async {
        if blocked { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitForCancellation() async {
        for await _ in cancellationEvents { return }
    }

    func unblockDecode() {
        gate?.resume()
        gate = nil
    }

    func transcribeWindow(sourceURLs: [URL], start: TimeInterval, duration: TimeInterval,
                          retaining: Range<TimeInterval>?) async throws -> [TranscriptSegment] {
        let core = retaining ?? start..<(start + duration)
        calls.append(core.lowerBound)
        if blockNextWindow {
            blockNextWindow = false
            blocked = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            let cancellationSignal = cancellationContinuation
            await withTaskCancellationHandler {
                await withCheckedContinuation { gate = $0 }
            } onCancel: {
                cancellationSignal.yield(())
            }
            blocked = false
        }
        if failureCore == core.lowerBound { throw CocoaError(.fileReadUnknown) }
        let segmentEnd = min(core.upperBound, core.lowerBound + 1)
        return [TranscriptSegment(start: core.lowerBound, end: segmentEnd,
                                  text: "Saved speech at \(Int(core.lowerBound)) seconds.")]
    }
}

@Suite("Authoritative transcription coordinator", .timeLimit(.minutes(1)))
struct TranscriptionCoordinatorTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeAudio(to url: URL, seconds: Int) throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ))
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: format.commonFormat, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        buffer.frameLength = 8_000
        for index in 0..<8_000 { buffer.floatChannelData![0][index] = 0 }
        for _ in 0..<(seconds * 2) { try file.write(from: buffer) }
        file.close()
    }

    private func createRecording(in directory: URL, system: Bool = false, missingSystem: Bool = false,
                                 seconds: Int = 60) throws {
        try writeAudio(to: directory.appendingPathComponent("mic.caf"), seconds: seconds)
        if system && !missingSystem {
            try writeAudio(to: directory.appendingPathComponent("system.caf"), seconds: seconds)
        }
        let metadata: [String: Any] = [
            "files": system ? ["mic": "mic.caf", "system": "system.caf"] : ["mic": "mic.caf"],
            "start_offset_ms": system ? ["mic": 100, "system": 500] : ["mic": 100]
        ]
        try JSONSerialization.data(withJSONObject: metadata).write(to: directory.appendingPathComponent("meta.json"))
        try Data(#"{"engine":"parakeet-v3","language":"en"}"#.utf8)
            .write(to: directory.appendingPathComponent("transcription-settings.json"))
    }

    private func enqueueAndWait(_ directory: URL, coordinator: TranscriptionCoordinator) async -> [TranscriptionCoordinator.Status] {
        let (events, continuation) = AsyncStream<TranscriptionCoordinator.Status>.makeStream()
        await coordinator.setStatusHandler { status in
            if case .ready(_, let issues) = status, issues.isEmpty {
                // Verify the commit at the ready callback, before the worker
                // can continue or the consuming test receives the event.
                #expect(TranscriptIntegrity.isComplete(at: directory))
            }
            continuation.yield(status)
            if case .idle = status { continuation.finish() }
        }
        await coordinator.enqueue(directory)
        var statuses: [TranscriptionCoordinator.Status] = []
        for await status in events { statuses.append(status) }
        return statuses
    }

    @Test("Both tracks produce source-aligned durable Markdown and JSON before ready")
    func completeTwoTrackCommit() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try createRecording(in: directory, system: true, seconds: 30)
        let engine = CoordinatorTestEngine()
        let coordinator = TranscriptionCoordinator(engineFactory: { _, _ in engine }, runHooks: false,
                                                   transcriptionEnabled: { true }, speakerEnrichmentEnabled: { false })
        let statuses = await enqueueAndWait(directory, coordinator: coordinator)
        #expect(statuses.contains { if case .ready(_, let issues) = $0 { return issues.isEmpty }; return false })
        #expect(TranscriptIntegrity.isComplete(at: directory))
        let transcript = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: directory.appendingPathComponent("transcript.json")))
        #expect(transcript.trackOutcomes.count == 2)
        #expect(transcript.segments.map(\.start_ms) == [100, 500, 26_100, 26_500])
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("transcript.md").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(TranscriptIntegrity.markerFilename).path))
        #expect(await engine.calls == [0, 26, 0, 26])
    }

    @Test("A missing requested track preserves available speech and never marks completion")
    func missingTrackIsIncomplete() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try createRecording(in: directory, system: true, missingSystem: true, seconds: 30)
        let engine = CoordinatorTestEngine()
        let coordinator = TranscriptionCoordinator(engineFactory: { _, _ in engine }, runHooks: false,
                                                   transcriptionEnabled: { true }, speakerEnrichmentEnabled: { false })
        _ = await enqueueAndWait(directory, coordinator: coordinator)
        let transcript = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: directory.appendingPathComponent("transcript.json")))
        #expect(!TranscriptIntegrity.isComplete(at: directory))
        #expect(!transcript.segments.isEmpty)
        #expect(transcript.trackOutcomes.contains { $0.file == "system.caf" && $0.status == .missing })
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(TranscriptIntegrity.markerFilename).path))
    }

    @Test("A transient tail failure preserves saved speech and retry recognizes only unfinished windows")
    func retryResumesCheckpoint() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try createRecording(in: directory)
        let engine = CoordinatorTestEngine(failureCore: 26)
        let coordinator = TranscriptionCoordinator(engineFactory: { _, _ in engine }, runHooks: false,
                                                   transcriptionEnabled: { true }, speakerEnrichmentEnabled: { false })
        _ = await enqueueAndWait(directory, coordinator: coordinator)
        let partial = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: directory.appendingPathComponent("transcript.json")))
        #expect(!partial.isComplete)
        #expect(partial.segments.count == 1)
        #expect(await engine.calls == [0, 26])
        await engine.clearFailure()
        _ = await enqueueAndWait(directory, coordinator: coordinator)
        #expect(TranscriptIntegrity.isComplete(at: directory))
        #expect(await engine.calls == [0, 26, 26, 52])
        let complete = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: directory.appendingPathComponent("transcript.json")))
        #expect(complete.segments.count == 3)
    }

    @Test("Missing or corrupt source audio preserves previously committed speech", arguments: [false, true])
    func missingOrCorruptSourcePreservesPartial(corrupt: Bool) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try createRecording(in: directory)
        let engine = CoordinatorTestEngine(failureCore: 26)
        let coordinator = TranscriptionCoordinator(engineFactory: { _, _ in engine }, runHooks: false,
                                                   transcriptionEnabled: { true }, speakerEnrichmentEnabled: { false })
        _ = await enqueueAndWait(directory, coordinator: coordinator)
        let source = directory.appendingPathComponent("mic.caf")
        if corrupt { try Data("damaged audio".utf8).write(to: source) }
        else { try FileManager.default.removeItem(at: source) }
        await engine.clearFailure()
        _ = await enqueueAndWait(directory, coordinator: coordinator)
        let partial = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: directory.appendingPathComponent("transcript.json")))
        #expect(!TranscriptIntegrity.isComplete(at: directory))
        #expect(partial.segments.count == 1)
        #expect(partial.segments.first?.text == "Saved speech at 0 seconds.")
        #expect(await engine.calls == [0, 26])
    }

    @Test("Starting a recording drains in-flight recognition before releasing its model")
    func cancellationWaitsForDecode() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try createRecording(in: directory, seconds: 30)
        let engine = CoordinatorTestEngine(blockNextWindow: true)
        let coordinator = TranscriptionCoordinator(engineFactory: { _, _ in engine }, runHooks: false,
                                                   transcriptionEnabled: { true }, speakerEnrichmentEnabled: { false })
        await coordinator.enqueue(directory)
        await engine.waitUntilDecoding()
        let start = Task { await coordinator.beginRecording() }
        // The decoder is deliberately non-cancellable until its current call
        // returns, matching Core ML. Beginning capture must respect ownership.
        await engine.waitForCancellation()
        #expect(await engine.releases == 0)
        await engine.unblockDecode()
        await start.value
        #expect(!(await engine.releasedDuringDecode))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(TranscriptIntegrity.markerFilename).path))
        // Resume and drain the cancelled queue, so this test leaves no work.
        let (events, continuation) = AsyncStream<TranscriptionCoordinator.Status>.makeStream()
        await coordinator.setStatusHandler { status in
            continuation.yield(status)
            if case .idle = status { continuation.finish() }
        }
        await coordinator.endRecordingWithoutEnqueue()
        for await _ in events {}
        #expect(TranscriptIntegrity.isComplete(at: directory))
    }
}
