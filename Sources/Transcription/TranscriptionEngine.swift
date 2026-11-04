import Foundation

/// One recognized word, relative to its track's own start. Confidence is the
/// mean token probability reported by the recognizer (0...1) when available.
struct TranscriptWord: Codable, Sendable, Equatable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    var confidence: Float?
}

/// One timed span of recognized speech from a single track, relative to that
/// track's own start. `words` is absent in checkpoints written before word
/// timings were retained.
struct TranscriptSegment: Codable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    var words: [TranscriptWord]? = nil
}

/// The next stretch of a track to recognize. `hasSpeech` is false when voice
/// activity detection found nothing worth decoding, so the window can be
/// committed as silent without running the recognizer.
struct WindowPlan: Sendable, Equatable {
    let window: TranscriptionWindow
    var hasSpeech: Bool = true
}

/// A speech-to-text engine quill can run locally. Engines are prepared lazily
/// (model download + load) when the transcription queue has work and released
/// when it drains, so quill never idles holding gigabytes of model weights.
protocol TranscriptionEngine: Sendable {
    /// Short engine identifier recorded as transcript.json provenance.
    var name: String { get }
    /// Concrete model identifier recorded as transcript.json provenance.
    var model: String { get }
    func prepare() async throws
    func transcribe(_ audio: URL) async throws -> [TranscriptSegment]
    func release() async
}

protocol WindowedTranscriptionEngine: TranscriptionEngine {
    /// Choose the next window after `completed` seconds. Engines with voice
    /// activity detection end windows in pauses; the default uses fixed lengths.
    func planWindow(sourceURLs: [URL], after completed: TimeInterval,
                    available: TimeInterval, final: Bool) async throws -> WindowPlan?
    func transcribeWindow(sourceURLs: [URL], start: TimeInterval, duration: TimeInterval,
                          retaining: Range<TimeInterval>?) async throws -> [TranscriptSegment]
}

/// Engines that can bias recognition toward names and terms for a meeting.
protocol VocabularyConfigurable: Sendable {
    func setVocabulary(_ terms: [String]) async
}

extension WindowedTranscriptionEngine {
    func planWindow(sourceURLs: [URL], after completed: TimeInterval,
                    available: TimeInterval, final: Bool) async throws -> WindowPlan? {
        TranscriptionWindow.next(after: completed, available: available, final: final).map { WindowPlan(window: $0) }
    }
}
