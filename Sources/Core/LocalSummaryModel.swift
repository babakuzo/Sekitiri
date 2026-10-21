import Foundation

enum LocalSummaryModel: String, CaseIterable, Identifiable, Sendable {
    case qwen2B = "qwen3.5-2b"
    case qwen08B = "qwen3.5-0.8b"

    var id: String { rawValue }
    var engineID: String { rawValue }
    var modelID: String {
        switch self {
        case .qwen2B: return "mlx-community/Qwen3.5-2B-4bit"
        case .qwen08B: return "mlx-community/Qwen3.5-0.8B-4bit"
        }
    }
    var label: String {
        switch self {
        case .qwen2B: return "Qwen3.5 2B · 4-bit"
        case .qwen08B: return "Qwen3.5 0.8B · 4-bit (experimental)"
        }
    }
    var approximateDownloadBytes: Int64 {
        switch self {
        case .qwen2B: return 1_750_000_000
        case .qwen08B: return 652_000_000
        }
    }
    var minimumFreeSpaceBytes: Int64 { approximateDownloadBytes * 2 }
}

struct LocalInferenceMemorySnapshot: Codable, Sendable {
    let activeBytes: Int
    let cacheBytes: Int
    let peakBytes: Int
}
