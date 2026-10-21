import SwiftUI

// ============================================================================
// Navigation used by the existing transcript and settings pages.
// ============================================================================

enum NavTab: String, CaseIterable, Identifiable {
    case record   = "Record"
    case meetings = "Meetings"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .record:   return "mic.fill"
        case .meetings: return "doc.text"
        case .settings: return "gearshape.fill"
        }
    }
}

struct SidebarView: View {
    @Binding var selected: NavTab
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 8) {
                    Image(systemName: "pencil.and.scribble")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    HStack(spacing: 6) {
                        Text("Sekitiri")
                            .font(.system(size: 16, weight: .semibold))
                        Circle()
                            .fill(model.recording ? Color.red : Color.green)
                            .frame(width: 6, height: 6)
                    }
                }

                VStack(spacing: 4) {
                    ForEach(NavTab.allCases) { tab in
                        SidebarButton(
                            icon: tab.icon,
                            label: tab.rawValue,
                            isSelected: selected == tab,
                            activeColor: .accentColor
                        ) { selected = tab }
                    }
                }
            }

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("ACTIVE PIPELINE")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("LOCAL")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                Text(model.selectedModel.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(model.selectedModel.provider)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color.white)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.08)))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(12)
        .frame(width: 240)
        .background(Color(hex: 0xFAF9FC))
        .overlay(alignment: .trailing) { Divider() }
    }
}

struct SidebarButton: View {
    let icon: String
    let label: String
    let isSelected: Bool
    let activeColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isSelected ? activeColor : .secondary)
                Text(label)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? activeColor : .secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? activeColor.opacity(0.08) : .clear)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(isSelected ? activeColor : .clear))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Hex color helper

extension Color {
    init(hex: UInt, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
