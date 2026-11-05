import AppKit
import Combine
import SwiftUI

// ============================================================================
// Floating mini-recorder. While a recording runs and Sekitiri's window isn't
// in front, a small pill floats above every app (including full-screen calls)
// with the time, mic activity, Mark, Pause and Stop. When Sekitiri spots a
// call in the background, the same panel asks whether to record.
// Drag it anywhere; it settles into the nearest corner.
// ============================================================================

@MainActor
final class MiniRecorderController {
    static let enabledKey = "miniRecorder"
    private static let cornerKey = "miniRecorderCorner"

    private let model: AppModel
    private var panel: MiniRecorderPanel?
    private var cancellables: Set<AnyCancellable> = []
    private var isSnapping = false
    private var snapCheck: DispatchWorkItem?
    private var contentSize = CGSize(width: 320, height: 52)

    /// 0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right.
    private var corner: Int {
        get { UserDefaults.standard.object(forKey: Self.cornerKey) as? Int ?? 1 }
        set { UserDefaults.standard.set(newValue, forKey: Self.cornerKey) }
    }

    init(model: AppModel) {
        self.model = model
        let center = NotificationCenter.default
        let triggers: [AnyPublisher<Void, Never>] = [
            model.$recording.map { _ in () }.eraseToAnyPublisher(),
            model.$isStartingRecording.map { _ in () }.eraseToAnyPublisher(),
            model.$detectedCallPrompt.map { _ in () }.eraseToAnyPublisher(),
            center.publisher(for: NSApplication.didBecomeActiveNotification).map { _ in () }.eraseToAnyPublisher(),
            center.publisher(for: NSApplication.didResignActiveNotification).map { _ in () }.eraseToAnyPublisher(),
            center.publisher(for: NSWindow.didChangeOcclusionStateNotification).map { _ in () }.eraseToAnyPublisher(),
            center.publisher(for: NSWindow.willCloseNotification).map { _ in () }.eraseToAnyPublisher(),
            center.publisher(for: UserDefaults.didChangeNotification).map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(triggers)
            .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.update() } }
            .store(in: &cancellables)
    }

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// The main window is on screen and Sekitiri is the active app.
    private var mainWindowInFront: Bool {
        guard NSApp.isActive else { return false }
        return NSApp.windows.contains { window in
            window.identifier?.rawValue.hasPrefix(MainWindow.id) == true
                && window.isVisible && !window.isMiniaturized
                && window.occlusionState.contains(.visible)
        }
    }

    private func update() {
        let capturing = model.recording || model.isStartingRecording
        let showRecorder = capturing && isEnabled && !mainWindowInFront
        let showPrompt = !capturing && model.detectedCallPrompt != nil && !mainWindowInFront
        if showRecorder || showPrompt { show() } else { hide() }
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        guard !panel.isVisible else { return }
        place(panel, animated: false)
        panel.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> MiniRecorderPanel {
        let panel = MiniRecorderPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.title = "Sekitiri recorder"
        panel.setAccessibilityLabel("Sekitiri recorder")

        let root = MiniRecorderContent(onSize: { [weak self] size in self?.resize(to: size) })
            .environmentObject(model)
            .tint(SekitiriColor.terracotta)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: contentSize)
        panel.contentView = hosting

        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSnap() }
        }
        return panel
    }

    // MARK: Size and position

    private func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0, size != contentSize else { return }
        contentSize = size
        guard let panel else { return }
        // The content often changes size under a click (Record, Stop). Don't
        // drop that resize, or the panel stays too narrow and clips the pill;
        // apply it once the button is released.
        if NSEvent.pressedMouseButtons != 0 { scheduleSnap(); return }
        place(panel, animated: false)
    }

    private func frame(for corner: Int, on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let margin: CGFloat = 16
        let x = corner % 2 == 0 ? visible.minX + margin : visible.maxX - contentSize.width - margin
        let y = corner < 2 ? visible.maxY - contentSize.height - margin : visible.minY + margin
        return NSRect(x: x, y: y, width: contentSize.width, height: contentSize.height)
    }

    private func place(_ panel: NSPanel, animated: Bool) {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let target = frame(for: corner, on: screen)
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            isSnapping = true
            panel.setFrame(target, display: true)
            isSnapping = false
            return
        }
        isSnapping = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            panel.animator().setFrame(target, display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.isSnapping = false }
        }
    }

    /// Waits until the drag ends (no mouse button held), then settles into
    /// the corner nearest the panel's centre.
    private func scheduleSnap() {
        guard !isSnapping else { return }
        snapCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                if NSEvent.pressedMouseButtons != 0 { self.scheduleSnap(); return }
                guard let screen = panel.screen ?? NSScreen.main else { return }
                let visible = screen.visibleFrame
                let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
                let left = center.x < visible.midX
                let top = center.y > visible.midY
                self.corner = (top ? 0 : 2) + (left ? 0 : 1)
                self.place(panel, animated: true)
            }
        }
        snapCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}

