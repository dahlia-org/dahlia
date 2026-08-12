import AppKit
import CoreGraphics
import Foundation

struct MeetingWindowDetection: Equatable, Sendable {
    let name: String
    let browserContexts: Set<MeetingAudioContext>
}

struct MeetingWindowInfo: Sendable {
    let owner: String
    let title: String
    let bundleIdentifier: String?

    init(owner: String, title: String, bundleIdentifier: String? = nil) {
        self.owner = owner
        self.title = title
        self.bundleIdentifier = bundleIdentifier
    }
}

enum MeetingWindowDetector {
    private static let googleMeetWebAppTitlePrefix = "Google Meet - "
    private static let titlePatterns: [(pattern: String, appName: String)] = [
        ("(Meeting) | Microsoft Teams", "Microsoft Teams"),
        ("Zoom Meeting", "Zoom"),
        ("Zoom Webinar", "Zoom"),
        ("Cisco Webex", "Webex"),
    ]

    static func detect(in windows: [MeetingWindowInfo]) -> MeetingWindowDetection? {
        var meetingName: String?
        var browserContexts = Set<MeetingAudioContext>()

        for window in windows {
            let browserContext = browserContext(for: window)
            if MeetingAudioWindowCatalog.isChromeWebApp(bundleIdentifier: window.bundleIdentifier) {
                if let browserContext, isGoogleMeetWindow(window) {
                    meetingName = meetingName ?? "Google Meet"
                    browserContexts.insert(browserContext)
                }
                continue
            }

            if let pattern = titlePatterns.first(where: { window.title.contains($0.pattern) }) {
                meetingName = meetingName ?? pattern.appName
                if let browserContext {
                    browserContexts.insert(browserContext)
                }
                continue
            }

            if let browserContext, isGoogleMeetWindow(window) {
                meetingName = meetingName ?? "Google Meet"
                browserContexts.insert(browserContext)
            }
        }

        return meetingName.map { MeetingWindowDetection(name: $0, browserContexts: browserContexts) }
    }

    private static func browserContext(for window: MeetingWindowInfo) -> MeetingAudioContext? {
        if let bundleIdentifier = window.bundleIdentifier,
           let context = MeetingAudioWindowCatalog.browserContext(forBundleIdentifier: bundleIdentifier) {
            return context
        }
        return MeetingAudioWindowCatalog.browserContext(forApplicationName: window.owner)
    }

    private static func isGoogleMeetWindow(_ window: MeetingWindowInfo) -> Bool {
        if MeetingAudioWindowCatalog.isChromeWebApp(bundleIdentifier: window.bundleIdentifier) {
            guard window.title.hasPrefix(googleMeetWebAppTitlePrefix) else { return false }
            let chromeTitle = String(window.title.dropFirst(googleMeetWebAppTitlePrefix.count))
            return hasGoogleMeetCallTitle(chromeTitle)
        }
        return hasGoogleMeetCallTitle(window.title)
    }

    private static func hasGoogleMeetCallTitle(_ title: String) -> Bool {
        title.hasPrefix("Meet -") || title.range(
            of: "[a-z]{3}-[a-z]{4}-[a-z]{3}",
            options: .regularExpression
        ) != nil
    }
}

/// WindowServer への同期問い合わせを MainActor 外で直列化し、表示に必要な小さい値だけを返す。
actor MeetingWindowDetectionWorker {
    func detect() -> MeetingWindowDetection? {
        guard !Task.isCancelled,
              let windows = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements],
                  kCGNullWindowID
              ) as? [[String: Any]] else { return nil }

        let windowInfo = windows.map { window -> MeetingWindowInfo in
            let owner = window[kCGWindowOwnerName as String] as? String ?? ""
            let title = window[kCGWindowName as String] as? String ?? ""
            let bundleIdentifier = (window[kCGWindowOwnerPID as String] as? pid_t)
                .flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
            return MeetingWindowInfo(owner: owner, title: title, bundleIdentifier: bundleIdentifier)
        }
        guard !Task.isCancelled else { return nil }
        return MeetingWindowDetector.detect(in: windowInfo)
    }
}
