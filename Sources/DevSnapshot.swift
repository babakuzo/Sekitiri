import AppKit
import SwiftUI

// ============================================================================
// Opt-in visual check for development. When SEKITIRI_SNAPSHOT_DIR is set, the
// app renders its own main window for each listed section to PNG and quits.
// Nothing runs unless that variable is present.
//
//   SEKITIRI_SNAPSHOT_DIR=/tmp/shots SEKITIRI_SNAPSHOT_SECTIONS=dashboard,meetings \
//   SEKITIRI_SNAPSHOT_SIZE=1440x900 SEKITIRI_SNAPSHOT_APPEARANCE=dark \
//   Sekitiri.app/Contents/MacOS/Sekitiri
// ============================================================================

extension Notification.Name {
    /// Object: an `AppSection` raw value.
    static let sekitiriShowSection = Notification.Name("SekitiriShowSection")
    /// Snapshot runs only: open the newest meeting that has notes.
    static let sekitiriSnapshotOpenMeeting = Notification.Name("SekitiriSnapshotOpenMeeting")
}

@MainActor
enum DevSnapshot {
    /// `cacheDisplay` can't draw scroll-view content, so snapshot runs lay
    /// pages out without scrolling. Read once at launch.
    nonisolated static let isActive = ProcessInfo.processInfo.environment["SEKITIRI_SNAPSHOT_DIR"] != nil

    static func runIfRequested(model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["SEKITIRI_SNAPSHOT_DIR"] else { return }
        let directory = URL(fileURLWithPath: dir, isDirectory: true)
        let sections = (env["SEKITIRI_SNAPSHOT_SECTIONS"] ?? "dashboard")
            .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        let size = env["SEKITIRI_SNAPSHOT_SIZE"].flatMap(parseSize)
        if let appearance = env["SEKITIRI_SNAPSHOT_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }

        Task { @MainActor in
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? await Task.sleep(for: .seconds(2))
            guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(MainWindow.id) == true }) else {
                NSApp.terminate(nil)
                return
            }
            if let size { window.setContentSize(size) }
            for section in sections {
                if section == "menubar" || section == "mini" {
                    renderStandalone(section, model: model, to: directory.appendingPathComponent("\(section).png"))
                    continue
                }
                if section == "meeting" {
                    NotificationCenter.default.post(name: .sekitiriShowSection, object: "meetings")
                    try? await Task.sleep(for: .seconds(1.5))
                    NotificationCenter.default.post(name: .sekitiriSnapshotOpenMeeting, object: nil)
                } else {
                    NotificationCenter.default.post(name: .sekitiriShowSection, object: section)
                }
                try? await Task.sleep(for: .seconds(2))
                if let view = window.contentView {
                    capture(view, to: directory.appendingPathComponent("\(section).png"))
                }
            }
            if env["SEKITIRI_SNAPSHOT_KEEP_OPEN"] == nil { exit(0) }
        }
    }

    private static func parseSize(_ text: String) -> NSSize? {
        let parts = text.lowercased().split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? NSSize(width: parts[0], height: parts[1]) : nil
    }

    /// Menu bar panel and mini-recorder live outside the main window, so
    /// they're hosted in an offscreen window just for the picture.
    private static func renderStandalone(_ name: String, model: AppModel, to url: URL) {
        let root: AnyView
        if name == "menubar" {
            root = AnyView(MenuBarPanel().environmentObject(model))
        } else {
            root = AnyView(VStack(alignment: .leading, spacing: 20) {
                MiniRecorderPill()
                DetectedCallCard(call: MeetingContext(eventID: "demo", title: "ALA Coaching", start: Date(),
                                                      end: Date().addingTimeInterval(1800), attendees: [], meetingURL: nil))
            }
            .padding(24)
            .background(SekitiriColor.sidebar)
            .environmentObject(model))
        }
        let hosting = NSHostingView(rootView: root.tint(SekitiriColor.terracotta))
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        capture(hosting, to: url)
        window.orderOut(nil)
    }

    private static func capture(_ view: NSView, to url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