/// Borderless panels can't become key by default; the recorder needs to so
/// its buttons respond on the first click. It never activates the app.
final class MiniRecorderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Content

private struct MiniRecorderContent: View {
    @EnvironmentObject var model: AppModel
    let onSize: (CGSize) -> Void

    var body: some View {
        Group {
            if model.recording || model.isStartingRecording {
                MiniRecorderPill()
            } else if let call = model.detectedCallPrompt {
                DetectedCallCard(call: call)
            }
        }
        .fixedSize()
        .padding(12) // room for the shadow
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
    }
}

struct MiniRecorderPill: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(SekitiriColor.terracotta)
                .frame(width: 10, height: 10)
                .padding(4)
                .background(SekitiriColor.tint, in: Circle())
                .opacity(model.isPaused ? 0.45 : 1)
                .accessibilityHidden(true)
            Button { MainWindow.show() } label: {
                Text(model.isStartingRecording ? "Starting…" : model.elapsed)
                    .font(SekitiriType.sans(16).monospacedDigit())
                    .foregroundStyle(SekitiriColor.ink)
                    .lineLimit(1)
                    .fixedSize()
            }
            .buttonStyle(.plain)
            .help("Open Sekitiri")
            .accessibilityLabel(model.isPaused ? "Paused, \(model.elapsed). Open Sekitiri" : "Recording, \(model.elapsed). Open Sekitiri")
            if model.micSendingNothing, model.recording, !model.isPaused {
                Button { MainWindow.show() } label: {
                    Image(systemName: "mic.slash.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(SekitiriColor.warning)
                        .frame(width: 26)
                }
                .buttonStyle(.plain)
                .help("Your microphone is sending no sound. Open Sekitiri")
                .accessibilityLabel("Microphone is sending no sound. Open Sekitiri")
            } else {
                ActivityWaveform(isActive: model.isHearingAudio && model.recording && !model.isPaused)
                    .scaleEffect(0.8)
                    .frame(width: 26)
            }
            circleButton("flag", help: "Mark this moment (⇧⌘M)", disabled: !model.recording || model.isPaused) { model.markMoment() }
            circleButton(model.isPaused ? "play.fill" : "pause.fill",
                         help: model.isPaused ? "Resume (⇧⌘P)" : "Pause (⇧⌘P)",
                         disabled: !model.recording || model.isFinalizingRecording) { model.togglePause() }
            Button { model.stop() } label: {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(SekitiriColor.onAccent)
                    .frame(width: 12, height: 12)
                    .frame(width: 36, height: 36)
                    .background(SekitiriColor.terracotta, in: Circle())
            }
            .buttonStyle(SekitiriHoverButtonStyle())
            .disabled(model.isFinalizingRecording)
            .help(model.isStartingRecording ? "Cancel recording" : "Stop and save (⇧⌘R)")
            .accessibilityLabel(model.isStartingRecording ? "Cancel recording" : "Stop and save")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(SekitiriColor.border))
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }

    private func circleButton(_ symbol: String, help: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SekitiriColor.terracotta)
                .frame(width: 34, height: 34)
                .background(SekitiriColor.sidebar, in: Circle())
        }
        .buttonStyle(SekitiriHoverButtonStyle())
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct DetectedCallCard: View {
    @EnvironmentObject var model: AppModel
    let call: MeetingContext

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(call.title) is open")
                .font(SekitiriType.serif(21, .semibold))
                .foregroundStyle(SekitiriColor.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text("Record it with Sekitiri? Make sure everyone has agreed to be recorded.")
                .font(SekitiriType.meta)
                .foregroundStyle(SekitiriColor.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Spacer()
                Button("Not Now") { model.dismissDetectedCallPrompt() }
                    .buttonStyle(.sk(.outline, .small))
                Button("Start Recording") { model.startDetectedCallRecording() }
                    .buttonStyle(.sk(.primary, .small))
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
        .background(SekitiriColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(SekitiriColor.line))
        .shadow(color: .black.opacity(0.16), radius: 12, y: 6)
    }
}
