import AVFoundation
import FluidAudio
import Foundation

/// Parakeet TDT 0.6B (v2, v3 or Ultra) via FluidAudio's Core ML port. v3 and
/// Ultra are multilingual; Ultra is a post-trained v3 with lower error rates at
/// the same speed. Models download once into FluidAudio's managed cache and all
/// inference runs on-device afterwards.
///
/// Windows are planned with Silero voice activity detection so each one ends
/// in a pause and fits a single 15-second encoder pass: no word is split by a
/// window boundary and stretches without speech are never decoded.
actor ParakeetEngine: WindowedTranscriptionEngine, VocabularyConfigurable {
    enum EngineError: Error, CustomStringConvertible {
        case notPrepared
        case unreadableAudio(URL, Error?)
        case missingWordTimings

        var description: String {
            switch self {
            case .notPrepared: return "parakeet engine used before prepare()"
            case .unreadableAudio(let url, let e):
                return "unreadable or empty audio \(url.lastPathComponent)"
                    + (e.map { ": \($0)" } ?? "")
            case .missingWordTimings:
                return "Speech recognition returned text without the timings needed to join audio windows safely."
            }
        }
    }

    nonisolated let name: String
    nonisolated let model: String
    nonisolated let languageCode: String
    private let version: AsrModelVersion
    private let languageHint: Language?

    private var manager: AsrManager?
    private var vad: VadManager?
    private var vocabulary: VocabularyBoostingSession?
    private var vocabularyTerms: [String] = []
    private var ctcModels: CtcModels?

    init(version: AsrModelVersion = .v3, languageCode: String = "auto") {
        self.version = version
        self.languageCode = languageCode
        let baseCode = languageCode.split(separator: "-").first.map(String.init) ?? languageCode
        // The hint only filters tokens by alphabet. It is never applied to
        // "auto": a French hint measurably hurts mixed English/French speech.
        self.languageHint = version == .v2 ? nil : Language(rawValue: baseCode)
        switch version {
        case .ultra:
            name = "parakeet-ultra"
            model = "parakeet-ultra-coreml"
        case .v3:
            name = "parakeet-v3"
            model = "parakeet-tdt-0.6b-v3-coreml"
        default:
            name = "parakeet"
            model = "parakeet-tdt-0.6b-v2-coreml"
        }
    }

    /// Engine identifiers accepted in settings and transcript provenance.
    static func version(forEngine name: String) -> AsrModelVersion {
        switch name.lowercased() {
        case "parakeet", "parakeet-v2": return .v2
        case "parakeet-ultra", "ultra": return .ultra
        default: return .v3
        }
    }

    /// True when the model for `engine` is already downloaded and load-ready.
    static func isCached(engine name: String) -> Bool {
        let version = version(forEngine: name)
        return AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
    }

    /// Download a model ahead of time without loading it into memory.
    static func download(engine name: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await AsrModels.download(version: version(forEngine: name)) { update in
            progress(update.fractionCompleted)
        }
    }

    func prepare() async throws {
        guard manager == nil else { return }
        let models = try await AsrModels.downloadAndLoad(version: version)
        // Each window is a single encoder pass, so long-form chunk workers
        // would only add memory. The library picks the right boundary mode.
        let manager = AsrManager(config: ASRConfig(parallelChunkConcurrency: 1))
        try await manager.loadModels(models)
        self.manager = manager
        // Voice activity detection is a ~2 MB model. Without it, windows fall
        // back to fixed lengths rather than failing transcription.
        vad = try? await VadManager()
    }

    /// Custom vocabulary rescoring loads a separate ~100 MB keyword model, so
    /// it is only loaded when there are terms. The model stays cached while
    /// the engine is prepared; only the term list is rebuilt per meeting.
    /// Failure leaves ordinary recognition untouched.
    func setVocabulary(_ terms: [String]) async {
        guard terms != vocabularyTerms else { return }
        vocabularyTerms = terms
        guard !terms.isEmpty else {
            vocabulary = nil
            return
        }
        do {
            let ctc: CtcModels
            if let ctcModels {
                ctc = ctcModels
            } else {
                ctc = try await CtcModels.downloadAndLoad(variant: .ctc110m)
                ctcModels = ctc
            }
            let context = CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) })
            // Conservative thresholds: a wrongly replaced common word costs
            // more than a missed name (FluidAudio #967).
            vocabulary = try await VocabularyBoostingSession(
                vocabulary: context, ctcModels: ctc,
                thresholds: .init(cbw: 0, minSimilarity: 0.7))
        } catch {
            vocabulary = nil
        }
    }

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        guard let manager else { throw EngineError.notPrepared }

        // A track with no frames (recorder died before its first buffer)
        // makes AVFoundation raise an ObjC exception deep inside the
        // resampler — uncatchable from Swift, so it takes the whole daemon
        // down. Check readability up front instead.
        do {
            let probe = try AVAudioFile(forReading: audio)
            guard probe.length > 0 else { throw EngineError.unreadableAudio(audio, nil) }
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.unreadableAudio(audio, error)
        }

        var state = try TdtDecoderState()
        let result = try await manager.transcribe(audio, decoderState: &state, language: languageHint)
        try Task.checkCancellation()

        let words = Self.words(from: result.tokenTimings ?? [])
        guard !words.isEmpty else {
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty
                ? []
                : [TranscriptSegment(start: 0, end: result.duration, text: text)]
        }
        return Self.segments(from: words)
    }

    func release() async {
        if let manager { await manager.cleanup() }
        manager = nil
        vad = nil
        vocabulary = nil
        vocabularyTerms = []
        ctcModels = nil
    }

    /// Plan the next window so its core ends in the quietest stretch between
    /// `minimumCore` and `maximumCore` seconds. Live windows wait until the
    /// whole search range plus right context has been recorded.
    func planWindow(sourceURLs: [URL], after completed: TimeInterval,
                    available: TimeInterval, final: Bool) async throws -> WindowPlan? {
        guard let fixed = TranscriptionWindow.next(after: completed, available: available, final: final) else {
            return nil
        }
        guard let vad else { return WindowPlan(window: fixed) }
        let searchEnd = min(available, completed + TranscriptionWindow.coreDuration)
        let samples = try AudioWindowReader.read(sourceURLs: sourceURLs, start: completed,
                                                  duration: searchEnd - completed)
        guard !samples.isEmpty else { return WindowPlan(window: fixed, hasSpeech: false) }
        let probabilities: [Float]
        do {
            probabilities = try await vad.process(samples).map(\.probability)
        } catch {
            return WindowPlan(window: fixed)
        }
        try Task.checkCancellation()
        let frame = Double(VadManager.chunkSize) / AudioWindowReader.sampleRate
        let cut = fixed.coreEnd >= available - 0.000_1 && searchEnd >= available - 0.000_1
            ? fixed.coreEnd
            : Self.pauseCut(probabilities: probabilities, frameDuration: frame,
                            from: completed, searchEnd: searchEnd)
        let coreFrames = Int(((cut - completed) / frame).rounded(.up))
        let speech = probabilities.prefix(max(1, coreFrames)).contains { $0 >= Self.speechFloor }
        let window = TranscriptionWindow(
            coreStart: completed, coreEnd: cut,
            readStart: max(0, completed - TranscriptionWindow.contextDuration),
            readEnd: min(available, cut + TranscriptionWindow.contextDuration))
        return WindowPlan(window: window, hasSpeech: speech)
    }

    /// Silero probability below which a frame is treated as certainly empty.
    /// Deliberately far under the usual 0.5 speech threshold: skipping is only
    /// for windows where even quiet, distant speech is implausible.
    static let speechFloor: Float = 0.15

    /// Choose a cut inside the longest low-probability run that starts after
    /// the minimum core length, preferring later runs on ties. Without any
    /// quiet run, cut at the least speech-like frame.
    static func pauseCut(probabilities: [Float], frameDuration: TimeInterval,
                         from start: TimeInterval, searchEnd: TimeInterval) -> TimeInterval {
        let quiet: Float = 0.35
        let firstFrame = Int((TranscriptionWindow.minimumCore / frameDuration).rounded(.up))
        let lastFrame = min(probabilities.count, Int(((searchEnd - start) / frameDuration).rounded(.down))) - 1
        guard firstFrame <= lastFrame else { return searchEnd }
        var best: (start: Int, length: Int)?
        var runStart: Int?
        for index in firstFrame...lastFrame + 1 {
            let isQuiet = index <= lastFrame && probabilities[index] < quiet
            if isQuiet, runStart == nil { runStart = index }
            if !isQuiet, let begin = runStart {
                let length = index - begin
                if best == nil || length >= best!.length { best = (begin, length) }
                runStart = nil
            }
        }
        let frameIndex: Int
        if let best {
            frameIndex = best.start + best.length / 2
        } else {
            frameIndex = (firstFrame...lastFrame).min { probabilities[$0] < probabilities[$1] } ?? lastFrame
        }
        let cut = start + (Double(frameIndex) + 0.5) * frameDuration
        return min(searchEnd, max(start + TranscriptionWindow.minimumCore, cut))
    }

    /// Recognize one bounded window from finalized recording segments, returning
    /// times relative to the track. `retaining` assigns words to adjacent core
    /// intervals by midpoint while the surrounding audio provides context.
    func transcribeWindow(
        sourceURLs: [URL], start: TimeInterval, duration: TimeInterval,
        retaining: Range<TimeInterval>? = nil
    ) async throws -> [TranscriptSegment] {
        guard let manager else { throw EngineError.notPrepared }
        var samples = try AudioWindowReader.read(sourceURLs: sourceURLs, start: start, duration: duration)
        guard !samples.isEmpty else { return [] }
        // A recording may stop immediately after a core boundary. Keep that
        // genuine tail rather than failing FluidAudio's 300ms minimum input.
        let minimumSamples = Int(AudioWindowReader.sampleRate * 0.3)
        if samples.count < minimumSamples {
            samples.append(contentsOf: repeatElement(0, count: minimumSamples - samples.count))
        }
        var state = try TdtDecoderState()
        let result = try await manager.transcribe(samples, decoderState: &state, language: languageHint)
        try Task.checkCancellation()
        let timings = result.tokenTimings ?? []
        var words = Self.words(from: timings)
        if words.isEmpty {
            guard result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw EngineError.missingWordTimings
            }
            return []
        }
        if let vocabulary,
           let output = await vocabulary.rescore(text: result.text, tokenTimings: timings, audioSamples: samples),
           output.wasModified {
            words = Self.applying(output.replacements, to: words)
        }
        return Self.segments(from: Self.retainedWords(
            words, offset: start, retaining: retaining ?? start..<(start + duration),
            reading: start..<(start + duration)
        ))
    }

    /// Words with the mean confidence of their sub-word tokens.
    static func words(from timings: [TokenTiming]) -> [TranscriptWord] {
        var result: [TranscriptWord] = []
        var text = ""
        var start: TimeInterval = 0
        var end: TimeInterval = 0
        var confidences: [Float] = []

        func flush() {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                let mean = confidences.isEmpty ? nil : confidences.reduce(0, +) / Float(confidences.count)
                result.append(TranscriptWord(text: trimmed, start: start, end: end, confidence: mean))
            }
            text = ""
            confidences = []
        }

        for timing in timings {
            let token = timing.token
            if token.isEmpty || token == "<blank>" || token == "<pad>" { continue }
            let boundary = token.hasPrefix("▁") || token.hasPrefix(" ")
            if boundary || text.isEmpty {
                flush()
                text = String(token.drop(while: { $0 == "▁" || $0 == " " }))
                start = timing.startTime
            } else {
                text += token
            }
            end = timing.endTime
            if timing.confidence.isFinite { confidences.append(timing.confidence) }
        }
        flush()
        return result
    }

    /// Apply vocabulary replacements to timed words. Each replacement consumes
    /// the first matching run of words after the previous one, keeping the
    /// run's timing and its trailing punctuation.
    static func applying(_ replacements: [VocabularyRescorer.RescoringResult],
                         to words: [TranscriptWord]) -> [TranscriptWord] {
        func key(_ value: String) -> String {
            value.lowercased().trimmingCharacters(in: .punctuationCharacters)
        }
        var output = words
        var cursor = 0
        for replacement in replacements where replacement.shouldReplace {
            guard let newText = replacement.replacementWord, !newText.isEmpty else { continue }
            let original = replacement.originalWord.split(separator: " ").map { key(String($0)) }
            guard !original.isEmpty, output.count >= original.count else { continue }
            var found: Int?
            for index in cursor...(output.count - original.count)
            where (0..<original.count).allSatisfy({ key(output[index + $0].text) == original[$0] }) {
                found = index
                break
            }
            guard let first = found else { continue }
            let run = output[first..<(first + original.count)]
            let lastText = run.last!.text
            let trailing = String(lastText.reversed().prefix(while: { $0.isPunctuation }).reversed())
            let merged = TranscriptWord(
                text: newText + trailing, start: run.first!.start, end: run.last!.end,
                confidence: run.compactMap(\.confidence).min())
            output.replaceSubrange(first..<(first + original.count), with: [merged])
            cursor = first + 1
            if cursor >= output.count { break }
        }
        return output
    }

    static func retainedWords(
        _ words: [TranscriptWord], offset: TimeInterval, retaining: Range<TimeInterval>,
        reading: Range<TimeInterval>? = nil
    ) -> [TranscriptWord] {
        words.compactMap { word in
            var start = word.start + offset
            var end = word.end + offset
            guard start.isFinite, end.isFinite, end >= start else { return nil }
            if let reading {
                guard end > reading.lowerBound, start < reading.upperBound else { return nil }
                start = max(start, reading.lowerBound)
                end = min(end, reading.upperBound)
            }
            guard retaining.contains((start + end) / 2) else { return nil }
            return TranscriptWord(text: word.text, start: start, end: end, confidence: word.confidence)
        }
    }

    /// Group word timings into readable segments: break on sentence-ending
    /// punctuation, a silence gap, or a hard length cap so a run-on speaker
    /// still wraps. Each segment keeps its words for later speaker assignment.
    static func segments(from words: [TranscriptWord]) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        var current: [TranscriptWord] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            out.append(TranscriptSegment(
                start: first.start,
                end: last.end,
                text: current.map(\.text).joined(separator: " "),
                words: current
            ))
            current = []
        }

        for word in words {
            if let last = current.last, word.start - last.end > 1.0 {
                flush()
            }
            current.append(word)
            let endsSentence = word.text.hasSuffix(".")
                || word.text.hasSuffix("?")
                || word.text.hasSuffix("!")
            if endsSentence || current.count >= 60 {
                flush()
            }
        }
        flush()
        return out
    }
}
