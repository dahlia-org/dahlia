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

        @Test(arguments: [false, true])
        func recoveryPreservesCurrentReadingOrLiveFollowing(following: Bool) async throws {
            let harness = Harness()
            let store = TranscriptStore()
            store.loadSegments((0 ..< 200).map { index in
                TranscriptSegment(startTime: Date(timeIntervalSince1970: Double(index)), text: "row \(index)", isConfirmed: true)
            })
            let state = FollowState()
            let follow: @MainActor (Bool) -> Void = {
                state.following = $0
                store.setFollowingLatest($0)
            }
            harness.show(store.segments, scrollRequest: (1, .top), onFollowChange: follow)
            #expect(await harness.waitForRows(200, firstText: "row 0"))
            // Offscreen WebKit does not schedule frames. Let this test drive the same scroll callback.
            let y = try #require(try await harness.webView.callAsyncJavaScript("""
            window.requestAnimationFrame = callback => { setTimeout(callback, 0); return 0; };
            const row = document.querySelectorAll('.row')[100];
            document.scrollingElement.scrollTop = following ? document.scrollingElement.scrollHeight : row.offsetTop + 5;
            window.dispatchEvent(new Event('scroll'));
            await new Promise(requestAnimationFrame);
            return row.getBoundingClientRect().top;
            """, arguments: ["following": following], in: nil, contentWorld: .page) as? Double)
            #expect(await pollUntil { state.following == following })
            // A JS round trip also ensures the scroll report has crossed the script-message boundary.
            _ = try await harness.webView.evaluateJavaScript("window.beforeRecovery = true")
            if following {
                _ = try await harness.webView.evaluateJavaScript("window.dahliaTranscript.apply = () => {}; true")
                var updated = store.segments
                updated[199].translatedText = "recovered"
                harness.show(updated, showsTranslatedText: true, scrollRequest: (1, .top), onFollowChange: follow)
                #expect(await harness.waitForText("recovered"))
            } else {
                harness.coordinator.webViewWebContentProcessDidTerminate(harness.webView)
                #expect(await pollUntil {
                    await (try? harness.webView
                        .evaluateJavaScript(
                            "typeof window.beforeRecovery === 'undefined' && document.querySelectorAll('.row').length === 200"
                        ) as? Bool) ==
                        true
                })
            }
            if following {
                #expect(await pollUntil { state.following })
                store.addSegment(TranscriptSegment(startTime: .now, text: "live after recovery", isConfirmed: true))
                #expect(store.segments.last?.text == "live after recovery")
                harness.show(store.segments, scrollRequest: (1, .top), onFollowChange: follow)
                #expect(await harness.waitForText("live after recovery"))
                #expect(await harness.isAtBottom())
            } else {
                #expect(await harness.waitForRow("row 100", at: y))
                // A command sent but not presented must override the saved reading position on recovery.
                _ = try await harness.webView.evaluateJavaScript("window.dahliaTranscript.apply = () => {}; true")
                harness.show(store.segments, scrollRequest: (2, .bottom), onFollowChange: follow)
                harness.coordinator.webViewWebContentProcessDidTerminate(harness.webView)
                #expect(await pollUntil { state.following })
                #expect(await harness.isAtBottom())
                // Command tokens belong to one content identity, even when a new Meeting reuses its token.
                harness.show(store.segments, contentID: "other", scrollRequest: (2, .top), onFollowChange: follow)
                #expect(await pollUntil {
                    await (try? harness.webView.evaluateJavaScript("document.scrollingElement.scrollTop") as? Double) == 0
                })
                #expect(await pollUntil { !state.following })
            }
        }

        @Test
        func existingPageAppliesChangedTextSizeWithoutReloading() async {
            let harness = Harness()
            let segments = [TranscriptSegment(startTime: .now, text: "font", isConfirmed: true)]
            harness.show(segments)
            #expect(await harness.waitForRows(1, firstText: "font"))
            _ = try? await harness.webView.evaluateJavaScript("window.sameDocument = true")
            harness.show(segments, baseSize: 18)
            #expect(await pollUntil {
                await (try? harness.webView.evaluateJavaScript("getComputedStyle(document.querySelector('.text')).fontSize") as? String) == "18px"
            })
            #expect(await (try? harness.webView.evaluateJavaScript("window.sameDocument") as? Bool) == true)
        }

        @Test(arguments: [TranscriptWebSurface.Edge.top, .bottom], [false, true])
        func stationaryUpdatesReportViewportWithoutRequestingPages(
            edge: TranscriptWebSurface.Edge,
            deliversScrollBeforeUpdate: Bool
        ) async throws {
            let harness = Harness()
            let requests = PageRequests()
            let request: @MainActor (TranscriptWebSurface.Edge) -> Void = { requests.values.append($0) }
            var segments = (0 ..< 200).map { index in
                TranscriptSegment(startTime: Date(timeIntervalSince1970: Double(index)), text: "row \(index)", isConfirmed: true)
            }
            harness.show(segments, onRequestPage: request)
            #expect(await harness.waitForRows(200, firstText: "row 0"))
            _ = try await harness.webView.callAsyncJavaScript("""
            window.requestAnimationFrame = callback => { setTimeout(callback, 0); return 0; };
            const scroller = document.scrollingElement;
            scroller.scrollTop = earlier ? 500 : scroller.scrollHeight - scroller.clientHeight - 500;
            window.dispatchEvent(new Event('scroll'));
            await new Promise(requestAnimationFrame);
            """, arguments: ["earlier": edge == .top], in: nil, contentWorld: .page)
            for index in 0 ..< 3 {
                // Height changes above the viewport also generate programmatic scroll events.
                segments[0].translatedText = index.isMultiple(of: 2) ? "update \(index)" : "update \(index)\nsecond line"
                harness.show(
                    segments, showsTranslatedText: true, hasEarlier: edge == .top, hasLater: edge == .bottom,
                    onRequestPage: request
                )
                #expect(await harness.waitForText("update \(index)"))
                _ = try await harness.webView.callAsyncJavaScript("""
                window.dispatchEvent(new Event('scroll'));
                await new Promise(requestAnimationFrame);
                """, arguments: [:], in: nil, contentWorld: .page)
                #expect(requests.values.isEmpty)
            }
            _ = try await harness.webView.callAsyncJavaScript("""
            Object.defineProperty(document, 'visibilityState', { value: 'visible', configurable: true });
            window.scrollFrames = [];
            window.requestAnimationFrame = callback => { window.scrollFrames.push(callback); return window.scrollFrames.length; };
            window.holdsScrollEvents = true;
            window.addEventListener('scroll', event => {
              if (window.holdsScrollEvents) event.stopImmediatePropagation();
            }, { capture: true });
            document.scrollingElement.scrollTop = earlier ? 0 : document.scrollingElement.scrollHeight;
            if (deliverBefore) {
              window.holdsScrollEvents = false;
              window.dispatchEvent(new Event('scroll'));
              window.holdsScrollEvents = true;
            }
            """, arguments: ["earlier": edge == .top, "deliverBefore": deliversScrollBeforeUpdate], in: nil, contentWorld: .page)
            // Cover both event delivery orderings around apply, including movement to a clamped edge.
            segments[0].translatedText = "overlapping update"
            harness.show(
                segments, showsTranslatedText: true, hasEarlier: edge == .top, hasLater: edge == .bottom,
                onRequestPage: request
            )
            #expect(await harness.waitForText("overlapping update"))
            _ = try await harness.webView.evaluateJavaScript("""
            window.holdsScrollEvents = false;
            window.dispatchEvent(new Event('scroll'));
            for (const frame of window.scrollFrames.splice(0)) frame();
            true
            """)
            #expect(await pollUntil { requests.values == [edge] })
            // A new content identity / explicit destination replaces a previously queued scroll demand.
            _ = try await harness.webView.evaluateJavaScript("""
            document.scrollingElement.scrollTop += document.scrollingElement.scrollTop === 0 ? 100 : -100;
            window.dispatchEvent(new Event('scroll')); true
            """)
            segments[0].text = "new context"
            harness.show(segments, contentID: "other", hasEarlier: true, hasLater: true, scrollRequest: (1, .top), onRequestPage: request)
            #expect(await harness.waitForText("new context"))
            _ = try await harness.webView.evaluateJavaScript("for (const frame of window.scrollFrames.splice(0)) frame(); true")
            #expect(requests.values == [edge])
        }

        @MainActor
        private final class PageRequests {
            var values: [TranscriptWebSurface.Edge] = []
        }

        @MainActor
        private final class FollowState {
            var following = false
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

            func show(
                _ segments: [TranscriptSegment],
                showsTranslatedText: Bool = false,
                contentID: String = "meeting",
                hasEarlier: Bool = false,
                hasLater: Bool = false,
                baseSize: CGFloat = 14,
                scrollRequest: (token: Int, edge: TranscriptWebSurface.Edge)? = nil,
                onFollowChange: @escaping @MainActor (Bool) -> Void = { _ in },
                onRequestPage: @escaping @MainActor (TranscriptWebSurface.Edge) -> Void = { _ in }
            ) {
                coordinator.parent = Self.surface(
                    segments, showsTranslatedText: showsTranslatedText, contentID: contentID,
                    hasEarlier: hasEarlier, hasLater: hasLater, baseSize: baseSize,
                    scrollRequest: scrollRequest, onFollowChange: onFollowChange, onRequestPage: onRequestPage
                )
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

            func isAtBottom() async -> Bool {
                await pollUntil { [webView] in
                    await (try? webView
                        .evaluateJavaScript(
                            "document.scrollingElement.scrollHeight - document.scrollingElement.scrollTop - document.scrollingElement.clientHeight < 24"
                        ) as? Bool) ==
                        true
                }
            }

            func waitForText(_ text: String) async -> Bool {
                await pollUntil { [webView] in
                    await (try? webView.evaluateJavaScript("document.body.textContent.includes('\(text)')") as? Bool) == true
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
                contentID: String = "meeting",
                hasEarlier: Bool = false,
                hasLater: Bool = false,
                baseSize: CGFloat = 14,
                scrollRequest: (token: Int, edge: TranscriptWebSurface.Edge)? = nil,
                onFollowChange: @escaping @MainActor (Bool) -> Void = { _ in },
                onRequestPage: @escaping @MainActor (TranscriptWebSurface.Edge) -> Void = { _ in }
            ) -> TranscriptWebSurface {
                TranscriptWebSurface(
                    contentID: contentID, segments: segments, recordingSessions: [], timeBase: Date(timeIntervalSince1970: 0),
                    showsTranslatedText: showsTranslatedText, hasEarlier: hasEarlier, hasLater: hasLater, baseSize: baseSize,
                    scrollRequest: scrollRequest,
                    onRequestPage: onRequestPage, onFollowChange: onFollowChange
                )
            }
        }
    }
#endif
