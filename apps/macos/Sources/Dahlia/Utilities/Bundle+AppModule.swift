import Foundation

extension Bundle {
    /// SPM 自動生成の `Bundle.module` をオーバーライドし、
    /// .app バンドル内の正しいリソースパスを解決する。
    ///
    /// SPM の `resource_bundle_accessor.swift` は `Bundle.main.bundleURL` 配下
    /// （= `Contents/MacOS/`）を探すが、`build-app.sh` はリソースバンドルを
    /// `Contents/Resources/` にコピーするためパスが食い違う。
    static let appModule: Bundle = {
        let bundleName = "Dahlia_Dahlia"

        let candidates = [
            // .app バンドルの Contents/Resources/ 配下（build-app.sh でのコピー先）
            Bundle.main.resourceURL,
            // SPM ビルド時（swift run）— bundleURL は実行ファイルと同階層
            Bundle.main.bundleURL,
        ]

        for candidate in candidates {
            let bundlePath = candidate?.appendingPathComponent(bundleName + ".bundle")
            if let bundlePath, let bundle = Bundle(path: bundlePath.path) {
                return bundle
            }
        }

        // XCTest / SwiftUI Previews では Bundle.main がアプリバンドルではないため、
        // SPM 自動生成の Bundle.module にフォールバックする。
        return .module
    }()
}
