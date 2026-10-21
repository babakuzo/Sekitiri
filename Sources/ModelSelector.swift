import SwiftUI

// ============================================================================
// Model selector — pill button + grouped popover (Screen C).
// ============================================================================

struct ModelItem: Identifiable, Hashable {
    let id: String
    let name: String           // display name
    let group: ModelGroup
    let provider: String
    let spec: String

    enum ModelGroup: String, CaseIterable, Identifiable {
        case local = "LOCAL (ON-DEVICE)"
        var id: String { rawValue }
    }

    var engineSpec: String { spec }

    static func == (lhs: ModelItem, rhs: ModelItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Built-in local summarizers. The MLX model is managed explicitly in
    /// Settings; requesting a summary never starts a download.
    static let sourceNotes = ModelItem(id: "source-notes", name: "Source notes · lightweight", group: .local, provider: "No language model", spec: "source-notes")
    static let appleIntelligence = ModelItem(id: "afm", name: "Apple Foundation Model", group: .local, provider: "On-device", spec: "afm")
    static let qwen35 = ModelItem(id: "qwen3.5-2b", name: "Qwen3.5 2B · 4-bit", group: .local, provider: "MLX local", spec: "qwen3.5-2b")
    static let qwenSmall = ModelItem(id: "qwen3.5-0.8b", name: "Qwen3.5 0.8B · 4-bit (experimental)", group: .local, provider: "MLX local", spec: "qwen3.5-0.8b")

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

// MARK: - Pill trigger (compact, used in toolbars)

struct ModelPill: View {
    @Binding var selected: ModelItem
    @State private var showPopover = false

    var body: some View {
        Button(action: { showPopover = true }) {
            HStack(spacing: 6) {
                Circle()
                    .fill(selected.group == .local ? Color.green : Color.accentColor)
                    .frame(width: 8, height: 8)
                Text(selected.name)
                    .font(.system(.caption, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.accentColor)
            .foregroundColor(.white)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover) {
            ModelPopover(selected: $selected, isPresented: $showPopover, allModels: ModelItem.builtIns)
                .frame(width: 340)
        }
    }
}

// MARK: - Popover (grouped list)

struct ModelPopover: View {
    @Binding var selected: ModelItem
    @Binding var isPresented: Bool
    let allModels: [ModelItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ModelItem.ModelGroup.allCases) { group in
                let models = allModels.filter { $0.group == group }

                // Section header
                Text(group.rawValue)
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 14)
                    .padding(.top, group == ModelItem.ModelGroup.allCases.first ? 10 : 14)
                    .padding(.bottom, 6)

                ForEach(models) { model in
                    Button(action: {
                        selected = model
                        isPresented = false
                    }) {
                        HStack(spacing: 10) {
                            // Selection circle
                            Circle()
                                .fill(selected.id == model.id ? Color.accentColor : Color.gray.opacity(0.3))
                                .frame(width: 16, height: 16)
                                .overlay(
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.white)
                                        .opacity(selected.id == model.id ? 1 : 0)
                                )

                            Text(model.name)
                                .font(.system(.body))
                                .foregroundColor(.primary)

                            Spacer()

                            // Provider tag
                            Text(model.provider)
                                .font(.system(.caption2, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(providerColor(model.provider))
                                .clipShape(Capsule())
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(selected.id == model.id
                                    ? Color.accentColor.opacity(0.1)
                                    : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()
                .padding(.top, 8)

            // Privacy note
            Text("Local models process completely off-network.")
                .font(.system(.caption))
                .foregroundColor(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .padding(.vertical, 4)
    }

    private func providerColor(_ provider: String) -> Color {
        provider == "On-device" ? .gray : SekitiriColor.terracotta
    }
}
