import SwiftUI

// ============================================================================
// Summary engines — all run on this Mac. A native menu picker is used
// everywhere the engine can be changed.
// ============================================================================

struct ModelItem: Identifiable, Hashable {
    let id: String
    /// Plain-language name shown in pickers.
    let name: String
    /// One-line explanation shown in Settings.
    let detail: String
    let spec: String

    var engineSpec: String { spec }

    static func == (lhs: ModelItem, rhs: ModelItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// "1.75 GB" — the approximate one-time Qwen download.
    static let qwenDownloadSize = ByteCountFormatter.string(
        fromByteCount: LocalSummaryModel.qwen2B.approximateDownloadBytes, countStyle: .file
    )

    /// Built-in local summarizers. The MLX model is downloaded explicitly;
    /// requesting a summary never starts a download.
    static let sourceNotes = ModelItem(
        id: "source-notes",
        name: "Quick extract (no AI, instant)",
        detail: "Keeps the transcript’s own sentences for decisions and tasks. Nothing to download.",
        spec: "source-notes"
    )
    static let appleIntelligence = ModelItem(
        id: "afm",
        name: "Apple Intelligence",
        detail: "Apple’s on-device model, built into macOS. Nothing to download.",
        spec: "afm"
    )
    static let qwen35 = ModelItem(
        id: "qwen3.5-2b",
        name: "Qwen 3.5 (\(qwenDownloadSize) download)",
        detail: "An open model that runs on this Mac after a one-time download.",
        spec: "qwen3.5-2b"
    )

    var localModel: LocalSummaryModel? { LocalSummaryModel(rawValue: spec) }
    var requiresDownload: Bool { localModel != nil }
}

// MARK: - Built-in local catalogue

extension ModelItem {
    // The 0.8B candidate failed factual extraction checks. Keep it available
    // to the opt-in benchmark without offering it as a dependable UI choice.
    static let builtIns: [ModelItem] = [.sourceNotes, .appleIntelligence, .qwen35]

    static func initialSelection(savedID: String?) -> ModelItem {
        builtIns.first { $0.id == savedID } ?? .sourceNotes
    }
}

// MARK: - Picker

/// Native menu picker for the summary engine, bound to the app model.
struct SummaryEnginePicker: View {
    @EnvironmentObject var model: AppModel
    var showsLabel = false

    var body: some View {
        Picker("Summary engine", selection: $model.selectedModel) {
            ForEach(ModelItem.builtIns) { item in
                Text(item.name).tag(item)
            }
        }
        .pickerStyle(.menu)
        .modifier(HiddenLabel(hidden: !showsLabel))
        .disabled(model.isSummarizing || model.localSummaryModelState.isBusy)
        .help("Choose how notes are generated. Everything runs on this Mac.")
    }

    private struct HiddenLabel: ViewModifier {
        let hidden: Bool
        func body(content: Content) -> some View {
            if hidden { content.labelsHidden().fixedSize() } else { content }
        }
    }
}
