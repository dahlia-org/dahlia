import CoreGraphics
@testable import Dahlia

#if canImport(Testing)
import Testing

struct ScreenshotWindowOptionTests {
    @Test
    func buildIncludesWindowFromAnotherDesktop() {
        let options = ScreenshotWindowOption.build(
            from: [
                .init(
                    windowID: 101,
                    appName: "Google Chrome",
                    bundleIdentifier: "com.google.Chrome",
                    title: "Databricks extension",
                    frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                    windowLayer: 0,
                    isOnScreen: false
                ),
            ],
            excludingBundleID: "com.matsuda.Dahlia"
        )

        #expect(options.count == 1)
        #expect(options[0].id == 101)
        #expect(options[0].isOnScreen == false)
        #expect(options[0].displayName == "Google Chrome — Databricks extension")
    }

    @Test
    func buildExcludesOwnAppUntitledAndZeroSizedWindows() {
        let options = ScreenshotWindowOption.build(
            from: [
                .init(
                    windowID: 1,
                    appName: "Dahlia",
                    bundleIdentifier: "com.matsuda.Dahlia",
                    title: "Control Panel",
                    frame: CGRect(x: 0, y: 0, width: 1000, height: 700),
                    windowLayer: 0,
                    isOnScreen: true
                ),
                .init(
                    windowID: 2,
                    appName: "Slack",
                    bundleIdentifier: "com.tinyspeck.slackmacgap",
                    title: "   ",
                    frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                    windowLayer: 0,
                    isOnScreen: true
                ),
                .init(
                    windowID: 3,
                    appName: "ChatGPT",
                    bundleIdentifier: "com.openai.chat",
                    title: "Summary",
                    frame: CGRect(x: 0, y: 0, width: 0, height: 800),
                    windowLayer: 0,
                    isOnScreen: true
                ),
                .init(
                    windowID: 4,
                    appName: "Codex",
                    bundleIdentifier: "com.openai.codex",
                    title: "dahlia",
                    frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                    windowLayer: 0,
                    isOnScreen: true
                ),
            ],
            excludingBundleID: "com.matsuda.Dahlia"
        )

        #expect(options.map(\.id) == [4])
        #expect(options[0].displayName == "Codex — dahlia")
    }
}
#endif
