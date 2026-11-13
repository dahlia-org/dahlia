import AppKit
import Foundation

struct SystemMeetingLinkWorkspace: MeetingLinkWorkspaceOpening {
    func applicationURL(forBundleIdentifier bundleIdentifier: String) async -> URL? {
        // Chrome 系 PWA の shim は、同じアプリ ID なら別のユーザーデータのものも同じ bundle identifier を持つ。
        // インストール先が残っているものを優先する。
        let applicationURLs = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleIdentifier)
        return applicationURLs.first { applicationURL in
            let infoDictionary = Bundle(url: applicationURL)?.infoDictionary ?? [:]
            return infoDictionary["CrAppModeShortcutID"] == nil
                || Self.chromeAppInstallation(infoDictionary: infoDictionary) != nil
        } ?? applicationURLs.first
    }

    func open(_ url: URL, withApplicationAt applicationURL: URL?) async -> String? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.promptsUserIfNeeded = true

        if let applicationURL,
           let bundle = Bundle(url: applicationURL),
           let arguments = Self.chromeAppLaunchArguments(infoDictionary: bundle.infoDictionary ?? [:], url: url),
           let browserIdentifier = bundle.object(forInfoDictionaryKey: "CrBundleIdentifier") as? String,
           let browserURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browserIdentifier) {
            configuration.arguments = arguments
            // 起動中のブラウザーへ引数を渡すため、別インスタンスとして起動する（引数を転送してすぐ終了する）。
            configuration.createsNewApplicationInstance = true
            return await withCheckedContinuation { continuation in
                NSWorkspace.shared.openApplication(at: browserURL, configuration: configuration) { _, error in
                    continuation.resume(returning: error == nil ? bundle.bundleIdentifier : nil)
                }
            }
        }

        return await withCheckedContinuation { continuation in
            let completionHandler: @Sendable (NSRunningApplication?, Error?) -> Void = { application, error in
                continuation.resume(returning: error == nil ? application?.bundleIdentifier ?? "" : nil)
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

    /// Chrome 系 PWA のアプリ shim は https の URL を渡しても捨てて開始ページを開く。
    /// ブラウザー本体にアプリ ID と URL を渡すと、その URL を PWA のウィンドウで開く。
    static func chromeAppLaunchArguments(infoDictionary: [String: Any], url: URL) -> [String]? {
        guard let appID = infoDictionary["CrAppModeShortcutID"] as? String else { return nil }
        let installation = chromeAppInstallation(infoDictionary: infoDictionary).map {
            ["--user-data-dir=\($0.userDataDirectory)", "--profile-directory=\($0.profileDirectory)"]
        }
        return (installation ?? [])
            + ["--app-id=\(appID)", "--app-launch-url-for-shortcuts-menu-item=\(url.absoluteString)"]
    }

    /// PWA をインストールしてあるブラウザーのユーザーデータとプロファイル。
    /// 指定しないと既定のユーザーデータの、最後に使ったプロファイルで開こうとし、そこに PWA がなければ開かない。
    /// shim の `CrAppModeUserDataDir` は `<ユーザーデータ>/-/Web Applications/…` で、
    /// プロファイルごとの `Web Applications/Manifest Resources/<アプリ ID>` がインストール先を示す。
    static func chromeAppInstallation(
        infoDictionary: [String: Any]
    ) -> (userDataDirectory: String, profileDirectory: String)? {
        guard let appID = infoDictionary["CrAppModeShortcutID"] as? String,
              let shimDataDirectory = infoDictionary["CrAppModeUserDataDir"] as? String,
              let userDataDirectory = shimDataDirectory.components(separatedBy: "/-/").first,
              let profiles = try? FileManager.default.contentsOfDirectory(atPath: userDataDirectory),
              let profileDirectory = profiles.sorted().first(where: { profile in
                  FileManager.default.fileExists(
                      atPath: "\(userDataDirectory)/\(profile)/Web Applications/Manifest Resources/\(appID)"
                  )
              })
        else { return nil }
        return (userDataDirectory, profileDirectory)
    }
}
