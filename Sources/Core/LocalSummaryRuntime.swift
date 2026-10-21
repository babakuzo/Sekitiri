import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
#if canImport(MLXLLM)
import MLX
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers
#endif

enum LocalSummaryModelState: Equatable, Sendable {
    case notDownloaded
    case downloading(Double)
    case ready
    case loading
    case failed(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var isBusy: Bool {
        switch self {
        case .downloading, .loading: return true
        default: return false
        }
    }
}

enum SummaryProgress: Equatable, Sendable {
    case preparing
    case loadingModel
    case generating(current: Int, total: Int)
    case repairing
    case saving

    var label: String {
        switch self {
        case .preparing: return "Preparing transcript…"
        case .loadingModel: return "Loading local model…"
        case .generating(let current, let total):
            return total > 1 ? "Generating summary · pass \(current) of \(total)…" : "Generating summary…"
        case .repairing: return "Formatting summary…"
        case .saving: return "Saving summary…"
        }
    }
}

enum LocalSummaryRuntimeError: LocalizedError {
    case notDownloaded
    case busy
    case insufficientDisk(required: Int64, available: Int64)
    case invalidRepository
    case removeFailed(String)

    var errorDescription: String? {
        switch self {
        case .busy:
            return "A local summary is already running or stopping. Wait for it to finish before starting another."
        case .notDownloaded:
            return "The selected Qwen3.5 model is not downloaded. Open Settings → Local summary model and choose Download before summarising."
        case .insufficientDisk(let required, let available):
            return "Qwen3.5 needs at least \(Self.bytes(required)) free to download safely. This Mac currently has \(Self.bytes(available)) free."
        case .invalidRepository:
            return "The built-in Qwen3.5 model identifier is invalid."
        case .removeFailed(let message):
            return "Couldn’t remove the Qwen3.5 download: \(message)"
        }
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

/// Owns the single downloadable summary model. Downloads are explicit and
/// inference only opens a complete local snapshot, so Summarise never starts a
/// network request. On an 8 GB Mac it is released immediately after use; Macs
/// with more memory retain it briefly to make one follow-up regeneration fast.
/// It is always released before recording or under memory pressure.
actor LocalSummaryRuntime {
    static let shared = LocalSummaryRuntime()
    static let modelID = "mlx-community/Qwen3.5-2B-4bit"
    static let engineID = "qwen3.5-2b"
    static let approximateDownloadBytes: Int64 = 1_750_000_000
    static let minimumFreeSpaceBytes: Int64 = 3_500_000_000
    static var warmRetentionSeconds: UInt64 {
        ProcessInfo.processInfo.physicalMemory <= 8 * 1_073_741_824 ? 0 : 30
    }

    #if canImport(MLXLLM)
    private let hub = HubClient.default
    private let cache = HubCache.default
    private let downloadPatterns = ["*.safetensors", "*.json", "*.jinja"]
    private var loadedContainer: ModelContainer?
    private var unloadTask: Task<Void, Never>?
    private var loadedModel: LocalSummaryModel?
    private var activeLease: UUID?
    private var activeCancellation: (@Sendable () -> Void)?
    private var activeCompletion: Task<Void, Never>?
    private var isUnloading = false
    private var isLoading = false
    private var hasInitializedMLX = false
    private var benchmarkRetentionSeconds: UInt64?
    #endif

    static var appleFoundationModelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    static func availableDiskBytes() -> Int64 {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    func isDownloaded(model: LocalSummaryModel = .qwen2B) async -> Bool {
        #if canImport(MLXLLM)
        return (try? await cachedDirectory(model: model)) != nil
        #else
        return false
        #endif
    }

    func download(
        model: LocalSummaryModel = .qwen2B,
        progressHandler: @MainActor @Sendable @escaping (Double) -> Void
    ) async throws {
        #if canImport(MLXLLM)
        try Task.checkCancellation()
        if await isDownloaded(model: model) {
            await progressHandler(1)
            return
        }
        let available = Self.availableDiskBytes()
        guard available >= model.minimumFreeSpaceBytes else {
            throw LocalSummaryRuntimeError.insufficientDisk(
                required: model.minimumFreeSpaceBytes,
                available: available
            )
        }
        guard let repo = Repo.ID(rawValue: model.modelID) else {
            throw LocalSummaryRuntimeError.invalidRepository
        }
        try Task.checkCancellation()
        _ = try await hub.downloadSnapshot(
            of: repo,
            revision: "main",
            matching: downloadPatterns,
            maxConcurrentDownloads: 4
        ) { progress in
            progressHandler(max(0, min(1, progress.fractionCompleted)))
        }
        try Task.checkCancellation()
        guard await isDownloaded(model: model) else { throw LocalSummaryRuntimeError.notDownloaded }
        await progressHandler(1)
        #else
        throw LocalSummaryRuntimeError.notDownloaded
        #endif
    }

    func removeDownload(model: LocalSummaryModel = .qwen2B) async throws {
        #if canImport(MLXLLM)
        await unload()
        guard let repo = Repo.ID(rawValue: model.modelID) else {
            throw LocalSummaryRuntimeError.invalidRepository
        }
        let fm = FileManager.default
        let targets = [
            cache.repoDirectory(repo: repo, kind: .model),
            cache.metadataDirectory(repo: repo, kind: .model),
            cache.lockPath(for: cache.repoDirectory(repo: repo, kind: .model)),
        ]
        do {
            for target in targets where fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
        } catch {
            throw LocalSummaryRuntimeError.removeFailed(error.localizedDescription)
        }
        #endif
    }

    /// Model references stay pinned for an entire generation. A second summary
    /// cannot load another set of weights while this operation is active.
    #if canImport(MLXLLM)
    func withContainer<T: Sendable>(
        model: LocalSummaryModel = .qwen2B,
        operation: @escaping @Sendable (ModelContainer) async throws -> T
    ) async throws -> T {
        guard activeLease == nil, !isUnloading, !isLoading else { throw LocalSummaryRuntimeError.busy }
        let lease = UUID()
        activeLease = lease
        let task = Task {
            let container = try await self.loadContainer(model: model, lease: lease)
            try Task.checkCancellation()
            return try await operation(container)
        }
        activeCancellation = { task.cancel() }
        activeCompletion = Task { _ = await task.result }
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            finishLease(lease)
            return result
        } catch {
            finishLease(lease)
            throw error
        }
    }

    /// Explicit preparation is also used by the controlled cold/warm benchmark.
    /// It never starts an automatic unload in the middle of model loading.
    func container(model: LocalSummaryModel = .qwen2B) async throws -> ModelContainer {
        try await loadContainer(model: model, lease: nil)
    }

    private func loadContainer(model: LocalSummaryModel, lease: UUID?) async throws -> ModelContainer {
        guard !isUnloading, !isLoading, activeLease == lease else { throw LocalSummaryRuntimeError.busy }
        unloadTask?.cancel()
        unloadTask = nil
        if let loadedContainer, loadedModel == model { return loadedContainer }
        loadedContainer = nil
        loadedModel = nil
        if hasInitializedMLX { Memory.clearCache() }
        hasInitializedMLX = true
        Memory.cacheLimit = 64 * 1_024 * 1_024
        isLoading = true
        defer { isLoading = false }
        let directory = try await cachedDirectory(model: model)
        try Task.checkCancellation()
        let configuration = ModelConfiguration(
            directory: directory,
            defaultPrompt: "Summarise this meeting.",
            extraEOSTokens: ["<|im_end|>"]
        )
        let container = try await #huggingFaceLoadModelContainer(configuration: configuration)
        try Task.checkCancellation()
        loadedContainer = container
        loadedModel = model
        return container
    }

    private func finishLease(_ lease: UUID) {
        guard activeLease == lease else { return }
        activeLease = nil
        activeCancellation = nil
        activeCompletion = nil
        if !isUnloading { scheduleUnload() }
    }
    #endif

    /// Cancels active generation and waits for it to release its inference
    /// buffers before capture may acquire the speech model.
    func unload() async {
        #if canImport(MLXLLM)
        unloadTask?.cancel()
        unloadTask = nil
        isUnloading = true
        activeCancellation?()
        if let completion = activeCompletion { await completion.value }
        loadedContainer = nil
        loadedModel = nil
        if hasInitializedMLX { Memory.clearCache() }
        isUnloading = false
        #endif
    }

    func didFinishUsing() {
        #if canImport(MLXLLM)
        guard loadedContainer != nil, activeLease == nil else { return }
        scheduleUnload()
        #endif
    }

    func setWarmRetentionForBenchmark(seconds: UInt64?) {
        #if canImport(MLXLLM)
        benchmarkRetentionSeconds = seconds
        #endif
    }

    nonisolated static func memorySnapshot() -> LocalInferenceMemorySnapshot {
        #if canImport(MLXLLM)
        return .init(activeBytes: Memory.activeMemory, cacheBytes: Memory.cacheMemory, peakBytes: Memory.peakMemory)
        #else
        return .init(activeBytes: 0, cacheBytes: 0, peakBytes: 0)
        #endif
    }

    #if canImport(MLXLLM)
    private func cachedDirectory(model: LocalSummaryModel) async throws -> URL {
        guard let repo = Repo.ID(rawValue: model.modelID) else { throw LocalSummaryRuntimeError.invalidRepository }
        do {
            let directory = try await hub.downloadSnapshot(of: repo, revision: "main", matching: downloadPatterns, localFilesOnly: true)
            // Supported snapshots must carry their own tokenizer configuration.
            // Never invoke a dependency's generic model fallback in an installed
            // bundle, and never silently fetch tokenizer data during inference.
            let tokenizerConfig = directory.appendingPathComponent("tokenizer_config.json")
            guard let data = try? Data(contentsOf: tokenizerConfig),
                  (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                throw LocalSummaryRuntimeError.notDownloaded
            }
            return directory
        } catch { throw LocalSummaryRuntimeError.notDownloaded }
    }

    private func scheduleUnload() {
        unloadTask?.cancel()
        let retention = benchmarkRetentionSeconds ?? Self.warmRetentionSeconds
        unloadTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(retention)) } catch { return }
            await self?.unload()
        }
    }
    #endif
}
