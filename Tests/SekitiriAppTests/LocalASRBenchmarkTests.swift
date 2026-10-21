import Darwin
import FluidAudio
import Foundation
import Testing
@testable import SekitiriApp

/// Opt-in end-to-end checks against consented local speech and manual references.
/// FluidAudio's offline switch blocks downloads and destructive cache recovery.
@Suite("Local speech accuracy and speed benchmark")
struct LocalASRBenchmarkTests {
    struct Manifest: Decodable {
        let fixtures: [Fixture]
    }
    struct Fixture: Decodable {
        let id: String
        let audio_file: String
        let reference: String
        let maximum_wer: Double?
        let required_phrases: [String]?
    }

    @Test("Cached v3 mixed-language fixtures", .enabled(if: ProcessInfo.processInfo.environment["SEKITIRI_ASR_BENCHMARK"] == "1"))
    func cachedModelBenchmark() async throws {
        let manifestPath = try #require(ProcessInfo.processInfo.environment["SEKITIRI_ASR_BENCHMARK_MANIFEST"])
        let manifestURL = URL(fileURLWithPath: manifestPath)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        #expect(!manifest.fixtures.isEmpty)
        let cache = AsrModels.defaultCacheDirectory(for: .v3)
        try #require(AsrModels.modelsExist(at: cache, version: .v3), "Install v3 using the app first. This benchmark never downloads models.")

        let previousOfflineMode = ModelHub.offlineMode
        ModelHub.offlineMode = true
        defer { ModelHub.offlineMode = previousOfflineMode }
        let engine = ParakeetEngine(version: .v3, languageCode: "auto")
        do {
            let loadStart = ProcessInfo.processInfo.systemUptime
            try await engine.prepare()
            let loadSeconds = ProcessInfo.processInfo.systemUptime - loadStart
            for fixture in manifest.fixtures {
                let audio = manifestURL.deletingLastPathComponent().appendingPathComponent(fixture.audio_file)
                let duration = try AudioWindowReader.duration(of: [audio])
                let inferenceStart = ProcessInfo.processInfo.systemUptime
                var completed: TimeInterval = 0
                var segments: [TranscriptSegment] = []
                while let window = TranscriptionWindow.next(after: completed, available: duration, final: true) {
                    segments += try await engine.transcribeWindow(
                        sourceURLs: [audio], start: window.readStart,
                        duration: window.readEnd - window.readStart,
                        retaining: window.coreStart..<window.coreEnd
                    )
                    completed = window.coreEnd
                }
                let inferenceSeconds = ProcessInfo.processInfo.systemUptime - inferenceStart
                let text = segments.map(\.text).joined(separator: " ")
                let wer = try Self.wordErrorRate(reference: fixture.reference, hypothesis: text)
                var usage = rusage()
                getrusage(RUSAGE_SELF, &usage)
                let report: [String: Any] = [
                    "id": fixture.id, "model": engine.model, "language": "auto",
                    "audio_seconds": duration, "model_load_seconds": loadSeconds,
                    "inference_seconds": inferenceSeconds,
                    "realtime_factor": duration > 0 ? inferenceSeconds / duration : 0,
                    "process_peak_rss_megabytes": Double(usage.ru_maxrss) / 1_048_576,
                    "word_error_rate": wer, "transcript": text,
                ]
                print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
                #expect(wer <= (fixture.maximum_wer ?? 0.15), "Fixture \(fixture.id) exceeded word-error target.")
                let normalized = Self.words(text).joined(separator: " ")
                for phrase in fixture.required_phrases ?? [] {
                    #expect(normalized.contains(Self.words(phrase).joined(separator: " ")), "Missing important name or number: \(phrase)")
                }
            }
            await engine.release()
        } catch {
            await engine.release()
            throw error
        }
    }

    static func words(_ text: String) -> [String] {
        let normalized = text.precomposedStringWithCompatibilityMapping
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "’", with: "'")
        let expression = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+(?:'[\\p{L}\\p{N}]+)*")
        return expression.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized))
            .compactMap { Range($0.range, in: normalized).map { String(normalized[$0]) } }
    }

    static func wordErrorRate(reference: String, hypothesis: String) throws -> Double {
        let expected = words(reference)
        let actual = words(hypothesis)
        // WER has no denominator for silence. For these strict fixtures use
        // 0 only for no recognized words, and 1 for any hallucinated speech.
        guard !expected.isEmpty else { return actual.isEmpty ? 0 : 1 }
        var row = Array(0...actual.count)
        for (i, expectedWord) in expected.enumerated() {
            var next = [i + 1]
            for (j, actualWord) in actual.enumerated() {
                next.append(min(next[j] + 1, row[j + 1] + 1, row[j] + (expectedWord == actualWord ? 0 : 1)))
            }
            row = next
        }
        return Double(row[actual.count]) / Double(expected.count)
    }

    @Test("Word-error scoring counts substitutions, insertions and deletions")
    func scoring() throws {
        #expect(Self.words("L’équipe, déjà! Let's go.") == ["l'équipe", "déjà", "let's", "go"])
        #expect(try Self.wordErrorRate(reference: "Bonjour Emma, 450 euros!", hypothesis: "bonjour emma 450 euros") == 0)
        #expect(try Self.wordErrorRate(reference: "one two three", hypothesis: "one three") == 1.0 / 3)
        #expect(try Self.wordErrorRate(reference: "one two three", hypothesis: "one new two three") == 1.0 / 3)
        #expect(try Self.wordErrorRate(reference: "one two three", hypothesis: "one four three") == 1.0 / 3)
        #expect(try Self.wordErrorRate(reference: "", hypothesis: "") == 0)
        #expect(try Self.wordErrorRate(reference: "", hypothesis: "hallucinated speech") == 1)
    }
}
