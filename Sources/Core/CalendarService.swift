import AppKit
import ApplicationServices
import EventKit
import Foundation

/// Calendar context captured alongside a recording. Attendee names are
/// candidates for speaker matching; they are never treated as voice identity
/// without an explicit local voice-profile match.
struct MeetingContext: Sendable, Equatable {
    let eventID: String
    let title: String
    let start: Date
    let end: Date
    let attendees: [String]
    let meetingURL: String?
    let calendarSource: String = "Calendar"

    var participantSummary: String {
        attendees.isEmpty ? "No attendees listed" : attendees.joined(separator: ", ")
    }

    /// Browser-only calls are hints. They can prompt the user, but must never
    /// be used as the sole reason to start an automatic recording.
    var isCalendarBacked: Bool { !eventID.hasPrefix("browser-") }
}

@MainActor
final class CalendarService: ObservableObject {
    @Published private(set) var authorizationStatus: EKAuthorizationStatus
    @Published private(set) var upcomingMeeting: MeetingContext?
    @Published private(set) var activeMeeting: MeetingContext?
    @Published private(set) var detectedCall: MeetingContext?
    @Published private(set) var todaySchedule: [MeetingContext] = []

    private let store = EKEventStore()
    private var refreshTimer: Timer?
    private var workspaceObserver: NSObjectProtocol?
    private var eventStoreObserver: NSObjectProtocol?

