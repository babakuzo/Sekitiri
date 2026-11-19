import AppKit
import CoreText
import SwiftUI

// MARK: - Colour tokens

/// Palette A from the redesign: white paper and warm greys, with terracotta as
/// the single brand accent that also marks recording. Every token resolves per
/// appearance. Use tokens for every surface, never `.white`.
enum SekitiriColor {
    /// Window background.
    static let canvas = dynamic(light: 0xFFFFFF, dark: 0x1A1918)
    /// Sidebar and right-hand rails.
    static let sidebar = dynamic(light: 0xF4F2EF, dark: 0x222120)
    /// Cards, editors and other raised surfaces.
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x262422)
    /// Cards placed on a rail (schedule entries), selected navigation.
    static let blush = dynamic(light: 0xE9E5E0, dark: 0x2F2C2A)
    /// Quiet fills: segmented tracks, skeletons, key caps.
    static let fill = dynamic(light: 0xEFECE8, dark: 0x2C2A28)
    /// Brand accent for text, icons and fills. Also the "recording" colour.
    static let terracotta = dynamic(light: 0x984536, dark: 0xD9876F)
    /// Soft brand tint behind icons, timestamps and the playing line.
    static let tint = dynamic(light: 0xF1DDD5, dark: 0x3D2A24)
    /// Text/icon colour placed on a terracotta fill.
    static let onAccent = dynamic(light: 0xFFF9F4, dark: 0x1A1918)
    /// Primary text.
    static let ink = dynamic(light: 0x1C1917, dark: 0xF2EEEA)
    /// Secondary text.
    static let muted = dynamic(light: 0x625A54, dark: 0xADA59D)
    /// Section rules under headings.
    static let rule = dynamic(light: 0xAFA197, dark: 0x4A4642)
    /// Control borders.
    static let line = dynamic(light: 0xD9D5CF, dark: 0x3B3836)
    /// Card borders and inner dividers.
    static let border = dynamic(light: 0xE2DED8, dark: 0x34312F)
    /// Low-key highlight behind search matches and selections.
    static let highlight = dynamic(light: 0xEAC3B4, dark: 0x5A3A2E)

    // Semantic states. Each has text, tint and border shades so they read
    // in both appearances without relying on hue alone.
    static let success = dynamic(light: 0x3F4C37, dark: 0xB7C8A9)
    static let successTint = dynamic(light: 0xE3E9DD, dark: 0x2A3126)
    static let sage = dynamic(light: 0x5E6D54, dark: 0x9DB08F)
    static let bronze = dynamic(light: 0x75603F, dark: 0xC8A878)
    static let bronzeTint = dynamic(light: 0xEFE5D3, dark: 0x352D20)
    static let danger = dynamic(light: 0xB3261E, dark: 0xF2867C)
    static let warning = danger
    static let dangerText = dynamic(light: 0x8C1D18, dark: 0xF5A39B)
    static let dangerTint = dynamic(light: 0xFCEDEB, dark: 0x3A2220)
    static let dangerBorder = dynamic(light: 0xEBB7B2, dark: 0x6B3530)
    static let caution = dynamic(light: 0x8A5A00, dark: 0xE9C27A)
    static let cautionText = dynamic(light: 0x6B4600, dark: 0xF0D29A)
    static let cautionTint = dynamic(light: 0xFDF4E3, dark: 0x3A2F1A)
    static let cautionBorder = dynamic(light: 0xEDCF97, dark: 0x6B5528)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Type

