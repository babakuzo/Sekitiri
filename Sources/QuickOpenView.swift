import SwiftUI

// ============================================================================
// ⌘K quick open: type to find a meeting by title, person or note text, then
// Return to open it. Opens and closes instantly; it's used many times a day.
// ============================================================================

struct QuickOpenView: View {
    @EnvironmentObject var model: AppModel
    let open: (String) -> Void
    let dismiss: () -> Void
    @State private var items: [MeetingItem] = []
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private var results: [MeetingItem] {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        let matches = terms.isEmpty ? items : items.filter { item in terms.allSatisfy { item.searchText.contains($0) } }
        return Array(matches.prefix(8))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture(perform: dismiss)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(SekitiriColor.muted)
                        .accessibilityHidden(true)
                    TextField("Find a meeting", text: $query)
                        .textFieldStyle(.plain)
                        .font(SekitiriType.sans(18))
                        .focused($focused)
                        .onSubmit(openHighlighted)
                        .accessibilityLabel("Find a meeting")
                    SKKbd(keys: "esc")
                }
                .padding(.horizontal, 18)
                .frame(height: 56)
                Rectangle().fill(SekitiriColor.border).frame(height: 1)
                if results.isEmpty {
                    Text(items.isEmpty ? "No meetings yet." : "No meetings match “\(query)”.")
                        .font(SekitiriType.meta)
                        .foregroundStyle(SekitiriColor.muted)
                        .padding(18)
                } else {
                    VStack(spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                            Button { open(item.id) } label: {
                                HStack(spacing: 12) {
                                    Text(item.title)
                                        .font(SekitiriType.serif(19, .medium))
                                        .foregroundStyle(SekitiriColor.ink)
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(item.date.map { $0.formatted(.dateTime.day().month(.abbreviated)) } ?? "")
                                        .font(SekitiriType.meta)
                                        .foregroundStyle(SekitiriColor.muted)
                                }
                                .padding(.horizontal, 12)
                                .frame(height: 42)
                                .background(index == highlighted ? SekitiriColor.blush : .clear,
                                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { if $0 { highlighted = index } }
                            .accessibilityAddTraits(index == highlighted ? .isSelected : [])
                        }
                    }
                    .padding(6)
                }
            }
            .frame(width: 560)
            .background(SekitiriColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(SekitiriColor.line))
            .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
            .padding(.top, 110)
            .onKeyPress(.downArrow) { move(1); return .handled }
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(.escape) { dismiss(); return .handled }
        }
        .onChange(of: query) { highlighted = 0 }
        .task {
            focused = true
            items = await MeetingLibrary.load()
        }
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        highlighted = (highlighted + delta + results.count) % results.count
    }

    private func openHighlighted() {
        guard results.indices.contains(highlighted) else { return }
        open(results[highlighted].id)
    }
}
