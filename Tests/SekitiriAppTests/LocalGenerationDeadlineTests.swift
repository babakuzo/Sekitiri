import Foundation
import Testing
@testable import SekitiriApp

@Suite("Local generation deadlines")
struct LocalGenerationDeadlineTests {
    private actor CleanupProbe {
        private var cleaned = false
        func finish() { cleaned = true }
        func isCleaned() -> Bool { cleaned }
    }

    @Test("Fast completion returns its value without waiting for the deadline")
    func successfulGeneration() async throws {
        let value = try await LocalGenerationDeadline.run(timeout: .seconds(30)) { 42 }
        #expect(value == 42)
    }

    @Test("Timeout waits for canceled inference cleanup before returning")
    func timeoutJoinsCleanup() async {
        let probe = CleanupProbe()
        do {
            let _: Int = try await LocalGenerationDeadline.run(timeout: .milliseconds(20)) {
                do {
                    try await Task.sleep(for: .seconds(30))
                    return 1
                } catch {
                    // Stand in for GPU synchronization that must complete even
                    // after cancellation, before another model can acquire RAM.
                    await probe.finish()
                    throw error
                }
            }
            Issue.record("The slow generation should time out")
        } catch {
            #expect(error is LocalGenerationDeadline.Exceeded)
        }
        #expect(await probe.isCleaned())
    }

    @Test("A generation deadline does not trigger automatic extraction retries")
    func noRetryAfterDeadline() async {
        var calls = 0
        do {
            _ = try await StructuredSummaryPipeline.run(
                transcript: "**[0:01] Alex:** I will send the report before Friday.",
                modelID: "fixture", tone: "Concise", progress: { _ in }
            ) { _, _, _ in
                calls += 1
                throw LocalGenerationDeadline.Exceeded()
            }
            Issue.record("The deadline should fail this generation")
        } catch { #expect(error is LocalGenerationDeadline.Exceeded) }
        #expect(calls == 1)
    }

    @Test("User cancellation also joins cleanup")
    func userCancellation() async {
        let started = CleanupProbe()
        let cleaned = CleanupProbe()
        let task = Task {
            try await LocalGenerationDeadline.run(timeout: .seconds(30)) {
                await started.finish()
                do {
                    try await Task.sleep(for: .seconds(30))
                    return 1
                } catch {
                    await cleaned.finish()
                    throw error
                }
            }
        }
        while !(await started.isCleaned()) { await Task.yield() }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled generation should not return a value")
        } catch { #expect(error is CancellationError) }
        #expect(await cleaned.isCleaned())
    }
}