/// The redesign's two families: a serif for headings and long reading
/// (Newsreader in the mockups) and a sans for interface text (IBM Plex Sans).
/// When those fonts are installed or bundled they are used automatically;
/// otherwise Apple's New York and SF stand in with the same sizes.
enum SekitiriType {
    private static let families: Set<String> = {
        _ = BundledFonts.registered
        return Set(NSFontManager.shared.availableFontFamilies)
    }()
    private static let serifFamily: String? = families.contains("Newsreader") ? "Newsreader" : nil
    private static let sansFamily: String? = families.contains("IBM Plex Sans") ? "IBM Plex Sans" : nil

    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        if let serifFamily { return .custom(serifFamily, fixedSize: size).weight(weight) }
        return .system(size: size, weight: weight, design: .serif)
    }

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        if let sansFamily { return .custom(sansFamily, fixedSize: size).weight(weight) }
        return .system(size: size, weight: weight)
    }

    // Scale from the mockups.
    static let wordmark = serif(56, .semibold)
    static let pageTitle = serif(44, .semibold)
    static let sectionTitle = serif(28, .semibold)
    static let cardTitle = serif(24, .medium)
    static let subTitle = serif(21, .semibold)
    static let reading = serif(18)
    static let nav = sans(17, .medium)
    static let body = sans(15)
    static let bodyStrong = sans(15, .semibold)
    static let meta = sans(14)
    static let label = sans(13, .medium)
    static let labelStrong = sans(13, .semibold)
    static let caption = sans(12)

    // Semantic aliases kept for existing screens.
    static let title = sectionTitle
    static let title2 = subTitle
    static let title3 = serif(19, .semibold)
}

/// Registers the fonts shipped in Resources/Fonts for this process only.
/// The app bundle copies Assets into Contents/Resources; `swift run` builds
/// keep them in the SwiftPM resource bundle beside the executable.
enum BundledFonts {
    /// Registers once, on first access.
    static let registered: Void = {
        var folders: [URL] = []
        if let resources = Bundle.main.resourceURL {
            folders.append(resources.appendingPathComponent("Fonts"))
            folders.append(resources)
        }
        let besideExecutable = Bundle.main.bundleURL
        let bundles = (try? FileManager.default.contentsOfDirectory(at: besideExecutable, includingPropertiesForKeys: nil)) ?? []
        folders += bundles.filter { $0.pathExtension == "bundle" }.flatMap { [$0.appendingPathComponent("Fonts"), $0] }
        for folder in folders {
            let fonts = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension.lowercased() == "ttf" }
            guard !fonts.isEmpty else { continue }
            CTFontManagerRegisterFontURLs(fonts as CFArray, .process, true, nil)
            return
        }
    }()
}

// MARK: - Motion

enum SekitiriMotion {
    /// Strong ease-out for UI responses (cubic-bezier .23, 1, .32, 1).
    static let easeOut = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.22)
    static let press = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.14)
}

// MARK: - Buttons

/// shadcn-style button anatomy themed with Sekitiri tokens. Every variant
/// scales to 0.97 on press (instant feedback) unless Reduce Motion is on.
struct SKButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, outline, ghost, destructive, link, onAccent }
    enum Size { case small, regular, large }

    var kind: Kind = .primary
    var size: Size = .regular
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        SKButtonBody(configuration: configuration, kind: kind, size: size, fullWidth: fullWidth)
    }
}

private struct SKButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: SKButtonStyle.Kind
    let size: SKButtonStyle.Size
    let fullWidth: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .font(font)
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, kind == .link ? 0 : horizontalPadding)
            .frame(height: kind == .link ? nil : height)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(background, in: shape)
            .overlay(shape.stroke(borderColor, lineWidth: kind == .outline ? 1 : 0))
            .contentShape(shape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.88 : 1) : 0.5)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : SekitiriMotion.press, value: configuration.isPressed)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size == .large ? height / 2 : 8, style: .continuous)
    }
    private var height: CGFloat { size == .small ? 30 : size == .regular ? 36 : 46 }
    private var horizontalPadding: CGFloat { size == .small ? 11 : size == .regular ? 15 : 22 }
    private var font: Font {
        size == .large ? SekitiriType.sans(16, .semibold) : SekitiriType.sans(size == .small ? 13 : 14, .medium)
    }
    private var foreground: Color {
        switch kind {
        case .primary: return SekitiriColor.onAccent
        case .destructive: return .white
        case .onAccent: return SekitiriColor.terracotta
        case .link: return SekitiriColor.terracotta
        default: return SekitiriColor.ink
        }
    }
    private var background: Color {
        switch kind {
        case .primary: return SekitiriColor.terracotta
        case .secondary: return SekitiriColor.fill
        case .outline: return SekitiriColor.surface
        case .destructive: return SekitiriColor.danger
        case .onAccent: return SekitiriColor.onAccent
        case .ghost, .link: return .clear
        }
    }
    private var borderColor: Color { kind == .outline ? SekitiriColor.line : .clear }
}

