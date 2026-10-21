import Foundation

/// One timed span of recognized speech from a single track, relative to that
/// track's own start.
struct TranscriptSegment: Codable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
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
    func transcribeWindow(sourceURLs: [URL], start: TimeInterval, duration: TimeInterval,
                          retaining: Range<TimeInterval>?) async throws -> [TranscriptSegment]
}

/// A bounded piece of mono PCM captured directly from the microphone.
/// The samples are copied before crossing into the asynchronous streaming
/// pipeline, keeping AVAudioEngine's realtime thread independent of model
/// loading and Core ML work.
struct LiveAudioChunk: Sendable {
    let samples: [Float]
    let sampleRate: Double

    var duration: TimeInterval {
        sampleRate > 0 ? Double(samples.count) / sampleRate : 0
    }
}

/// Thread-safe handoff from Core Audio's realtime callback to the async live
/// transcription consumer. The stream itself owns a small newest-first buffer;
/// when recognition falls behind, stale partial-transcript audio is discarded
/// instead of allowing a long meeting to grow memory without bound. The saved
/// recording remains authoritative and is never affected by these drops.
final class LiveAudioIngress: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<LiveAudioChunk>.Continuation?

    func install(_ continuation: AsyncStream<LiveAudioChunk>.Continuation) {
        lock.lock()
        let previous = self.continuation
        self.continuation = continuation
        lock.unlock()
        previous?.finish()
    }

    func yield(_ chunk: LiveAudioChunk) {
        guard chunk.duration > 0 else { return }
        lock.lock()
        let continuation = self.continuation
        lock.unlock()
        continuation?.yield(chunk)
    }

    func finish() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.finish()
    }
}

/// A true streaming backend. The saved-file transcription path remains
/// separate and authoritative after recording stops.
protocol LiveTranscriptionBackend: Sendable {
    var name: String { get }
    var model: String { get }
    func prepare() async throws
    func append(_ chunk: LiveAudioChunk) async throws -> String
    func finish() async throws -> String
    func release() async
}
