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
        func frontmostWindowSkipsOtherAppsAndSmallAuxiliaryWindows() {
            func snapshot(_ id: CGWindowID, _ bundleIdentifier: String, width: CGFloat = 1200) -> ScreenshotWindowOption.Snapshot {
                .init(
                    windowID: id,
                    appName: "App",
                    bundleIdentifier: bundleIdentifier,
                    title: "Window",
                    frame: CGRect(x: 0, y: 0, width: width, height: 800),
                    windowLayer: 0,
                    isOnScreen: true
                )
            }
            let snapshots = [
                snapshot(1, "com.google.Chrome"),
                snapshot(2, "com.google.Chrome.app.meet", width: 320),
                snapshot(3, "com.google.Chrome.app.meet"),
                snapshot(4, "com.google.Chrome.app.meet"),
            ]

            #expect(ScreenshotWindowOption.frontmostWindowID(
                from: snapshots,
                bundleIdentifier: "com.google.chrome.app.meet",
                frontToBack: [1, 2, 4, 3]
            ) == 4)
            #expect(ScreenshotWindowOption.frontmostWindowID(
                from: snapshots,
                bundleIdentifier: "us.zoom.xos",
                frontToBack: [1, 2, 4, 3]
            ) == nil)
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