extension ButtonStyle where Self == SKButtonStyle {
    static var skPrimary: SKButtonStyle { SKButtonStyle(kind: .primary) }
    static var skSecondary: SKButtonStyle { SKButtonStyle(kind: .secondary) }
    static var skOutline: SKButtonStyle { SKButtonStyle(kind: .outline) }
    static var skGhost: SKButtonStyle { SKButtonStyle(kind: .ghost) }
    static var skLink: SKButtonStyle { SKButtonStyle(kind: .link) }
    static var skDestructive: SKButtonStyle { SKButtonStyle(kind: .destructive) }
    static func sk(_ kind: SKButtonStyle.Kind, _ size: SKButtonStyle.Size = .regular) -> SKButtonStyle {
        SKButtonStyle(kind: kind, size: size)
    }
}

/// Press feedback for large custom tappable areas (cards).
struct SekitiriHoverButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(reduceMotion ? nil : SekitiriMotion.press, value: configuration.isPressed)
    }
}

// MARK: - Surfaces

extension View {
    /// A raised surface with one edge treatment: a border, no shadow.
    func sekitiriCard(cornerRadius: CGFloat = 12, padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .background(SekitiriColor.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(SekitiriColor.border))
    }
}

/// A heading with the rule beneath it, as in the mockups.
struct SKSectionHeader<Trailing: View>: View {
    let title: String
    var font: Font = SekitiriType.sectionTitle
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(font)
                    .foregroundStyle(SekitiriColor.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                trailing
            }
            Rectangle().fill(SekitiriColor.rule).frame(height: 1)
        }
    }
}

extension SKSectionHeader where Trailing == EmptyView {
    init(_ title: String, font: Font = SekitiriType.sectionTitle) {
        self.init(title: title, font: font) { EmptyView() }
    }
}

// MARK: - Badge

/// Status badges: live, progress, success, pending actions, warning, danger.
struct SKBadge: View {
    enum Tone { case live, progress, success, pending, warning, danger, outline, neutral }

    let text: String
    var tone: Tone = .neutral
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if tone == .live {
                Circle().fill(SekitiriColor.onAccent).frame(width: 7, height: 7).accessibilityHidden(true)
            } else if tone == .progress {
                ProgressView().controlSize(.mini).tint(SekitiriColor.terracotta).accessibilityHidden(true)
            } else if let icon {
                Image(systemName: icon).font(.system(size: 10, weight: .bold)).accessibilityHidden(true)
            }
            Text(text)
        }
        .font(SekitiriType.labelStrong)
        .foregroundStyle(foreground)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(tone == .outline ? SekitiriColor.line : .clear))
        .fixedSize()
    }

    private var foreground: Color {
        switch tone {
        case .live: return SekitiriColor.onAccent
        case .progress: return SekitiriColor.terracotta
        case .success: return SekitiriColor.success
        case .pending: return SekitiriColor.bronze
        case .warning: return SekitiriColor.cautionText
        case .danger: return .white
        case .outline, .neutral: return SekitiriColor.ink
        }
    }
    private var background: Color {
        switch tone {
        case .live: return SekitiriColor.terracotta
        case .progress: return SekitiriColor.tint
        case .success: return SekitiriColor.successTint
        case .pending: return SekitiriColor.bronzeTint
        case .warning: return SekitiriColor.cautionTint
        case .danger: return SekitiriColor.danger
        case .outline: return SekitiriColor.surface
        case .neutral: return SekitiriColor.fill
        }
    }
}

