import Darwin
import FluidAudio
import Foundation
import Testing
#if canImport(MLX)
import MLX
#endif
@testable import SekitiriApp

/// Synthetic, opt-in inference checks. Normal test runs never load or download
/// a model. Run this suite alone: concurrent inference invalidates RAM results.
@Suite("Local pipeline inference and sampled memory", .serialized)
struct LocalPipelineBenchmarkTests {
    private let environment = ProcessInfo.processInfo.environment

    /// Separate explicit action; inference methods never initiate downloads.
    @Test("Download explicitly selected public summary candidates", .enabled(if: ProcessInfo.processInfo.environment["SEKITIRI_PIPELINE_DOWNLOAD_MODELS"] == "1"))
    func downloadSelectedCandidates() async throws {
        let requested = (environment["SEKITIRI_PIPELINE_MODELS"] ?? "qwen08B").split(separator: ",").map(String.init)
        for name in requested {
            if name == "afm" { continue }
            let model = try #require(name == "qwen08B" ? LocalSummaryModel.qwen08B : name == "qwen2B" ? .qwen2B : nil,
                "Select qwen08B or qwen2B for an explicit public-model download")
            if !(await LocalSummaryRuntime.shared.isDownloaded(model: model)) {
                try await LocalSummaryRuntime.shared.download(model: model) { _ in }
            }
            #expect(await LocalSummaryRuntime.shared.isDownloaded(model: model))
        }
    }

    @Test("Active inference lease cancels and releases before recording", .enabled(if: ProcessInfo.processInfo.environment["SEKITIRI_PIPELINE_LIFECYCLE"] == "1"))
    func cancellationAndUnloadLifecycle() async throws {
        let model: LocalSummaryModel = environment["SEKITIRI_PIPELINE_MODELS"] == "qwen08B" ? .qwen08B : .qwen2B
        try #require(await LocalSummaryRuntime.shared.isDownloaded(model: model), "Lifecycle test requires an explicitly cached model")
        await LocalSummaryRuntime.shared.unload()
        await LocalSummaryRuntime.shared.setWarmRetentionForBenchmark(seconds: 60)
        let gate = PipelineLeaseGate()
        let recorder = PipelineMemoryRecorder(includeMetal: true)
        let sampling = Task { await recorder.run() }
        await recorder.mark("lifecycle_baseline")
        let operation = Task {
            do {
                return try await LocalSummaryRuntime.shared.withContainer(model: model) { _ in
                    await gate.signal("entered")
                    // Keep the same model lease as real generation while the
                    // unload request exercises cancellation and release ordering.
                    try await Task.sleep(for: .seconds(600))
                    return "unexpected_completion"
                }
            } catch {
                await gate.signal("failed: \(error)")
                throw error
            }
        }
        let gateResult = await gate.wait()
        #expect(gateResult == "entered", "Model lease could not start: \(gateResult)")
        await recorder.mark("active_model_lease")
        var rejectedConcurrentLease = false
        do {
            _ = try await LocalSummaryRuntime.shared.withContainer(model: model) { _ in 1 }
        } catch LocalSummaryRuntimeError.busy {
            rejectedConcurrentLease = true
        } catch { Issue.record(error, "Concurrent lease returned an unexpected error") }
        let cancelStart = ProcessInfo.processInfo.systemUptime
        await recorder.mark("cancelling_for_capture")
        await LocalSummaryRuntime.shared.unload()
        var operationCancelled = false
        do { _ = try await operation.value }
        catch is CancellationError { operationCancelled = true }
        catch { Issue.record(error, "Cancelled operation returned an unexpected error") }
        let cancelSeconds = ProcessInfo.processInfo.systemUptime - cancelStart
        await recorder.mark("unload_returned")
        for _ in 0..<20 {
            if LocalSummaryRuntime.memorySnapshot().activeBytes <= 16 * 1_024 * 1_024 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let finalMemory = LocalSummaryRuntime.memorySnapshot()
        await recorder.mark("lifecycle_after_settle")
        await LocalSummaryRuntime.shared.setWarmRetentionForBenchmark(seconds: nil)
        await recorder.stop()
        await sampling.value
        try save(await recorder.report(), name: "\(model.engineID)-lifecycle-memory")
        try save(PipelineLifecycleReport(modelID: model.modelID, rejectedConcurrentLease: rejectedConcurrentLease,
            operationCancelled: operationCancelled, unloadSeconds: cancelSeconds,
            finalMLXActiveBytes: finalMemory.activeBytes, finalMLXCacheBytes: finalMemory.cacheBytes), name: "\(model.engineID)-lifecycle")
        #expect(rejectedConcurrentLease, "A second local model lease must be rejected while the first is active")
        #expect(operationCancelled, "Unload must cancel and await the active operation before capture proceeds")
        #expect(finalMemory.activeBytes <= 16 * 1_024 * 1_024, "Local weights remained allocated after unload")
    }

    @Test("Controlled bilingual extraction and current memory", .enabled(if: ProcessInfo.processInfo.environment["SEKITIRI_PIPELINE_BENCHMARK"] == "1"))
    func summaryInference() async throws {
        let fixtureURL = try environment["SEKITIRI_PIPELINE_SUMMARY_MANIFEST"].map { URL(fileURLWithPath: $0) }
            ?? #require(Bundle.module.url(forResource: "summary-benchmark.json", withExtension: nil))
        let manifest = try JSONDecoder().decode(PipelineSummaryManifest.self, from: Data(contentsOf: fixtureURL))
        let requested = (environment["SEKITIRI_PIPELINE_MODELS"] ?? "afm,qwen2B,qwen08B").split(separator: ",").map(String.init)
        let repetitions = max(1, Int(environment["SEKITIRI_PIPELINE_REPEATS"] ?? "2") ?? 2)
        for modelName in requested {
            let model: LocalSummaryModel? = modelName == "qwen08B" ? .qwen08B : modelName == "qwen2B" ? .qwen2B : nil
            if model == nil && modelName != "afm" && modelName != "sourceNotes" {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Unknown benchmark engine \(modelName)"])
            }
            if let model, !(await LocalSummaryRuntime.shared.isDownloaded(model: model)) {
                try save(PipelineAvailabilityReport(model: modelName, status: "not_measured_model_not_cached"), name: "\(modelName)-availability")
                continue
            }
            if modelName == "afm" && !LocalSummaryRuntime.appleFoundationModelAvailable {
                try save(PipelineAvailabilityReport(model: modelName, status: "not_measured_apple_unavailable"), name: "\(modelName)-availability")
                continue
            }
            if modelName != "sourceNotes" {
                await LocalSummaryRuntime.shared.unload()
                await LocalSummaryRuntime.shared.setWarmRetentionForBenchmark(seconds: 60)
            }
            let recorder = PipelineMemoryRecorder(includeMetal: model != nil)
            let sampling = Task { await recorder.run() }
            await recorder.mark("baseline")
            try await Task.sleep(for: .milliseconds(300))
            for repetition in 0..<repetitions {
                for fixture in manifest.fixtures {
                    let runID = "\(modelName)-\(fixture.id)-run\(repetition + 1)"
                    let start = ProcessInfo.processInfo.systemUptime
                    let phasePrefix = "\(runID):"
                    await recorder.mark(phasePrefix + "loading_or_inference")
                    do {
                        let result: SummaryGenerationResult
                        let callback: @MainActor @Sendable (SummaryProgress) -> Void = { progress in
                            Task { await recorder.mark(phasePrefix + String(describing: progress)) }
                        }
                        if modelName == "afm" {
                            result = try await NativeAFMEngine().summarize(transcript: fixture.transcript, prompt: SummaryTonePrompts.default(for: "Detailed"), tone: "Detailed", progress: callback)
                        } else if modelName == "sourceNotes" {
                            result = try await NativeSourceNotesEngine().summarize(transcript: fixture.transcript, prompt: SummaryTonePrompts.default(for: "Detailed"), tone: "Detailed", progress: callback)
                        } else {
                            result = try await NativeMLXEngine(model: model ?? .qwen2B).summarize(transcript: fixture.transcript, prompt: SummaryTonePrompts.default(for: "Detailed"), tone: "Detailed", progress: callback)
                        }
                        let seconds = ProcessInfo.processInfo.systemUptime - start
                        let document = try #require(result.document, "Actual engine must return validated structured evidence")
                        let evaluation = PipelineEvaluator.evaluate(document, fixture: fixture)
                        await recorder.mark(phasePrefix + "returned")
                        try save(PipelineSummaryReport(id: runID, modelID: result.modelID,
                            elapsedSeconds: seconds, inputTokens: result.inputTokens, passCount: result.passCount,
                            cacheCondition: modelName == "sourceNotes" ? "no_language_model_loaded" : repetition == 0 && fixture.id == manifest.fixtures.first?.id ? "first_run_model_unloaded_os_cache_uncontrolled" : "warm_same_process_60_second_retention_lease",
                            evaluation: evaluation, document: document, markdown: result.text), name: runID)
                        #expect(evaluation.passed, "\(runID) failed structured factual checks: \(evaluation.failures)")
                    } catch {
                        try save(PipelineFailureReport(id: runID, error: String(describing: error), elapsedSeconds: ProcessInfo.processInfo.systemUptime - start), name: runID)
                        Issue.record(error, "\(runID) could not produce a validated summary")
                    }
                }
            }
            if modelName != "sourceNotes" {
                await recorder.mark("before_explicit_unload")
                await LocalSummaryRuntime.shared.unload()
                await LocalSummaryRuntime.shared.setWarmRetentionForBenchmark(seconds: nil)
                await recorder.mark("after_explicit_unload")
            } else {
                await recorder.mark("source_notes_finished_without_model")
            }
            try await Task.sleep(for: .seconds(2))
            await recorder.mark("after_unload_settle")
            await recorder.stop()
            await sampling.value
            try save(await recorder.report(), name: "\(modelName)-memory")
        }
    }

    @Test("Cancel actual streamed local summary before capture", .enabled(if: ProcessInfo.processInfo.environment["SEKITIRI_PIPELINE_STREAM_CANCEL"] == "1"))
    func cancellationDuringGeneratedStream() async throws {
        let model: LocalSummaryModel = environment["SEKITIRI_PIPELINE_MODELS"] == "qwen2B" ? .qwen2B : .qwen08B
        try #require(await LocalSummaryRuntime.shared.isDownloaded(model: model), "Stream cancellation requires an explicitly cached candidate")
        let fixtureURL = try #require(Bundle.module.url(forResource: "summary-benchmark.json", withExtension: nil))
        let fixture = try JSONDecoder().decode(PipelineSummaryManifest.self, from: Data(contentsOf: fixtureURL)).fixtures[0]
        await LocalSummaryRuntime.shared.unload()
        await LocalSummaryRuntime.shared.setWarmRetentionForBenchmark(seconds: 60)
        let gate = PipelineLeaseGate()
        let recorder = PipelineMemoryRecorder(includeMetal: true)
        let sampling = Task { await recorder.run() }
        await recorder.mark("stream_cancel_baseline")
        let operation = Task {
            do {
                let result = try await NativeMLXEngine(model: model).summarize(
                    transcript: fixture.transcript, prompt: SummaryTonePrompts.default(for: "Detailed"), tone: "Detailed",
                    progress: { progress in
                        if case .generating = progress { Task { await gate.signal("generating") } }
                    })
                await gate.signal("unexpected_completed_summary")
                return result
            } catch {
                await gate.signal("failed: \(error)")
                throw error
            }
        }
        let gateResult = await gate.wait()
        #expect(gateResult == "generating", "Summary did not begin generation: \(gateResult)")
        // Progress is emitted immediately before streamResponse. Let its
        // producer enter prefill/decoding before requesting cancellation.
        try await Task.sleep(for: .milliseconds(100))
        await recorder.mark("stream_active_cancel_requested")
        let started = ProcessInfo.processInfo.systemUptime
        await LocalSummaryRuntime.shared.unload()
        var cancelled = false
        var returnedSummary = false
        do { _ = try await operation.value; returnedSummary = true }
        catch is CancellationError { cancelled = true }
        catch { Issue.record(error, "Stream cancellation returned an unexpected error") }
        let cancelSeconds = ProcessInfo.processInfo.systemUptime - started
        await recorder.mark("stream_unload_returned")
        for _ in 0..<20 {
            if LocalSummaryRuntime.memorySnapshot().activeBytes <= 16 * 1_024 * 1_024 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let finalMemory = LocalSummaryRuntime.memorySnapshot()
        await recorder.mark("stream_after_settle")
        await LocalSummaryRuntime.shared.setWarmRetentionForBenchmark(seconds: nil)
        await recorder.stop()
        await sampling.value
        try save(await recorder.report(), name: "\(model.engineID)-stream-cancel-memory")
        try save(PipelineStreamCancelReport(modelID: model.modelID, operationCancelled: cancelled,
            returnedSummary: returnedSummary, unloadSeconds: cancelSeconds, finalMLXActiveBytes: finalMemory.activeBytes,
            finalMLXCacheBytes: finalMemory.cacheBytes), name: "\(model.engineID)-stream-cancel")
        #expect(cancelled && !returnedSummary, "Cancelled generation must not return a partial or complete saved summary")
        #expect(finalMemory.activeBytes <= 16 * 1_024 * 1_024, "Stream producer or model retained GPU allocations after unload")
    }

    @Test("Saved bilingual speech and silence with phase memory", .enabled(if: ProcessInfo.processInfo.environment["SEKITIRI_PIPELINE_ASR"] == "1"))
    func transcriptionInference() async throws {
        let manifestPath = try #require(environment["SEKITIRI_ASR_BENCHMARK_MANIFEST"])
        let manifestURL = URL(fileURLWithPath: manifestPath)
        let manifest = try JSONDecoder().decode(LocalASRBenchmarkTests.Manifest.self, from: Data(contentsOf: manifestURL))
        try #require(AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3), "Cached v3 model required; no benchmark download")
        let previousOffline = ModelHub.offlineMode
        ModelHub.offlineMode = true
        defer { ModelHub.offlineMode = previousOffline }
        let recorder = PipelineMemoryRecorder(includeMetal: false)
        let sampling = Task { await recorder.run() }
        let engine = ParakeetEngine(version: .v3, languageCode: "auto")
        await recorder.mark("baseline")
        try await Task.sleep(for: .milliseconds(300))
        do {
            await recorder.mark("model_loading")
            let loadStart = ProcessInfo.processInfo.systemUptime
            try await engine.prepare()
            let loadSeconds = ProcessInfo.processInfo.systemUptime - loadStart
            for repetition in 0..<2 {
                for fixture in manifest.fixtures {
                    let audio = manifestURL.deletingLastPathComponent().appendingPathComponent(fixture.audio_file)
                    let duration = try AudioWindowReader.duration(of: [audio])
                    let start = ProcessInfo.processInfo.systemUptime
                    let runID = "asr-\(fixture.id)-run\(repetition + 1)"
                    await recorder.mark(runID + ":inference")
                    var completed: TimeInterval = 0
                    var segments: [TranscriptSegment] = []
                    while let window = TranscriptionWindow.next(after: completed, available: duration, final: true) {
                        segments += try await engine.transcribeWindow(sourceURLs: [audio], start: window.readStart,
                            duration: window.readEnd - window.readStart, retaining: window.coreStart..<window.coreEnd)
                        completed = window.coreEnd
                    }
                    let seconds = ProcessInfo.processInfo.systemUptime - start
                    let text = segments.map(\.text).joined(separator: " ")
                    let wer = try LocalASRBenchmarkTests.wordErrorRate(reference: fixture.reference, hypothesis: text)
                    let normalized = LocalASRBenchmarkTests.words(text).joined(separator: " ")
                    let missing = (fixture.required_phrases ?? []).filter { !normalized.contains(LocalASRBenchmarkTests.words($0).joined(separator: " ")) }
                    let passed = wer <= (fixture.maximum_wer ?? 0.15) && missing.isEmpty
                    try save(PipelineASRReport(id: runID, modelID: engine.model, audioSeconds: duration,
                        modelLoadSeconds: loadSeconds, elapsedSeconds: seconds, wordErrorRate: wer,
                        missingPhrases: missing, passed: passed, transcript: text), name: runID)
                    #expect(passed, "\(runID): WER \(wer), missing \(missing)")
                }
            }
        } catch {
            await engine.release()
            await recorder.stop()
            await sampling.value
            try save(await recorder.report(), name: "asr-memory")
            throw error
        }
        await recorder.mark("before_release")
        await engine.release()
        await recorder.mark("after_release")
        try await Task.sleep(for: .seconds(2))
        await recorder.mark("after_release_settle")
        await recorder.stop()
        await sampling.value
        try save(await recorder.report(), name: "asr-memory")
    }

    @Test("Evaluator rejects wrong ownership, unsupported tasks and missing evidence")
    func evaluatorRegression() throws {
        let url = try #require(Bundle.module.url(forResource: "summary-benchmark.json", withExtension: nil))
        let fixture = try JSONDecoder().decode(PipelineSummaryManifest.self, from: Data(contentsOf: url)).fixtures[0]
        let raw = """
        ## At a glance
        Budget remains open.
        ## Decisions
        - Buy a new tool.
        ## Action Items
        - [ ] Emma — send the revised proposal before Friday 23 October.
        ## Key Points
        _(none)_
        ## Open Questions and Risks
        - The delivery date is undecided.
        ## Summary
        A proposal was discussed.
        """
        let document = CanonicalSummaryBuilder.build(markdown: raw, transcript: fixture.transcript, modelID: "test", tone: "Detailed")
        let result = PipelineEvaluator.evaluate(document, fixture: fixture)
        #expect(!result.passed)
        #expect(result.failures.contains { $0.contains("owner") })
        #expect(result.failures.contains { $0.contains("decision") })
        #expect(result.failures.contains { $0.contains("evidence") })
    }

    private func save<T: Encodable>(_ value: T, name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        let directory = environment["SEKITIRI_PIPELINE_OUTPUT"].map { URL(fileURLWithPath: $0) }
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name + ".json"), options: .atomic)
        }
        print("PIPELINE_REPORT \(name)\n" + String(decoding: data, as: UTF8.self))
    }
}

