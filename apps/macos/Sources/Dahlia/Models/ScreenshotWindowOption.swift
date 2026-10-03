import CoreGraphics
@preconcurrency import ScreenCaptureKit

struct ScreenshotWindowOption: Identifiable, Equatable {
    struct Snapshot: Equatable {
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
