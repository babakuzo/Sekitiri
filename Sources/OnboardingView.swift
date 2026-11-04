import AVFoundation
import AppKit
import EventKit
import SwiftUI

/// First-run setup: microphone, system audio, calendar. Every step can be
/// skipped; only the microphone is needed to record.
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    let finish: () -> Void
    @State private var step = 0
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @AppStorage("systemAudio") private var systemAudio = true
    @AppStorage("browserCallDetection") private var browserCallDetection = true

    private let stepCount = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Sekitiri")
                    .font(SekitiriType.title)
                    .foregroundStyle(SekitiriColor.ink)
                Text("Recordings, transcripts and notes stay on this Mac. Let’s get recording ready.")
                    .font(SekitiriType.meta)
                    .foregroundStyle(SekitiriColor.muted)
            }

            Text("Step \(step + 1) of \(stepCount)")
                .font(SekitiriType.labelStrong)
                .foregroundStyle(SekitiriColor.terracotta)
                .textCase(.uppercase)

            Group {
                switch step {
                case 0: microphoneStep
                case 1: systemAudioStep
                default: calendarStep
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            Spacer(minLength: 0)

            HStack {
                Button("Set Up Later", action: finish)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if step > 0 {
                    Button("Back") { step -= 1 }
                }
                Button(step == stepCount - 1 ? "Done" : "Continue") {
                    if step == stepCount - 1 { finish() } else { step += 1 }
                }
                .buttonStyle(.skPrimary)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 540, height: 460)
        .background(SekitiriColor.canvas)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }

    // MARK: Steps

    private var microphoneStep: some View {
        StepContent(
            icon: "mic.fill",
            title: "Microphone",
            detail: "Sekitiri records your voice from the microphone. This is the only permission you need to start recording."
        ) {
            switch micStatus {
            case .authorized:
                PermissionState(text: "Microphone access allowed", granted: true)
            case .notDetermined:
                Button("Allow Microphone Access") {
                    Task {
                        _ = await AVCaptureDevice.requestAccess(for: .audio)
                        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                    }
                }
                .buttonStyle(.skPrimary)
            default:
                PermissionState(text: "Microphone access is off", granted: false)
                Button("Open Privacy Settings") { SystemSettingsLink.open(SystemSettingsLink.microphone) }
            }
        }
    }

    private var systemAudioStep: some View {
        StepContent(
            icon: "speaker.wave.2.fill",
            title: "Computer audio",
            detail: "To capture the other side of a call, Sekitiri records your Mac’s audio output. macOS asks for permission the first time you record — choose Allow. If you missed it, allow Sekitiri under Privacy & Security › Screen & System Audio Recording."
        ) {
            Toggle("Record computer audio during meetings", isOn: $systemAudio)
            Button("Open Privacy Settings") { SystemSettingsLink.open(SystemSettingsLink.audioCapture) }
            Text("If computer audio isn’t available, your microphone still records.")
                .font(SekitiriType.caption)
                .foregroundStyle(SekitiriColor.muted)
        }
    }

    private var calendarStep: some View {
        StepContent(
            icon: "calendar",
            title: "Calendar (optional)",
            detail: "Sekitiri can name recordings after your events, list today’s meetings and remind you before they start. It reads titles, times and attendee names, and never changes your calendar."
        ) {
            CalendarAccessControl()
            Toggle("Also detect meetings in browser tabs", isOn: $browserCallDetection)
                .help("Checks only the address of the active browser tab for Meet, Zoom, Teams or Webex links.")
            Text("Detection only asks whether to record — it never starts on its own.")
                .font(SekitiriType.caption)
                .foregroundStyle(SekitiriColor.muted)
        }
    }
}

private struct StepContent<Controls: View>: View {
    let icon: String
    let title: String
    let detail: String
    @ViewBuilder var controls: Controls

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(SekitiriColor.terracotta)
                .frame(width: 44, height: 44)
                .background(SekitiriColor.blush, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(SekitiriType.title3)
                Text(detail)
                    .font(SekitiriType.meta)
                    .foregroundStyle(SekitiriColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 8) { controls }
                    .padding(.top, 4)
            }
        }
    }
}

private struct PermissionState: View {
    let text: String
    let granted: Bool

    var body: some View {
        Label(text, systemImage: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
            .foregroundStyle(granted ? SekitiriColor.terracotta : SekitiriColor.warning)
            .font(.callout.weight(.medium))
    }
}
