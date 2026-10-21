import Foundation
import Testing
@testable import SekitiriApp

@Suite("Resource stability")
struct ResourceStabilityTests {
    @Test("Live audio keeps only the newest bounded chunks")
    func boundedLiveAudio() async {
        let ingress = LiveAudioIngress()
        let (stream, continuation) = AsyncStream<LiveAudioChunk>.makeStream(
            bufferingPolicy: .bufferingNewest(2)
        )
        ingress.install(continuation)
        ingress.yield(LiveAudioChunk(samples: [1], sampleRate: 1))
        ingress.yield(LiveAudioChunk(samples: [2], sampleRate: 1))
        ingress.yield(LiveAudioChunk(samples: [3], sampleRate: 1))
        ingress.finish()

        var received: [Float] = []
        for await chunk in stream {
            received.append(contentsOf: chunk.samples)
        }
        #expect(received == [2, 3])
    }

    @Test("Eight gigabyte Macs do not retain summary weights")
    func summaryRetentionIsBounded() {
        #expect(LocalSummaryRuntime.warmRetentionSeconds <= 30)
    }
}
