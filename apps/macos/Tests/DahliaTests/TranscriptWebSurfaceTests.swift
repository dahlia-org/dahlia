#if canImport(Testing)
    import AppKit
    import Testing
    import WebKit
    @testable import Dahlia

    @MainActor
    struct TranscriptWebSurfaceTests {
        @Test
        func rowsHideTranslationsWhenOffAndNameSpeakers() {
            let segment = TranscriptSegment(
                startTime: .now, text: "原文", translatedText: "Translation", isConfirmed: true, speakerLabel: "話者B"
            )
            let shown = TranscriptWebSurface.row(segment, sessions: [], timeBase: segment.startTime, showsTranslatedText: true)
            let hidden = TranscriptWebSurface.row(segment, sessions: [], timeBase: segment.startTime, showsTranslatedText: false)
            #expect(shown.translation == "Translation")
            #expect(hidden.translation == nil)
            #expect(shown.speaker == "話者B")
            #expect(shown.speakerColor == "-apple-system-orange")
            #expect(shown.time == "00:00:00")
        }

        @Test
        func renderedRowsFollowTheStoreAndRecoverWhenThePageStopsResponding() async throws {
            let harness = Harness()
            let segments = (0 ..< 300).map { index in
                TranscriptSegment(startTime: Date(timeIntervalSince1970: Double(index)), text: "row \(index)", isConfirmed: true)
            }
            harness.show(segments)
            #expect(await harness.waitForRows(300, firstText: "row 0"))

            // A changed translation reaches the page without resending every row.
            var updated = segments
            updated[299].translatedText = "translated"
            harness.show(updated, showsTranslatedText: true)
            #expect(await harness.waitForText("translated"))

            // A page that never reports a frame is reloaded, and the reload receives the whole window again.
            _ = try await harness.webView.evaluateJavaScript("window.dahliaTranscript.apply = () => {}; true")
            harness.show(Array(updated.prefix(10)), showsTranslatedText: true)
            #expect(await harness.waitForRows(10, firstText: "row 0"))
        }

        @Test
        func shortInitialPageStartsFollowingLiveSegments() async {
            let harness = Harness()
            let store = TranscriptStore()
            store.loadSegments([TranscriptSegment(startTime: .now, text: "initial", isConfirmed: true)])
            store.setFollowingLatest(false)
            var following = false
            harness.coordinator.parent = Harness.surface(store.segments, showsTranslatedText: false, onFollowChange: {
                following = $0
                store.setFollowingLatest($0)
            })
            harness.coordinator.contentDidChange()
            #expect(await pollUntil { following })
            store.addSegment(TranscriptSegment(startTime: .now, text: "live", isConfirmed: true))
            #expect(store.segments.last?.text == "live")
        }

        @Test
        func pagingPreservesTheVisibleRowWhenPrependingAndTrimming() async throws {
            let harness = Harness()
            let segments = (0 ..< 400).map { index in
                TranscriptSegment(
                    startTime: Date(timeIntervalSince1970: Double(index)),
                    text: "row \(index) " + String(repeating: "text ", count: 12),
                    isConfirmed: true
                )
            }
            harness.show(Array(segments[100 ..< 400]))
            #expect(await harness.waitForRows(300, firstText: segments[100].text))
            let anchorID = segments[220].text
            let before = try await harness.webView.callAsyncJavaScript("""
            const row = document.querySelectorAll('.row')[120];
            document.scrollingElement.scrollTop = row.offsetTop + 5;
            return row.getBoundingClientRect().top;
            """, arguments: [:], in: nil, contentWorld: .page) as? Double
            let y = try #require(before)
            harness.show(Array(segments[0 ..< 300]))
            #expect(await harness.waitForRows(300, firstText: segments[0].text))
            #expect(await harness.waitForRow(anchorID, at: y))
            harness.show(Array(segments[100 ..< 400]))
            #expect(await harness.waitForRows(300, firstText: segments[100].text))
            #expect(await harness.waitForRow(anchorID, at: y))
        }

        @Test
        func responseTimeoutRecoversAfterHiddenWindowBecomesVisible() async throws {
            let harness = Harness()
            harness.show([TranscriptSegment(startTime: .now, text: "initial", isConfirmed: true)])
            #expect(await harness.waitForRows(1, firstText: "initial"))
            _ = try await harness.webView.evaluateJavaScript("window.dahliaTranscript.apply = () => {}; true")
            let visibility = Visibility()
            harness.coordinator.isDisplayed = {
                visibility.checks += 1
                return visibility.visible
            }
            harness.show([TranscriptSegment(startTime: .now, text: "recovered", isConfirmed: true)])
            #expect(await pollUntil { visibility.checks > 0 })
            visibility.visible = true
            #expect(await harness.waitForRows(1, firstText: "recovered"))
        }

        @MainActor
        private final class Visibility {
            var visible = false
            var checks = 0
        }

        @MainActor
        private final class Harness {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            let webView: WKWebView
            let coordinator: TranscriptWebSurface.Coordinator

            init() {
                let surface = Self.surface([], showsTranslatedText: false)
                coordinator = surface.makeCoordinator()
                coordinator.responseTimeout = .milliseconds(300)
                coordinator.isDisplayed = { true }
                let configuration = WKWebViewConfiguration()
                configuration.userContentController.add(coordinator, name: "transcript")
                webView = WKWebView(frame: window.contentLayoutRect, configuration: configuration)
                window.contentView = webView
                coordinator.view = webView
                coordinator.load()
            }

            func show(_ segments: [TranscriptSegment], showsTranslatedText: Bool = false) {
                coordinator.parent = Self.surface(segments, showsTranslatedText: showsTranslatedText)
                coordinator.contentDidChange()
            }

            func waitForRows(_ count: Int, firstText: String) async -> Bool {
                await pollUntil { [webView] in
                    let result = try? await webView.evaluateJavaScript(
                        "[document.querySelectorAll('.row').length, document.querySelector('.row .text')?.textContent ?? '']"
                    ) as? [Any]
                    return result?.first as? Int == count && result?.last as? String == firstText
                }
            }

            func waitForText(_ text: String) async -> Bool {
                await pollUntil { [webView] in
                    await (try? webView.evaluateJavaScript("document.body.innerText.includes('\(text)')") as? Bool) == true
                }
            }

            func waitForRow(_ id: String, at y: Double) async -> Bool {
                await pollUntil { [webView] in
                    guard let current = try? await webView.callAsyncJavaScript(
                        "return [...document.querySelectorAll('.row')].find(row => row.querySelector('.text')?.textContent === id)?.getBoundingClientRect().top",
                        arguments: ["id": id], in: nil, contentWorld: .page
                    ) as? Double else { return false }
                    return abs(current - y) < 2
                }
            }

            static func surface(
                _ segments: [TranscriptSegment],
                showsTranslatedText: Bool,
                onFollowChange: @escaping @MainActor (Bool) -> Void = { _ in }
            ) -> TranscriptWebSurface {
                TranscriptWebSurface(
                    contentID: "meeting", segments: segments, recordingSessions: [], timeBase: Date(timeIntervalSince1970: 0),
                    showsTranslatedText: showsTranslatedText, hasEarlier: false, hasLater: false, scrollRequest: nil,
                    onRequestPage: { _ in }, onFollowChange: onFollowChange
                )
            }
        }
    }
#endif
