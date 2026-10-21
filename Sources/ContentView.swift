import SwiftUI

// ============================================================================
// Root view — dark icon sidebar + light content area.
// Routes between Record, Meetings, Settings.
// ============================================================================

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var nav: NavTab = .record
    @State private var requestedMeetingID: String?

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width < 760 {
                VStack(spacing: 0) {
                    CompactNavigationBar(selected: $nav)
                    activeContent
                }
            } else {
                HStack(spacing: 0) {
                    DashboardSidebarView(selected: $nav)
                        .environmentObject(model)
                    activeContent
                }
            }
        }
        .frame(minWidth: 620, minHeight: 560)
        .alert(
            "Meeting detected",
            isPresented: Binding(
                get: { model.detectedCallPrompt != nil },
                set: { if !$0 { model.dismissDetectedCallPrompt() } }
            )
        ) {
            Button("Not now", role: .cancel) { model.dismissDetectedCallPrompt() }
            Button("Start Recording") { model.startDetectedCallRecording() }
        } message: {
            Text(model.detectedCallPrompt.map { "\($0.title) is open. Start recording? Make sure everyone has consented." } ?? "A meeting call is open.")
        }
        .alert(item: $model.recordingSafetyPrompt) { prompt in
            Alert(
                title: Text(prompt.reason),
                message: Text("\(prompt.detail) No audio will be stopped without your action unless you enabled a recording safety timeout."),
                primaryButton: .destructive(Text("Stop Recording")) { model.stop() },
                secondaryButton: .default(Text("Keep Recording")) { model.keepRecordingAfterSafetyPrompt() }
            )
        }
    }

    @ViewBuilder
    private var activeContent: some View {
        switch nav {
        case .record:
            DashboardView(
                openMeetings: { nav = .meetings },
                openMeeting: { id in
                    requestedMeetingID = id
                    nav = .meetings
                }
            )
                .environmentObject(model)
        case .meetings:
            MeetingsScreenView(requestedMeetingID: $requestedMeetingID)
        case .settings:
            SettingsView().environmentObject(model)
        }
    }
}
