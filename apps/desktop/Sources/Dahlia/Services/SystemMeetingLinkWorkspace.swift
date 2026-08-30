import AppKit
import Foundation

struct SystemMeetingLinkWorkspace: MeetingLinkWorkspaceOpening {
    func applicationURL(forBundleIdentifier bundleIdentifier: String) async -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    func open(_ url: URL, withApplicationAt applicationURL: URL?) async -> Bool {
        await withCheckedContinuation { continuation in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.promptsUserIfNeeded = true

            let completionHandler: @Sendable (NSRunningApplication?, Error?) -> Void = { _, error in
                continuation.resume(returning: error == nil)
            }
            if let applicationURL {
                NSWorkspace.shared.open(
                    [url],
                    withApplicationAt: applicationURL,
                    configuration: configuration,
                    completionHandler: completionHandler
                )
            } else {
                NSWorkspace.shared.open(
                    url,
                    configuration: configuration,
                    completionHandler: completionHandler
                )
            }
        }
    }
}
