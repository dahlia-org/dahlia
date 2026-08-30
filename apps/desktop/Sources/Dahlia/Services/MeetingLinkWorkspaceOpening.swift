import Foundation

protocol MeetingLinkWorkspaceOpening: Sendable {
    func applicationURL(forBundleIdentifier bundleIdentifier: String) async -> URL?
    func open(_ url: URL, withApplicationAt applicationURL: URL?) async -> Bool
}
