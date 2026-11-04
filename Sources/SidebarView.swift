import SwiftUI

// ============================================================================
// Editorial sidebar: wordmark, the two working areas, a live recording pill
// while capturing, and Settings at the foot. Narrow windows get an icon rail.
// ============================================================================

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case dashboard
    case record
    case meetings
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .record: return "Recording"
        case .meetings: return "Meetings"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .record: return "record.circle"
        case .meetings: return "text.page"
        case .settings: return "gearshape"
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @Binding var selection: AppSection
    let compact: Bool
    /// Called when the already-selected section is clicked again.
    let reselect: (AppSection) -> Void

    static func width(compact: Bool) -> CGFloat { compact ? 76 : 260 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(compact ? "S" : "Sekitiri")
                .font(compact ? SekitiriType.serif(34, .semibold) : SekitiriType.wordmark)
                .foregroundStyle(SekitiriColor.terracotta)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
                .padding(.horizontal, compact ? 0 : 2)
                .padding(.bottom, 16)
                .accessibilityAddTraits(.isHeader)
            Rectangle().fill(SekitiriColor.rule).frame(height: 1)

            VStack(spacing: 6) {
                navRow(.dashboard, shortcut: "1")
                navRow(.meetings, shortcut: "2")
            }
            .padding(.top, compact ? 24 : 40)

            if model.recording || model.isStartingRecording {
                RecordingPill(compact: compact, isSelected: selection == .record) { select(.record) }
                    .padding(.top, 22)
                    .transition(.opacity)
            }

            Spacer(minLength: 16)

            HStack(spacing: 10) {
                if !compact {
                    Text(Self.initials)
                        .font(SekitiriType.sans(16, .medium))
                        .foregroundStyle(SekitiriColor.ink)
                        .frame(width: 40, height: 40)
                        .background(SekitiriColor.highlight, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .accessibilityHidden(true)
                }
                navRow(.settings, shortcut: nil)
            }
        }
        .padding(.top, 44)
        .padding(.horizontal, compact ? 10 : 18)
        .padding(.bottom, 20)
        .frame(width: Self.width(compact: compact))
        .frame(maxHeight: .infinity, alignment: .top)
        .background(SekitiriColor.sidebar)
        .animation(SekitiriMotion.easeOut, value: model.recording || model.isStartingRecording)
    }

    private func select(_ section: AppSection) {
        if selection == section { reselect(section) } else { selection = section }
    }

    @ViewBuilder
    private func navRow(_ section: AppSection, shortcut: KeyEquivalent?) -> some View {
        let button = SidebarNavButton(
            title: section.title,
            icon: section.icon,
            isSelected: selection == section,
            compact: compact
        ) { select(section) }
        if let shortcut {
            button.keyboardShortcut(shortcut, modifiers: .command)
        } else {
            button
        }
    }

    private static let initials: String = {
        let parts = NSFullUserName().split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "S" : letters.uppercased()
    }()
}

private struct SidebarNavButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let compact: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .regular))
                    .frame(width: 22)
                    .accessibilityHidden(true)
                if !compact {
                    Text(title).font(SekitiriType.nav)
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(isSelected ? SekitiriColor.terracotta : SekitiriColor.muted)
            .padding(.horizontal, compact ? 0 : 14)
            .frame(maxWidth: compact ? .infinity : nil, alignment: compact ? .center : .leading)
            .frame(height: 44)
            .background(background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(SekitiriHoverButtonStyle())
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var background: Color {
        if isSelected { return SekitiriColor.blush }
        return hovering ? SekitiriColor.blush.opacity(0.5) : .clear
    }
}

/// Terracotta pill shown while a recording runs; opens the live page.
private struct RecordingPill: View {
    @EnvironmentObject var model: AppModel
    let compact: Bool
    let isSelected: Bool
    let action: () -> Void

    private var title: String {
        if model.isStartingRecording { return "Starting…" }
        return model.isPaused ? "Paused" : "Recording"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Circle()
                    .fill(SekitiriColor.onAccent)
                    .frame(width: 10, height: 10)
                    .opacity(model.isPaused ? 0.5 : 1)
                    .accessibilityHidden(true)
                if !compact {
                    Text(title).font(SekitiriType.bodyStrong)
                    Spacer(minLength: 0)
                    Text(model.elapsed).font(SekitiriType.meta.monospacedDigit())
                }
            }
            .foregroundStyle(SekitiriColor.onAccent)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
            .frame(height: 46)
            .background(SekitiriColor.terracotta, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(SekitiriColor.ink.opacity(isSelected ? 0.25 : 0), lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(SekitiriHoverButtonStyle())
        .help("Show the current recording")
        .accessibilityLabel("\(title), \(model.elapsed). Show recording")
    }
}
