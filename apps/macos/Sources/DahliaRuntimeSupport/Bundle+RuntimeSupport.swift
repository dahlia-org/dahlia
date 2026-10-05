import Foundation

extension Bundle {
    /// SPM 自動生成の `Bundle.module` は `.app` 直下とビルドマシンの絶対パスしか探さないため、
    /// 配布版では見つからず起動時に fatalError する。
    /// App (Contents/MacOS) と同梱 MCP (Contents/Helpers) は Contents/Resources を共有する。
    static let runtimeSupport: Bundle = {
        let embeddedURL = Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Dahlia_DahliaRuntimeSupport.bundle")
        return embeddedURL.flatMap(Bundle.init(url:)) ?? .module
    }()
}
