import CoreGraphics
import Foundation

struct MeetingWindowDetection: Equatable, Sendable {
    let name: String
    let browserContexts: Set<MeetingAudioContext>
}

struct MeetingWindowInfo: Sendable {
    let owner: String
    let title: String
}

enum MeetingWindowDetector {
    private static let titlePatterns: [(pattern: String, appName: String)] = [
        ("(Meeting) | Microsoft Teams", "Microsoft Teams"),
        ("Zoom Meeting", "Zoom"),
        ("Zoom Webinar", "Zoom"),
        ("Cisco Webex", "Webex"),
    ]

    static func detect(in windows: [MeetingWindowInfo]) -> MeetingWindowDetection? {
        var meetingName: String?
        var browserContexts = Set<MeetingAudioContext>()

        for window in windows where !window.title.isEmpty {
            if let pattern = titlePatterns.first(where: { window.title.contains($0.pattern) }) {
                meetingName = meetingName ?? pattern.appName
                if let browserContext = MeetingAudioWindowCatalog.browserContext(
                    forApplicationName: window.owner
                ) {
                    browserContexts.insert(browserContext)
                }
                continue
            }

            if let browserContext = MeetingAudioWindowCatalog.browserContext(
                forApplicationName: window.owner
            ), window.title.hasPrefix("Meet -") || window.title.range(
                of: "[a-z]{3}-[a-z]{4}-[a-z]{3}",
                options: .regularExpression
            ) != nil {
                meetingName = meetingName ?? "Google Meet"
                browserContexts.insert(browserContext)
            }
        }

        return meetingName.map { MeetingWindowDetection(name: $0, browserContexts: browserContexts) }
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

        let windowInfo = windows.compactMap { window -> MeetingWindowInfo? in
            guard let owner = window[kCGWindowOwnerName as String] as? String,
                  let title = window[kCGWindowName as String] as? String else { return nil }
            return MeetingWindowInfo(owner: owner, title: title)
        }
        guard !Task.isCancelled else { return nil }
        return MeetingWindowDetector.detect(in: windowInfo)
    }
}