private struct PipelineSummaryManifest: Decodable { let fixtures: [PipelineSummaryFixture] }
private struct PipelineSummaryFixture: Decodable {
    let id: String
    let transcript: String
    let decisions: [PipelineExpectedFact]
    let actions: [PipelineExpectedFact]
    let forbidden_decision_phrases: [String]
    let forbidden_action_phrases: [String]
    let required_open_question_phrases: [[String]]
}
private struct PipelineExpectedFact: Decodable {
    let id: String
    let phrases: [String]
    let source_quotes: [String]
    let owner: String?
    let due_phrases: [String]?
}
private struct PipelineEvaluation: Codable {
    let expectedDecisions: Int
    let matchedDecisions: Int
    let expectedActions: Int
    let matchedActions: Int
    let failures: [String]
    let passed: Bool
}

/// Requires the correct record type, exact owner/date fields and references to
/// the expected transcript passage. Phrase aliases are manually declared for
/// bilingual paraphrases; this score is deliberately not a general LLM judge.
private enum PipelineEvaluator {
    static func evaluate(_ document: CanonicalSummaryDocument, fixture: PipelineSummaryFixture) -> PipelineEvaluation {
        var failures: [String] = []
        var matchedDecisions = Set<String>()
        var matchedActions = Set<String>()
        let sources = Dictionary(uniqueKeysWithValues: document.sources.map { ($0.id, $0.quote) })
        func contains(_ text: String, _ phrase: String) -> Bool { normalize(text).contains(normalize(phrase)) }
        func evidence(_ ids: [String], expected: PipelineExpectedFact) -> Bool {
            ids.contains { id in sources[id].map { source in expected.source_quotes.contains { contains(source, $0) } } ?? false }
        }
        for fact in fixture.decisions {
            guard let claim = document.sections.decisions.first(where: { claim in fact.phrases.contains { contains(claim.text, $0) } }) else {
                failures.append("missing decision: \(fact.id)"); continue
            }
            if evidence(claim.evidenceSourceIDs, expected: fact) { matchedDecisions.insert(fact.id) }
            else { failures.append("wrong or missing decision evidence: \(fact.id)") }
        }
        for fact in fixture.actions {
            guard let action = document.actionItems.first(where: { action in fact.phrases.contains { contains(action.text, $0) } }) else {
                failures.append("missing action: \(fact.id)"); continue
            }
            var valid = true
            if normalize(action.owner ?? "") != normalize(fact.owner ?? "") { failures.append("wrong action owner: \(fact.id)"); valid = false }
            if let dates = fact.due_phrases, !dates.contains(where: { contains(action.dueDateText ?? "", $0) }) { failures.append("wrong action deadline: \(fact.id)"); valid = false }
            if !evidence(action.evidenceSourceIDs, expected: fact) { failures.append("wrong or missing action evidence: \(fact.id)"); valid = false }
            if valid { matchedActions.insert(fact.id) }
        }
        for claim in document.sections.decisions {
            if !fixture.decisions.contains(where: { fact in fact.phrases.contains { contains(claim.text, $0) } }) { failures.append("unexpected decision: \(claim.text)") }
            if fixture.forbidden_decision_phrases.contains(where: { contains(claim.text, $0) }) { failures.append("forbidden decision: \(claim.text)") }
        }
        for action in document.actionItems {
            if !fixture.actions.contains(where: { fact in fact.phrases.contains { contains(action.text, $0) } }) { failures.append("unexpected action: \(action.text)") }
            if fixture.forbidden_action_phrases.contains(where: { contains(action.text, $0) }) { failures.append("forbidden action: \(action.text)") }
        }
        let questions = document.sections.openQuestionsAndRisks.map(\.text).joined(separator: " ")
        for aliases in fixture.required_open_question_phrases where !aliases.contains(where: { contains(questions, $0) }) {
            failures.append("missing open question: \(aliases.joined(separator: " / "))")
        }
        return PipelineEvaluation(expectedDecisions: fixture.decisions.count, matchedDecisions: matchedDecisions.count,
            expectedActions: fixture.actions.count, matchedActions: matchedActions.count, failures: failures, passed: failures.isEmpty)
    }
    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

private struct PipelineSummaryReport: Encodable {
    let id: String; let modelID: String; let elapsedSeconds: Double; let inputTokens: Int; let passCount: Int
    let cacheCondition: String; let evaluation: PipelineEvaluation; let document: CanonicalSummaryDocument; let markdown: String
}
private struct PipelineASRReport: Encodable {
    let id: String; let modelID: String; let audioSeconds: Double; let modelLoadSeconds: Double; let elapsedSeconds: Double
    let wordErrorRate: Double; let missingPhrases: [String]; let passed: Bool; let transcript: String
}
private struct PipelineAvailabilityReport: Encodable { let model: String; let status: String }
private struct PipelineFailureReport: Encodable { let id: String; let error: String; let elapsedSeconds: Double }
private struct PipelineLifecycleReport: Encodable {
    let modelID: String; let rejectedConcurrentLease: Bool; let operationCancelled: Bool; let unloadSeconds: Double
    let finalMLXActiveBytes: Int; let finalMLXCacheBytes: Int
}
private struct PipelineStreamCancelReport: Encodable {
    let modelID: String; let operationCancelled: Bool; let returnedSummary: Bool; let unloadSeconds: Double
    let finalMLXActiveBytes: Int; let finalMLXCacheBytes: Int
}
private actor PipelineLeaseGate {
    private var signalValue: String?
    private var waiter: CheckedContinuation<String, Never>?
    func signal(_ value: String) {
        guard signalValue == nil else { return }
        signalValue = value
        waiter?.resume(returning: value)
        waiter = nil
    }
    func wait() async -> String {
        if let signalValue { return signalValue }
        return await withCheckedContinuation { waiter = $0 }
    }
}

private actor PipelineMemoryRecorder {
    private let includeMetal: Bool
    private var phase = "baseline"
    private var running = true
    private var samples: [PipelineMemorySample] = []
    private let started = ProcessInfo.processInfo.systemUptime
    init(includeMetal: Bool) { self.includeMetal = includeMetal }
    func mark(_ phase: String) { self.phase = phase; capture() }
    func stop() { capture(); running = false }
    func run() async {
        while running {
            capture()
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
    func report() -> PipelineMemoryReport {
        PipelineMemoryReport(processID: ProcessInfo.processInfo.processIdentifier,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory, sampleIntervalMilliseconds: 200,
            interpretation: "Test-process baseline included. RSS and physical footprint are distinct, non-additive measures. MLX allocation bytes overlap unified physical memory; never add them to footprint. Apple/CoreML external services require separate sampling. First run does not mean cold OS model cache. Sampled peaks are lower bounds; lifetime peak RSS is not per phase.", samples: samples)
    }
    private func capture() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        var active: Int?; var cache: Int?; var peak: Int?
        #if canImport(MLX)
        if includeMetal {
            let snapshot = Memory.snapshot()
            active = snapshot.activeMemory; cache = snapshot.cacheMemory; peak = snapshot.peakMemory
        }
        #endif
        samples.append(PipelineMemorySample(elapsedSeconds: ProcessInfo.processInfo.systemUptime - started,
            phase: phase, residentBytes: status == KERN_SUCCESS ? info.resident_size : nil,
            physicalFootprintBytes: status == KERN_SUCCESS ? info.phys_footprint : nil,
            lifetimePeakRSSBytes: UInt64(max(0, usage.ru_maxrss)), mlxActiveBytes: active, mlxCacheBytes: cache, mlxLifetimePeakBytes: peak))
    }
}
private struct PipelineMemoryReport: Encodable {
    let processID: Int32; let physicalMemoryBytes: UInt64; let sampleIntervalMilliseconds: Int; let interpretation: String; let samples: [PipelineMemorySample]
}
private struct PipelineMemorySample: Encodable {
    let elapsedSeconds: Double; let phase: String; let residentBytes: UInt64?; let physicalFootprintBytes: UInt64?
    let lifetimePeakRSSBytes: UInt64; let mlxActiveBytes: Int?; let mlxCacheBytes: Int?; let mlxLifetimePeakBytes: Int?
}
