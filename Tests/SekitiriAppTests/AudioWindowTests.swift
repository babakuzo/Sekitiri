import AVFoundation
import FluidAudio
import Foundation
import Testing
@testable import SekitiriApp

@Suite("Bounded local transcription windows")
struct AudioWindowTests {
    private func withAudio(_ body: ([URL]) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
            channels: 1, interleaved: false
        ))
        var urls: [URL] = []
        for index in 0..<3 {
            let url = folder.appendingPathComponent("part-\(index).caf")
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
                buffer.frameLength = 16_000
                let channel = try #require(buffer.floatChannelData?[0])
                for frame in 0..<16_000 { channel[frame] = Float(index + 1) / 10 }
                try file.write(from: buffer)
            }
            urls.append(url)
        }
        try body(urls)
    }

    @Test("Window reads across closed files without loading the recording")
    func boundedRead() throws {
        try withAudio { urls in
            #expect(try AudioWindowReader.duration(of: urls) == 3)
            let samples = try AudioWindowReader.read(sourceURLs: urls, start: 0.75, duration: 1.5)
            #expect(samples.count == 24_000)
            #expect(samples[0] == 0.1)
            #expect(samples[3_999] == 0.1)
            #expect(samples[4_000] == 0.2)
            #expect(samples[19_999] == 0.2)
            #expect(samples[20_000] == 0.3)
            #expect(samples.last == 0.3)
        }
    }

    @Test("The final fractional-second tail remains available")
    func shortTail() throws {
        try withAudio { urls in
            let samples = try AudioWindowReader.read(sourceURLs: urls, start: 2.95, duration: 0.05)
            #expect(samples.count == 800)
            #expect(samples.allSatisfy { $0 == 0.3 })
        }
    }

    @Test("Native-rate stereo audio is downmixed and resampled locally")
    func nativeRateConversion() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
            channels: 2, interleaved: false
        ))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
            buffer.frameLength = 48_000
            let channels = try #require(buffer.floatChannelData)
            for channel in 0..<2 {
                for frame in 0..<48_000 { channels[channel][frame] = 0.25 }
            }
            try file.write(from: buffer)
        }
        let samples = try AudioWindowReader.read(sourceURLs: [url], start: 0.25, duration: 0.5)
        #expect(abs(samples.count - 8_000) <= 1)
        #expect(abs(samples[samples.count / 2] - 0.25) < 0.001)
    }

    @Test("Missing files, unfinished tails and oversized windows fail explicitly")
    func rejectIncompleteOrUnboundedReads() throws {
        try withAudio { urls in
            #expect(throws: (any Error).self) {
                try AudioWindowReader.read(sourceURLs: urls, start: 2, duration: 2)
            }
            #expect(throws: (any Error).self) {
                try AudioWindowReader.read(sourceURLs: urls, start: 0, duration: 3600)
            }
            #expect(throws: (any Error).self) {
                try AudioWindowReader.read(sourceURLs: [urls[0].appendingPathExtension("missing")], start: 0, duration: 1)
            }
        }
    }

    @Test("Overlapping model results assign boundary words to one core")
    func reconcileOverlap() {
        // Fake recognizer emits the same words in adjacent context windows.
        let left = [
            TranscriptWord(text: "before", start: 24.2, end: 24.8),
            TranscriptWord(text: "boundary", start: 25.7, end: 26.3),
            TranscriptWord(text: "after", start: 26.5, end: 27.0),
        ]
        let right = left.map {
            TranscriptWord(text: $0.text, start: $0.start - 24, end: $0.end - 24)
        }
        let kept = ParakeetEngine.retainedWords(left, offset: 0, retaining: 0..<26)
            + ParakeetEngine.retainedWords(right, offset: 24, retaining: 26..<52)
        #expect(kept.map(\.text) == ["before", "boundary", "after"])
        #expect(kept[1].start == 25.7)
        #expect(kept[1].end == 26.3)
    }

    @Test("Model padding cannot introduce speech outside the recorded tail")
    func paddedTailBounds() {
        let words = [
            TranscriptWord(text: "Oui.", start: 0.01, end: 0.1),
            TranscriptWord(text: "padding", start: 0.2, end: 0.3),
        ]
        let kept = ParakeetEngine.retainedWords(
            words, offset: 26, retaining: 26..<26.05, reading: 24..<26.05
        )
        #expect(kept.map(\.text) == ["Oui."])
        #expect(kept.first?.end == 26.05)
    }
}
