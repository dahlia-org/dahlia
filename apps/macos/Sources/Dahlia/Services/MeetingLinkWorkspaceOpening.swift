import Foundation

protocol MeetingLinkWorkspaceOpening: Sendable {
    func applicationURL(forBundleIdentifier bundleIdentifier: String) async -> URL?
    /// 開いたアプリの bundle identifier を返す。開けなかった場合は nil、開けたがアプリが分からない場合は空文字列。
    func open(_ url: URL, withApplicationAt applicationURL: URL?) async -> String?
}
