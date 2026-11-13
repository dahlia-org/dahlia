import AppKit
import CoreGraphics
@preconcurrency import ScreenCaptureKit

struct ScreenshotWindowOption: Identifiable, Equatable {
    struct Snapshot: Equatable, Sendable {
        let windowID: CGWindowID
        let appName: String?
        let bundleIdentifier: String?
        let title: String?
        let frame: CGRect
        let windowLayer: Int
        let isOnScreen: Bool
    }

    let id: CGWindowID
    let appName: String
    let title: String
    let isOnScreen: Bool

    var displayName: String {
        title.isEmpty ? appName : "\(appName) — \(title)"
    }

    static func build(from snapshots: [Snapshot], excludingBundleID bundleID: String?) -> [Self] {
        snapshots
            .compactMap { snapshot in
                guard snapshot.frame.width > 0,
                      snapshot.frame.height > 0,
                      snapshot.windowLayer == 0 else {
                    return nil
                }

                let title = snapshot.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !title.isEmpty else { return nil }
                guard snapshot.bundleIdentifier != bundleID else { return nil }

                let trimmedAppName = snapshot.appName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let appName = trimmedAppName.isEmpty ? "不明" : trimmedAppName

                return Self(
                    id: snapshot.windowID,
                    appName: appName,
                    title: title,
                    isOnScreen: snapshot.isOnScreen
                )
            }
            .sorted(by: sort)
    }

    /// 会議リンクを開いたアプリのウィンドウのうち、開く前になかったもの、なければ開く前からタイトルが変わったもの。
    /// 前者は PWA や新しいウィンドウ、後者は既存のウィンドウにタブで開いた場合にあたる。
    /// `snapshots` は前面から順に並べ、`titlesBeforeOpening` にはリンクを開く直前の `Snapshot.titlesOnScreen()` を渡す。
    static func meetingWindowID(
        from snapshots: [Snapshot],
        bundleIdentifier: String,
        titlesBeforeOpening: [CGWindowID: String]
    ) -> CGWindowID? {
        let candidates = meetingWindowCandidates(from: snapshots, bundleIdentifier: bundleIdentifier)
        let opened = candidates.first { titlesBeforeOpening[$0.windowID] == nil }
            ?? candidates.first { titlesBeforeOpening[$0.windowID] != $0.title }
        return opened?.windowID
    }

    /// 指定アプリの、画面上で最も前面にあるウィンドウ。`snapshots` は前面から順に並べる。
    static func frontmostWindowID(from snapshots: [Snapshot], bundleIdentifier: String) -> CGWindowID? {
        meetingWindowCandidates(from: snapshots, bundleIdentifier: bundleIdentifier).first?.windowID
    }

    /// 取得対象の一覧に出る（タイトルのある通常の）ウィンドウに限る。
    /// 翻訳の吹き出しや Picture in Picture など、同じアプリの小さな補助ウィンドウは会議画面ではない。
    private static func meetingWindowCandidates(from snapshots: [Snapshot], bundleIdentifier: String) -> [Snapshot] {
        snapshots.filter {
            $0.bundleIdentifier?.lowercased() == bundleIdentifier.lowercased()
                && $0.windowLayer == 0
                && $0.title?.isEmpty == false
                && $0.frame.width >= 400 && $0.frame.height >= 300
        }
    }

    private static func sort(lhs: Self, rhs: Self) -> Bool {
        let appOrder = lhs.appName.localizedCaseInsensitiveCompare(rhs.appName)
        if appOrder != .orderedSame {
            return appOrder == .orderedAscending
        }

        let titleOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        if titleOrder != .orderedSame {
            return titleOrder == .orderedAscending
        }

        return lhs.id < rhs.id
    }
}

extension ScreenshotWindowOption.Snapshot {
    init(window: SCWindow) {
        self.init(
            windowID: window.windowID,
            appName: window.owningApplication?.applicationName,
            bundleIdentifier: window.owningApplication?.bundleIdentifier,
            title: window.title,
            frame: window.frame,
            windowLayer: window.windowLayer,
            isOnScreen: window.isOnScreen
        )
    }
}

extension ScreenshotWindowOption.Snapshot {
    /// 画面上の通常ウィンドウの ID とタイトル。`onScreen()` と同じ情報源なので、後で差分を取れる。
    static func titlesOnScreen() -> [CGWindowID: String] {
        Dictionary(
            windowInfoOnScreen().compactMap { window in
                guard window[kCGWindowLayer] as? Int == 0,
                      let windowID = window[kCGWindowNumber] as? CGWindowID else { return nil }
                return (windowID, title(of: window))
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// 画面上のウィンドウ。前面から順に並ぶ。
    static func onScreen() -> [Self] {
        var bundleIdentifiers: [pid_t: String?] = [:]
        return windowInfoOnScreen().compactMap { window in
            guard let windowID = window[kCGWindowNumber] as? CGWindowID,
                  let processID = window[kCGWindowOwnerPID] as? pid_t else { return nil }
            let bundleIdentifier = bundleIdentifiers[processID]
                ?? NSRunningApplication(processIdentifier: processID)?.bundleIdentifier
            bundleIdentifiers[processID] = bundleIdentifier
            return Self(
                windowID: windowID,
                appName: window[kCGWindowOwnerName] as? String,
                bundleIdentifier: bundleIdentifier,
                title: title(of: window),
                frame: (window[kCGWindowBounds] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero,
                windowLayer: window[kCGWindowLayer] as? Int ?? 0,
                isOnScreen: true
            )
        }
    }

    private static func windowInfoOnScreen() -> [[CFString: Any]] {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[CFString: Any]] ?? []
    }

    private static func title(of window: [CFString: Any]) -> String {
        (window[kCGWindowName] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
