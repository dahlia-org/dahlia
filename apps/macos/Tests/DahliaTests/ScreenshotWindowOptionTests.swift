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
        func meetingWindowIsNewOrRetitledSinceTheLinkOpened() {
            let meet = "com.google.Chrome.app.meet"
            let chrome = "com.google.Chrome"
            // 前面から順。開く前は Chrome の 1・5 と、Meet PWA のホーム画面 3 があった。
            let before: [CGWindowID: String] = [1: "Slides", 3: "Google Meet", 5: "Inbox"]

            // PWA: 小さな吹き出し 2 と開く前からある 3 を除き、新しい 4 を選ぶ。3 が前面でも変わらない。
            let pwaWindows = [
                snapshot(1, chrome, "Slides"),
                snapshot(2, meet, "Translate?", width: 320),
                snapshot(3, meet, "Google Meet"),
                snapshot(4, meet, "Meet - abc"),
            ]
            #expect(ScreenshotWindowOption.meetingWindowID(
                from: pwaWindows,
                bundleIdentifier: "com.google.chrome.app.meet",
                titlesBeforeOpening: before
            ) == 4)

            // 会議のウィンドウがまだ開いていなければ選ばない。最前面へのフォールバックは別の関数。
            #expect(ScreenshotWindowOption.meetingWindowID(
                from: Array(pwaWindows.prefix(3)),
                bundleIdentifier: meet,
                titlesBeforeOpening: before
            ) == nil)
            #expect(ScreenshotWindowOption.frontmostWindowID(from: pwaWindows, bundleIdentifier: meet) == 3)
            #expect(ScreenshotWindowOption.frontmostWindowID(from: pwaWindows, bundleIdentifier: "us.zoom.xos") == nil)

            // タブ: 既存のウィンドウ 5 のタイトルが変わった。
            let tabWindows = [snapshot(1, chrome, "Slides"), snapshot(5, chrome, "Meet - abc")]
            #expect(ScreenshotWindowOption.meetingWindowID(
                from: tabWindows,
                bundleIdentifier: chrome,
                titlesBeforeOpening: before
            ) == 5)

            // 新しいウィンドウは、タイトルが変わっただけの前面のウィンドウより優先する。タイトルのないウィンドウは選ばない。
            #expect(ScreenshotWindowOption.meetingWindowID(
                from: [snapshot(1, chrome, "Slides (1)"), snapshot(6, chrome, ""), snapshot(7, chrome, "Meet - abc")],
                bundleIdentifier: chrome,
                titlesBeforeOpening: before
            ) == 7)
        }

        private func snapshot(
            _ id: CGWindowID,
            _ bundleIdentifier: String,
            _ title: String,
            width: CGFloat = 1200
        ) -> ScreenshotWindowOption.Snapshot {
            .init(
                windowID: id,
                appName: "App",
                bundleIdentifier: bundleIdentifier,
                title: title,
                frame: CGRect(x: 0, y: 0, width: width, height: 800),
                windowLayer: 0,
                isOnScreen: true
            )
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
