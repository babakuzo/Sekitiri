import SwiftUI

// ============================================================================
// Root view: the editorial sidebar beside the selected screen. The window has
// a hidden title bar, so content runs to the top edge under the traffic lights.
// ============================================================================

extension Notification.Name {
    /// Posted by the app menu's Settings… item (⌘,) to show Settings in-window.
    static let sekitiriShowSettings = Notification.Name("SekitiriShowSettings")
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var section: AppSection = .dashboard
    @State private var selectedMeetingID: String?
    @State private var showingQuickOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < SKLayout.compactSidebarBelow
            HStack(spacing: 0) {
                SidebarView(selection: $section, compact: compact) { reselected in
                    if reselected == .meetings { selectedMeetingID = nil }
                }
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(SekitiriColor.canvas)
                    .environment(\.skShowsRail, proxy.size.width >= SKLayout.railFrom)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .overlay {
            if showingQuickOpen {
                QuickOpenView(
                    open: { id in
                        showingQuickOpen = false
                        selectedMeetingID = id
                        section = .meetings
                    },
                    dismiss: { showingQuickOpen = false }
                )
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(toast: toast, undo: model.undoToast, dismiss: model.dismissToast)
                    .padding(.bottom, 28)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .timingCurve(0.23, 1, 0.32, 1, duration: 0.25), value: model.toast)
        .background {
            Button("") { showingQuickOpen.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
        }
        .tint(SekitiriColor.terracotta)
        .foregroundStyle(SekitiriColor.ink)
        .frame(minWidth: 760, minHeight: 560)
        .onAppear { MainWindow.openAction = openWindow }
        .onReceive(NotificationCenter.default.publisher(for: .sekitiriShowSettings)) { _ in
            section = .settings
        }
        .onAppear(perform: handleRequests)
        .onChange(of: model.requestedMeetingID) { handleRequests() }
        .onChange(of: model.requestedSection) { handleRequests() }
        .onReceive(NotificationCenter.default.publisher(for: .sekitiriShowSection)) { note in
            if let raw = note.object as? String, let target = AppSection(rawValue: raw) { section = target }
        }
        .onChange(of: model.recording) { _, isRecording in
            if isRecording { section = .record }
        }
        .onChange(of: model.isStartingRecording) { _, starting in
            if starting { section = .record }
        }
        .sheet(isPresented: Binding(
            get: { !hasCompletedOnboarding },
            set: { if !$0 { hasCompletedOnboarding = true } }
        )) {
            OnboardingView { hasCompletedOnboarding = true }
                .environmentObject(model)
                .tint(SekitiriColor.terracotta)
        }
        .alert(
            "Meeting detected",
            isPresented: Binding(
                get: { model.detectedCallPrompt != nil },
                set: { if !$0 { model.dismissDetectedCallPrompt() } }
            )
        ) {
            Button("Not Now", role: .cancel) { model.dismissDetectedCallPrompt() }
            Button("Start Recording") { model.startDetectedCallRecording() }
        } message: {
            Text(model.detectedCallPrompt.map { "\($0.title) is open. Start recording? Make sure everyone has consented." } ?? "A meeting call is open.")
        }
        .alert(item: $model.recordingSafetyPrompt) { prompt in
            Alert(
                title: Text(prompt.reason),
                message: Text("\(prompt.detail) Sekitiri keeps recording until you stop it."),
                primaryButton: .destructive(Text("Stop Recording")) { model.stop() },
                secondaryButton: .default(Text("Keep Recording")) { model.keepRecordingAfterSafetyPrompt() }
            )
        }
    }

    /// Navigation asked for from outside this window (the menu bar panel).
    private func handleRequests() {
        if let id = model.requestedMeetingID {
            model.requestedMeetingID = nil
            selectedMeetingID = id
            section = .meetings
        }
        if let raw = model.requestedSection {
            model.requestedSection = nil
            if let target = AppSection(rawValue: raw) { section = target }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .dashboard:
            DashboardView(
                startRecording: {
                    section = .record
                    model.startIfNotRecording()
                },
                setUpRecording: { section = .record },
                openMeetings: { section = .meetings },
                openMeeting: { id in
                    selectedMeetingID = id
                    section = .meetings
                }
            )
        case .record:
            RecordView(openMeeting: { id in
                model.dismissCompletedRecording()
                selectedMeetingID = id
                section = .meetings
            })
        case .meetings:
            MeetingsScreenView(selectedMeetingID: $selectedMeetingID)
        case .settings:
            SettingsScreen()
        }
    }
}

/// Bottom toast: a short confirmation with an optional Undo. Swipe down or
/// press the close button to dismiss early.
private struct ToastView: View {
    let toast: AppToast
    let undo: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Text(toast.message)
                .font(SekitiriType.body)
                .foregroundStyle(SekitiriColor.canvas)
            if toast.canUndo {
                Button("Undo", action: undo)
                    .buttonStyle(.plain)
                    .font(SekitiriType.bodyStrong)
                    .foregroundStyle(SekitiriColor.highlight)
                    .keyboardShortcut("z", modifiers: .command)
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(SekitiriColor.canvas.opacity(0.7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 18)
        .frame(height: 44)
        .background(SekitiriColor.ink, in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        .gesture(DragGesture(minimumDistance: 8).onEnded { value in
            if value.translation.height > 12 || value.velocity.height > 300 { dismiss() }
        })
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isStaticText)
    }
}
