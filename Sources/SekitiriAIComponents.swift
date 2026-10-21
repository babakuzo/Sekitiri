import SwiftUI

/// Native SwiftUI primitives for Sekitiri's AI-facing states.
/// These are deliberately presentation-only: recording and model lifecycles
/// remain owned by AppModel and the transcription/summary coordinators.
enum SekitiriStatusKind {
    case active
    case ready
    case waiting
    case warning
    case neutral

    var color: Color {
        switch self {
        case .active, .ready: return SekitiriColor.terracotta
        case .waiting, .neutral: return SekitiriColor.muted
        case .warning: return .red
        }
    }

    var icon: String {
        switch self {
        case .active: return "waveform"
        case .ready: return "checkmark.circle.fill"
        case .waiting: return "clock"
        case .warning: return "exclamationmark.triangle.fill"
        case .neutral: return "circle"
        }
    }
}

struct SekitiriStatusBadge: View {
    let title: String
    let kind: SekitiriStatusKind

    var body: some View {
        Label(title, systemImage: kind.icon)
            .font(SekitiriType.body(10, weight: .semibold))
            .foregroundStyle(kind.color)
            .textCase(.uppercase)
            .tracking(0.35)
    }
}

struct SekitiriProcessingStep: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let kind: SekitiriStatusKind
}

struct SekitiriProcessingTimeline: View {
    let steps: [SekitiriProcessingStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(steps) { step in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: step.kind.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(step.kind.color)
                        .frame(width: 18, height: 18)
                        .background(step.kind.color.opacity(0.12), in: Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title)
                            .font(SekitiriType.body(12, weight: .semibold))
                            .foregroundStyle(SekitiriColor.ink)
                        Text(step.detail)
                            .font(SekitiriType.body(10))
                            .foregroundStyle(SekitiriColor.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
        .background(.white.opacity(0.52), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(SekitiriColor.line))
    }
}

struct SekitiriActionItemRow: View {
    let text: String
    let isChecked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(isChecked ? SekitiriColor.terracotta : SekitiriColor.ink)
                    .frame(width: 24, alignment: .leading)
                Text(text)
                    .font(SekitiriType.body(12))
                    .foregroundStyle(isChecked ? SekitiriColor.muted : SekitiriColor.ink)
                    .strikethrough(isChecked, color: SekitiriColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SekitiriContextCard: View {
    let title: String
    let text: String
    let timestamp: String?
    let action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(SekitiriType.body(10, weight: .semibold))
                .foregroundStyle(SekitiriColor.terracotta)
                .textCase(.uppercase)
                .tracking(0.35)
            Text(text)
                .font(.system(size: 15, design: .serif))
                .foregroundStyle(SekitiriColor.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let timestamp, let action {
                Button(action: action) {
                    Label("View in transcript", systemImage: "arrow.right")
                        .font(SekitiriType.body(10, weight: .medium))
                        .foregroundStyle(SekitiriColor.terracotta)
                }
                .buttonStyle(.plain)
                .help("Open transcript at \(timestamp)")
            }
        }
        .padding(14)
        .background(.white.opacity(0.52), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(SekitiriColor.line))
    }
}