    init() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        if isAuthorized { refresh() }
        // Keep the detector resident in the menu-bar process. Ten seconds is
        // short enough for a prompt at the start of a call, while avoiding a
        // tight AppleScript loop against Chrome/Safari.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        eventStoreObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    var isAuthorized: Bool {
        authorizationStatus == .fullAccess
    }

    func requestAccess() {
        store.requestFullAccessToEvents { [weak self] granted, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.authorizationStatus = granted
                    ? EKEventStore.authorizationStatus(for: .event)
                    : .denied
                if granted { self.refresh() }
            }
        }
    }

    func refresh() {
        let now = Date()
        let browserCall = browserCallContext(now: now)
        guard isAuthorized else {
            upcomingMeeting = nil
            detectedCall = browserCall
            activeMeeting = browserCall
            todaySchedule = browserCall.map { [$0] } ?? []
            return
        }
        let horizon = now.addingTimeInterval(24 * 60 * 60)
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-5 * 60), end: horizon, calendars: nil)
        let meetings = store.events(matching: predicate)
            .filter(isLikelyMeeting)
            .compactMap(MeetingContext.init)
            .sorted { $0.start < $1.start }

        let calendar = Calendar.current
        todaySchedule = meetings.filter { calendar.isDate($0.start, inSameDayAs: now) && $0.end >= now }

        let calendarActive = meetings.first { $0.start <= now && $0.end.addingTimeInterval(120) >= now }
        upcomingMeeting = meetings.first { $0.start > now }
        activeMeeting = fusedActiveMeeting(calendarActive: calendarActive, meetings: meetings, browserCall: browserCall)
        detectedCall = browserCall.map { browser in
            fusedBrowserCall(browser, with: nearestCalendarMeeting(to: browser, in: meetings))
        }
        if activeMeeting == nil, let detectedCall { activeMeeting = detectedCall }
    }

    /// The event to use for automatic recording. Includes a two-minute
    /// pre-roll so the opening context is not lost.
    var automaticRecordingCandidate: MeetingContext? {
        let now = Date()
        if let activeMeeting, activeMeeting.isCalendarBacked { return activeMeeting }
        guard let upcomingMeeting,
              upcomingMeeting.start.timeIntervalSince(now) <= 120 else { return nil }
        return upcomingMeeting
    }

    private func browserCallContext(now: Date) -> MeetingContext? {
        let browserDetection = UserDefaults.standard.object(forKey: "browserCallDetection") as? Bool ?? true
        let teamsDetection = UserDefaults.standard.object(forKey: "teamsDesktopDetection") as? Bool ?? true
        if teamsDetection,
           let teams = NSWorkspace.shared.runningApplications.first(where: {
               ["com.microsoft.teams2", "com.microsoft.teams"].contains($0.bundleIdentifier)
           }),
           let teamsCall = teamsDesktopCallContext(application: teams, now: now) {
            return teamsCall
        }
        guard browserDetection else { return nil }
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let url: String?
        switch app.bundleIdentifier {
        case "com.google.Chrome", "com.google.Chrome.canary":
            url = browserURL(application: "Google Chrome")
        case "org.chromium.Chromium":
            url = browserURL(application: "Chromium")
        case "com.microsoft.edgemac":
            url = browserURL(application: "Microsoft Edge")
        case "com.apple.Safari":
            url = browserURL(application: "Safari")
        default:
            return nil
        }
        guard let url,
              url.range(of: #"(?i)(meet\.google\.com|zoom\.us|teams\.microsoft|webex\.com)"#, options: .regularExpression) != nil,
              looksLikeMeetingURL(url)
        else { return nil }
        let name: String
        if url.localizedCaseInsensitiveContains("meet.google") { name = "Google Meet" }
        else if url.localizedCaseInsensitiveContains("zoom") { name = "Zoom" }
        else if url.localizedCaseInsensitiveContains("teams") { name = "Microsoft Teams" }
        else { name = "Webex" }
        return MeetingContext(
            eventID: "browser-\(stableBrowserID(url))",
            title: "\(name) call",
            start: now,
            end: now.addingTimeInterval(60 * 60),
            attendees: [],
            meetingURL: url
        )
    }

    /// Teams desktop does not expose the active meeting URL through the same
    /// AppleScript interface as browsers. When Accessibility permission is
    /// granted, inspect only Teams' visible window titles and roles—never page
    /// contents, transcripts, or participant data. Detection remains a hint.
    private func teamsDesktopCallContext(application: NSRunningApplication, now: Date) -> MeetingContext? {
        guard AXIsProcessTrusted() else { return nil }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return nil }

        let titles = windows.compactMap { window -> String? in
            var titleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
                  let title = titleValue as? String else { return nil }
            return title.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        let callTitle = titles.first {
            let lower = $0.lowercased()
            return lower.contains("meeting") || lower.contains("call") || lower.contains("huddle")
                || lower.contains("together mode") || lower.contains("live event")
        }
        guard let callTitle else { return nil }
        return MeetingContext(
            eventID: "teams-desktop-\(stableTeamsID(callTitle))",
            title: callTitle == "Microsoft Teams" ? "Microsoft Teams call" : callTitle,
            start: now,
            end: now.addingTimeInterval(60 * 60),
            attendees: [],
            meetingURL: nil
        )
    }

    private func stableTeamsID(_ title: String) -> String {
        title.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(80).description
    }

    private func fusedActiveMeeting(
        calendarActive: MeetingContext?,
        meetings: [MeetingContext],
        browserCall: MeetingContext?
    ) -> MeetingContext? {
        guard let browserCall else { return calendarActive }
        if let matched = nearestCalendarMeeting(to: browserCall, in: meetings) {
            return fusedBrowserCall(browserCall, with: matched)
        }
        // A confirmed browser call is stronger than a calendar event with an
        // unrelated URL, so do not let an unrelated active event hide it.
        return browserCall
    }

    private func nearestCalendarMeeting(to browser: MeetingContext, in meetings: [MeetingContext]) -> MeetingContext? {
        let browserURL = URL(string: browser.meetingURL ?? "")
        return meetings
            .filter { event in
                let eventURL = event.meetingURL.flatMap(URL.init(string:))
                let sameHostAndPath = browserURL?.host?.lowercased() == eventURL?.host?.lowercased()
                    && browserURL?.path == eventURL?.path
                let closeInTime = abs(event.start.timeIntervalSince(browser.start)) <= 45 * 60
                    || (event.start <= browser.start && event.end.addingTimeInterval(120) >= browser.start)
                return sameHostAndPath || closeInTime
            }
            .min { lhs, rhs in
                abs(lhs.start.timeIntervalSince(browser.start)) < abs(rhs.start.timeIntervalSince(browser.start))
            }
    }

    private func fusedBrowserCall(_ browser: MeetingContext, with event: MeetingContext?) -> MeetingContext {
        guard let event else { return browser }
        return MeetingContext(
            eventID: event.eventID,
            title: event.title == "Meeting" ? browser.title : event.title,
            start: event.start,
            end: event.end,
            attendees: event.attendees,
            meetingURL: browser.meetingURL ?? event.meetingURL
        )
    }

    private func looksLikeMeetingURL(_ rawURL: String) -> Bool {
        guard let components = URLComponents(string: rawURL),
              let host = components.host?.lowercased()
        else { return false }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        if host == "meet.google.com" { return path.contains("-") && path.count >= 6 }
        if host.hasSuffix("zoom.us") { return path.contains("/j/") || path.hasPrefix("j/") || path.contains("/wc/") }
        if host.contains("teams.microsoft") { return path.contains("meet") || path.contains("l/") }
        if host == "webex.com" || host.hasSuffix(".webex.com") { return !path.isEmpty && path != "signin" }
        return false
    }

    private func stableBrowserID(_ rawURL: String) -> String {
        guard let components = URLComponents(string: rawURL), let host = components.host else { return rawURL }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        return "\(host.lowercased())/\(path)"
    }

    private func browserURL(application: String) -> String? {
        let source = "tell application \"\(application)\" to get URL of active tab of front window"
        var error: NSDictionary?
        let value = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? value?.stringValue : nil
    }

    private func isLikelyMeeting(_ event: EKEvent) -> Bool {
        let combined = "\(event.location ?? "") \(event.notes ?? "") \(event.url?.absoluteString ?? "")"
        let hasCallURL = combined.range(of: #"(?i)(zoom\.us|meet\.google|teams\.microsoft|webex\.com|facetime|gotomeet)"#, options: .regularExpression) != nil
        return hasCallURL || (event.attendees?.count ?? 0) >= 1
    }
}

private extension MeetingContext {
    init?(event: EKEvent) {
        guard let eventID = event.eventIdentifier, !eventID.isEmpty else { return nil }
        self.eventID = eventID
        title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? event.title!
            : "Meeting"
        start = event.startDate
        end = event.endDate
        attendees = (event.attendees ?? [])
            .compactMap(\.name)
            .filter { !$0.isEmpty }
        meetingURL = event.url?.absoluteString
    }
}