/// A speaker or owner pill.
struct SKPersonPill: View {
    let name: String
    var color: Color = SekitiriColor.terracotta

    var body: some View {
        Text(name)
            .font(SekitiriType.labelStrong)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(color, in: Capsule())
            .fixedSize()
    }

    static func color(for name: String) -> Color {
        switch name.lowercased() {
        case "you", "me": return SekitiriColor.terracotta
        default:
            let palette = [SekitiriColor.sage, SekitiriColor.bronze, Color(nsColor: .systemGray)]
            // Stable across launches, unlike `hashValue`.
            let seed = name.lowercased().unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
            return palette[seed % palette.count]
        }
    }
}

/// A keyboard shortcut hint.
struct SKKbd: View {
    let keys: String
    var body: some View {
        Text(keys)
            .font(SekitiriType.caption.monospacedDigit())
            .foregroundStyle(SekitiriColor.muted)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(SekitiriColor.sidebar, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityLabel("Shortcut \(keys)")
    }
}

// MARK: - Alerts

/// shadcn-style alert: icon, title, message and optional actions. Severity is
/// carried by tint, border and icon together, never by a coloured edge bar.
struct SekitiriBanner<Actions: View>: View {
    enum Severity { case info, warning, danger }

    let systemImage: String
    let title: String
    var message: String? = nil
    var severity: Severity = .warning
    @ViewBuilder var actions: Actions

    init(systemImage: String, title: String, message: String? = nil,
         severity: Severity = .warning, @ViewBuilder actions: () -> Actions) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.severity = severity
        self.actions = actions()
    }

    /// Compatibility with screens written before severities existed.
    init(systemImage: String, title: String, message: String? = nil,
         isWarning: Bool, @ViewBuilder actions: () -> Actions) {
        self.init(systemImage: systemImage, title: title, message: message,
                  severity: isWarning ? .warning : .info, actions: actions)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 20)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(SekitiriType.bodyStrong).foregroundStyle(textColor)
                if let message {
                    Text(message)
                        .font(SekitiriType.meta)
                        .foregroundStyle(severity == .info ? SekitiriColor.muted : textColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) { actions }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(tint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(borderColor))
        .accessibilityElement(children: .contain)
    }

    private var iconColor: Color {
        switch severity { case .info: SekitiriColor.ink; case .warning: SekitiriColor.caution; case .danger: SekitiriColor.danger }
    }
    private var textColor: Color {
        switch severity { case .info: SekitiriColor.ink; case .warning: SekitiriColor.cautionText; case .danger: SekitiriColor.dangerText }
    }
    private var tint: Color {
        switch severity { case .info: SekitiriColor.surface; case .warning: SekitiriColor.cautionTint; case .danger: SekitiriColor.dangerTint }
    }
    private var borderColor: Color {
        switch severity { case .info: SekitiriColor.border; case .warning: SekitiriColor.cautionBorder; case .danger: SekitiriColor.dangerBorder }
    }
}

extension SekitiriBanner where Actions == EmptyView {
    init(systemImage: String, title: String, message: String? = nil, severity: Severity = .warning) {
        self.init(systemImage: systemImage, title: title, message: message, severity: severity) { EmptyView() }
    }

    init(systemImage: String, title: String, message: String? = nil, isWarning: Bool) {
        self.init(systemImage: systemImage, title: title, message: message,
                  severity: isWarning ? .warning : .info) { EmptyView() }
    }
}

enum SystemSettingsLink {
    static let microphone = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    static let audioCapture = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
    static let storage = URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!

    static func open(_ url: URL) { NSWorkspace.shared.open(url) }
}
