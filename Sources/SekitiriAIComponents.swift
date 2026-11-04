import SwiftUI

/// Native SwiftUI primitives for Sekitiri's AI-facing states.
/// These are deliberately presentation-only: recording and model lifecycles
/// remain owned by AppModel and the transcription/summary coordinators.
enum SekitiriStatusKind: Sendable {
    case active
    case ready
    case pending
    case waiting
    case warning
    case neutral

    var color: Color {
        switch self {
        case .active, .ready, .pending: return SekitiriColor.terracotta
        case .waiting, .neutral: return SekitiriColor.muted
        case .warning: return SekitiriColor.warning
        }
    }

    var icon: String {
        switch self {
        case .active: return "waveform"
        case .ready: return "checkmark.circle.fill"
        case .pending: return "checklist"
        case .waiting: return "clock"
        case .warning: return "exclamationmark.triangle.fill"
        case .neutral: return "circle"
        }
    }
}

struct SekitiriStatusBadge: View {
    let title: String
    let kind: SekitiriStatusKind

    private var tone: SKBadge.Tone {
        switch kind {
        case .active: return .progress
        case .ready: return .success
        case .pending: return .pending
        case .warning: return .warning
        case .waiting, .neutral: return .neutral
        }
    }

    var body: some View {
        SKBadge(text: title, tone: tone)
    }
}

struct SekitiriProcessingStep: Identifiable {
    let title: String
    let detail: String
    let kind: SekitiriStatusKind
    var id: String { title }
}

struct SekitiriProcessingTimeline: View {
    let steps: [SekitiriProcessingStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(steps) { step in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: step.kind.icon)
                        .font(SekitiriType.labelStrong)
                        .foregroundStyle(step.kind.color)
                        .frame(width: 20, height: 20)
                        .background(step.kind.color.opacity(0.12), in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(step.title)
                            .font(SekitiriType.bodyStrong)
                            .foregroundStyle(step.kind == .waiting ? SekitiriColor.muted : SekitiriColor.ink)
                        Text(step.detail)
                            .font(SekitiriType.caption)
                            .foregroundStyle(SekitiriColor.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

struct SekitiriActionItemRow: View {
    let text: String
    let isChecked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 17))
                    .foregroundStyle(isChecked ? SekitiriColor.terracotta : SekitiriColor.muted)
                    .frame(width: 24, alignment: .leading)
                    .accessibilityHidden(true)
                Text(text)
                    .font(SekitiriType.sans(16))
                    .foregroundStyle(isChecked ? SekitiriColor.muted : SekitiriColor.ink)
                    .strikethrough(isChecked, color: SekitiriColor.muted)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isChecked ? .isSelected : [])
    }
}
