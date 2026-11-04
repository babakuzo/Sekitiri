import SwiftUI

// ============================================================================
// Page layout shared by every screen: a reading column and, when the window
// is wide enough, a 300pt rail on the right in the sidebar colour. Narrower
// windows drop the rail and each screen places that content inline instead.
// ============================================================================

private struct ShowsRailKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether the window is wide enough for a right-hand rail.
    var skShowsRail: Bool {
        get { self[ShowsRailKey.self] }
        set { self[ShowsRailKey.self] = newValue }
    }
}

enum SKLayout {
    static let railWidth: CGFloat = 300
    /// Window widths below this use the icon sidebar.
    static let compactSidebarBelow: CGFloat = 900
    /// Window widths at or above this show a page's rail.
    static let railFrom: CGFloat = 1180
    static let pagePadding = EdgeInsets(top: 56, leading: 40, bottom: 40, trailing: 40)
}

/// A page with a reading column and an optional right rail.
struct SKRailLayout<Main: View, Rail: View>: View {
    @Environment(\.skShowsRail) private var showsRail
    var scrolls = true
    /// False when the main view scrolls itself and applies its own padding.
    var padded = true
    @ViewBuilder var main: Main
    @ViewBuilder var rail: Rail

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if !padded {
                    main
                } else if scrolls {
                    SKScroll { column }
                } else {
                    column
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showsRail {
                SKScroll { railColumn }
                    .frame(width: SKLayout.railWidth)
                .frame(maxHeight: .infinity)
                .background(SekitiriColor.sidebar)
            }
        }
        .background(SekitiriColor.canvas)
    }

    private var railColumn: some View {
        VStack(alignment: .leading, spacing: 16) { rail }
            .padding(EdgeInsets(top: 56, leading: 24, bottom: 24, trailing: 24))
            .frame(maxWidth: .infinity, maxHeight: DevSnapshot.isActive ? .infinity : nil, alignment: .topLeading)
    }

    private var column: some View {
        main
            .padding(SKLayout.pagePadding)
            .frame(maxWidth: 1000, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

extension SKRailLayout where Rail == EmptyView {
    init(scrolls: Bool = true, @ViewBuilder main: () -> Main) {
        self.init(scrolls: scrolls, main: main) { EmptyView() }
    }
}

/// A vertical ScrollView, except in snapshot runs where `cacheDisplay`
/// can't draw scrolled content and the page is laid out flat instead.
struct SKScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if DevSnapshot.isActive {
            content.frame(maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView { content }
        }
    }
}

/// Items in up to `maxColumns` columns separated by vertical rules, as in
/// the Recent Meetings and archive mockups. Column count follows the width.
struct SKColumnGrid<Item: Identifiable, Cell: View>: View {
    let items: [Item]
    var minColumnWidth: CGFloat = 220
    var maxColumns = 3
    @ViewBuilder let cell: (Item) -> Cell
    @State private var width: CGFloat = 900

    private let gutter: CGFloat = 22

    var body: some View {
        let columns = max(1, min(maxColumns, Int((width + gutter * 2) / (minColumnWidth + gutter * 2))))
        let rows = stride(from: 0, to: items.count, by: columns).map { Array(items[$0..<min($0 + columns, items.count)]) }
        VStack(alignment: .leading, spacing: 28) {
            ForEach(rows.indices, id: \.self) { rowIndex in
                let row = rows[rowIndex]
                HStack(alignment: .top, spacing: 0) {
                    ForEach(0..<columns, id: \.self) { column in
                        Group {
                            if column < row.count { cell(row[column]) } else { Color.clear.frame(height: 1) }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.leading, column == 0 ? 0 : gutter)
                        .padding(.trailing, column == columns - 1 ? 0 : gutter)
                        .overlay(alignment: .trailing) {
                            if column < row.count - 1 {
                                Rectangle().fill(SekitiriColor.rule).frame(width: 1)
                            }
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// The date line above page titles, e.g. "Wednesday, 4 November".
enum SKDate {
    static func dayLine(_ date: Date = Date()) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    /// "10:00 AM | 30m" as used on schedule cards.
    static func slot(start: Date, end: Date) -> String {
        "\(start.formatted(date: .omitted, time: .shortened)) | \(duration(end.timeIntervalSince(start)))"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h\(minutes % 60)m"
    }

    /// "Starts in 4 min", "Started 3 min ago", "In 2h".
    static func relative(to start: Date, end: Date, now: Date = Date()) -> String {
        if now >= start && now < end { return "Happening now" }
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 0 { return "Ended" }
        if minutes < 60 { return "Starts in \(minutes) min" }
        return "Starts in \(duration(start.timeIntervalSince(now)))"
    }
}

/// Underlined text tabs, as used for Summary / Transcript and Settings.
struct SKTabRow<Tab: Hashable>: View {
    @Binding var selection: Tab
    let tabs: [Tab]
    let title: (Tab) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: 26) {
                ForEach(tabs, id: \.self) { tab in
                    let selected = tab == selection
                    Button { selection = tab } label: {
                        Text(title(tab))
                            .font(SekitiriType.sans(16, selected ? .semibold : .medium))
                            .foregroundStyle(selected ? SekitiriColor.ink : SekitiriColor.muted)
                            .padding(.bottom, 9)
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(selected ? SekitiriColor.terracotta : .clear)
                                    .frame(height: 2)
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
                }
            }
            Rectangle().fill(SekitiriColor.border).frame(height: 1)
        }
    }
}

/// Pill segmented control: the selected option fills terracotta.
struct SKSegmented<Option: Hashable>: View {
    @Binding var selection: Option
    let options: [Option]
    let title: (Option) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button { selection = option } label: {
                    Text(title(option))
                        .font(SekitiriType.sans(14, selected ? .semibold : .medium))
                        .foregroundStyle(selected ? SekitiriColor.onAccent : SekitiriColor.muted)
                        .padding(.horizontal, 16)
                        .frame(height: 36)
                        .background(selected ? SekitiriColor.terracotta : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(3)
        .background(SekitiriColor.sidebar, in: Capsule())
    }
}

/// Wraps children onto new lines, for chips.
struct SKFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (indices: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = ([index], size.width, size.height)
            } else {
                current = (current.indices + [index], needed, max(current.height, size.height))
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
