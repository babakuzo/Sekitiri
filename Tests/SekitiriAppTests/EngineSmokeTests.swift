import Foundation
import Testing
@testable import SekitiriApp

/// Opt-in end-to-end check of pause-aligned windows on the real model, using
/// speech synthesized locally with `say` (no recordings involved):
///
///     SEKITIRI_ENGINE_SMOKE=1 swift test --filter EngineSmokeTests
@Suite("Engine smoke", .enabled(if: ProcessInfo.processInfo.environment["SEKITIRI_ENGINE_SMOKE"] == "1"))
struct EngineSmokeTests {
    @Test("Pause-aligned windows recognize synthesized speech without seam losses")
    func synthesizedSpeech() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sentences = [
            "Good morning everyone, thanks for joining the weekly planning meeting.",
            "First, the budget review moves to Thursday afternoon.",
            "Second, Maria will send the updated roadmap before the end of the week.",
            "Third, we still need a decision on the hiring plan for the design team.",
            "Finally, please add your questions to the shared document before Monday.",
        ]
        let script = sentences.joined(separator: " [[slnc 1200]] ")
        let audio = directory.appendingPathComponent("speech.wav")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", audio.path, "--file-format=WAVE", "--data-format=LEI16@16000", script]
        try say.run()
        say.waitUntilExit()
        #expect(say.terminationStatus == 0)

        print("engine-smoke cached v3=\(ParakeetEngine.isCached(engine: "parakeet-v3")) "
            + "ultra=\(ParakeetEngine.isCached(engine: "parakeet-ultra")) default=\(Config.transcriptionEngine())")
        let engineName = ProcessInfo.processInfo.environment["SEKITIRI_ENGINE"] ?? "parakeet-v3"
        let engine = ParakeetEngine(version: ParakeetEngine.version(forEngine: engineName))
        try await engine.prepare()
        defer { Task { await engine.release() } }
        let duration = try AudioWindowReader.duration(of: [audio])
        var completed: TimeInterval = 0
        var segments: [TranscriptSegment] = []
        var windows: [WindowPlan] = []
        let started = ProcessInfo.processInfo.systemUptime
        while let plan = try await engine.planWindow(sourceURLs: [audio], after: completed,
                                                     available: duration, final: true) {
            windows.append(plan)
            if plan.hasSpeech {
                let window = plan.window
                segments += try await engine.transcribeWindow(
                    sourceURLs: [audio], start: window.readStart, duration: window.readEnd - window.readStart,
                    retaining: window.coreStart..<window.coreEnd)
            }
            completed = plan.window.coreEnd
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let hypothesis = EchoSuppression.tokens(segments.map(\.text).joined(separator: " "))
        let reference = EchoSuppression.tokens(sentences.joined(separator: " "))
        var remaining = Dictionary(hypothesis.map { ($0, 1) }, uniquingKeysWith: +)
        let recalled = reference.filter { token in
            guard let count = remaining[token], count > 0 else { return false }
            remaining[token] = count - 1
            return true
        }.count
        let words = segments.flatMap { $0.words ?? [] }
        print("engine-smoke engine=\(engineName) audio=\(String(format: "%.1f", duration))s "
            + "windows=\(windows.map { String(format: "%.1f-%.1f%@", $0.window.coreStart, $0.window.coreEnd, $0.hasSpeech ? "" : "(silent)") }) "
            + "recall=\(recalled)/\(reference.count) words=\(words.count) "
            + "lowConfidence=\(words.filter { ($0.confidence ?? 1) < 0.5 }.count) elapsed=\(String(format: "%.2f", elapsed))s")
        #expect(Double(recalled) / Double(reference.count) >= 0.95)
        #expect(words.allSatisfy { $0.confidence != nil })
        #expect(windows.allSatisfy { $0.window.readEnd - $0.window.readStart < 15 })
    }

    @Test("An imported compressed file is transcribed end to end by the real pipeline")
    func importedFile() async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = work.appendingPathComponent("Recordings")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let sentences = [
            "Welcome to the quarterly review of the support team.",
            "Response times improved by twenty percent since August.",
            "Daniel will draft the new escalation guide by Friday.",
        ]
        let audio = work.appendingPathComponent("Support review.m4a")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", audio.path, "--file-format=m4af", "--data-format=aac",
                         sentences.joined(separator: " [[slnc 900]] ")]
        try say.run()
        say.waitUntilExit()
        #expect(say.terminationStatus == 0)

        let session = try await AudioImport.importFile(audio, into: root)
        let engineName = ProcessInfo.processInfo.environment["SEKITIRI_ENGINE"] ?? "parakeet-v3"
        try Data(#"{"engine":"\#(engineName)","language":"auto"}"#.utf8)
            .write(to: session.appendingPathComponent("transcription-settings.json"))
        let coordinator = TranscriptionCoordinator(runHooks: false, transcriptionEnabled: { true },
                                                   speakerEnrichmentEnabled: { false })
        let (events, continuation) = AsyncStream<TranscriptionCoordinator.Status>.makeStream()
        await coordinator.setStatusHandler { status in
            continuation.yield(status)
            if case .idle = status { continuation.finish() }
        }
        await coordinator.enqueue(session)
        for await _ in events {}

        #expect(TranscriptIntegrity.isComplete(at: session))
        let transcript = try JSONDecoder().decode(
            Transcript.self, from: Data(contentsOf: session.appendingPathComponent("transcript.json")))
        let heard = Set(EchoSuppression.tokens(transcript.segments.map(\.text).joined(separator: " ")))
        let expected = EchoSuppression.tokens(sentences.joined(separator: " "))
        let recalled = expected.filter(heard.contains).count
        print("import-smoke engine=\(engineName) segments=\(transcript.segments.count) recall=\(recalled)/\(expected.count)")
        #expect(Double(recalled) / Double(expected.count) >= 0.9)
        #expect(transcript.segments.allSatisfy { $0.speaker == "them" })
    }
}
