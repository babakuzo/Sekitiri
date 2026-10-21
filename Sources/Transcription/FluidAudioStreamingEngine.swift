import AVFoundation
import FluidAudio
import Foundation

/// FluidAudio's cache-aware Nemotron streaming ASR adapter.
///
/// The 1120 ms tier is a practical default for a recording UI: it provides a
/// stable partial about once per second without the extra work of 560 ms.
/// FluidAudio downloads the model only on first use and the manager is loaded
/// only while a live transcription session is active.
actor FluidAudioStreamingEngine: LiveTranscriptionBackend {
    enum BackendError: Error, CustomStringConvertible {
        case notPrepared
        case invalidAudio

        var description: String {
            switch self {
            case .notPrepared: return "streaming ASR used before prepare()"
            case .invalidAudio: return "streaming ASR received an invalid audio chunk"
            }
        }
    }

    nonisolated let name = "fluidaudio-streaming"
    nonisolated let model = "nemotron-3.5-asr-streaming-multilingual-0.6b-1120ms-coreml"
    private let languageCode: String

    private var manager: StreamingNemotronMultilingualAsrManager?

    init(languageCode: String = "auto") {
        self.languageCode = languageCode
    }

    func prepare() async throws {
        guard manager == nil else { return }
        let shared = try await StreamingNemotronMultilingualAsrManager.downloadAndPreloadShared(
            languageCode: languageCode,
            chunkMs: 1120
        )
        let manager = StreamingNemotronMultilingualAsrManager()
        try await manager.loadFromShared(shared)
        self.manager = manager
    }

    func append(_ chunk: LiveAudioChunk) async throws -> String {
        guard let manager else { throw BackendError.notPrepared }
        guard !chunk.samples.isEmpty,
              chunk.sampleRate.isFinite,
              chunk.sampleRate > 0,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: chunk.sampleRate,
                  channels: 1,
                  interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(chunk.samples.count)
              )
        else {
            throw BackendError.invalidAudio
        }

        buffer.frameLength = AVAudioFrameCount(chunk.samples.count)
        chunk.samples.withUnsafeBufferPointer { source in
            guard let destination = buffer.floatChannelData?[0],
                  let baseAddress = source.baseAddress
            else { return }
            destination.update(from: baseAddress, count: chunk.samples.count)
        }

        // Back-pressure keeps audio bounded while the actor processes complete
        // model chunks. No model work runs on AVAudioEngine's callback thread.
        _ = try await manager.process(audioBuffer: buffer)
        return await manager.getPartialTranscript()
    }

    func finish() async throws -> String {
        guard let manager else { throw BackendError.notPrepared }
        return try await manager.finish()
    }

    func release() async {
        await manager?.cleanup()
        manager = nil
    }
}
