#if canImport(Testing)
    import AppKit
    import Testing
    import UniformTypeIdentifiers
    @testable import Dahlia

    @MainActor
    struct ScreenshotOverlayViewTests {
        @Test
        func fittedSizePreservesLandscapeAndPortraitAspectRatios() {
            #expect(ScreenshotOverlayLayout.fittedSize(
                imageSize: CGSize(width: 1600, height: 900),
                availableSize: CGSize(width: 800, height: 600)
            ) == CGSize(width: 800, height: 450))
            #expect(ScreenshotOverlayLayout.fittedSize(
                imageSize: CGSize(width: 900, height: 1600),
                availableSize: CGSize(width: 800, height: 600)
            ) == CGSize(width: 337.5, height: 600))
        }

        @Test
        func fittedSizeRejectsEmptyDimensions() {
            #expect(ScreenshotOverlayLayout.fittedSize(
                imageSize: .zero,
                availableSize: CGSize(width: 800, height: 600)
            ) == .zero)
            #expect(ScreenshotOverlayLayout.fittedSize(
                imageSize: CGSize(width: 1600, height: 900),
                availableSize: .zero
            ) == .zero)
        }

        @Test
        func copyWritesOriginalImageWithoutDismissingOverlay() async throws {
            let mouseFixture = try makeMouseFixture(
                eventType: .leftMouseDown,
                eventLocation: CGPoint(x: 50, y: 50)
            )
            let pasteboard = NSPasteboard(name: .init("ScreenshotOverlayViewTests-\(UUID().uuidString)"))
            let imageData = try #require(TestScreenshotImageFixture.data(using: .jpeg))
            let screenshot = MeetingScreenshotRecord(
                id: .v7(),
                meetingId: .v7(),
                capturedAt: .now,
                imageData: imageData,
                mimeType: "image/jpeg"
            )
            var dismissCount = 0
            let view = ScreenshotOverlayView(
                screenshot: screenshot,
                previewImage: nil,
                requestedAt: .now,
                canGoPrevious: false,
                canGoNext: false,
                onPrevious: {},
                onNext: {}
            ) {
                dismissCount += 1
            }
            let coordinator = ScreenshotOverlayInputMonitor.Coordinator {
                dismissCount += 1
            }

            let handledEvent = coordinator.handle(mouseFixture.event, in: mouseFixture.view)
            await view.copyImage(to: pasteboard)

            let type = NSPasteboard.PasteboardType(UTType.jpeg.identifier)
            #expect(handledEvent === mouseFixture.event)
            #expect(pasteboard.data(forType: type) == screenshot.imageData)
            #expect(dismissCount == 0)
        }

        @Test
        func imageClickIsForwardedWithoutDismissal() throws {
            let fixture = try makeMouseFixture(
                eventType: .leftMouseDown,
                eventLocation: CGPoint(x: 50, y: 50)
            )
            var dismissCount = 0
            let coordinator = ScreenshotOverlayInputMonitor.Coordinator {
                dismissCount += 1
            }

            let handledEvent = coordinator.handle(fixture.event, in: fixture.view)

            #expect(handledEvent === fixture.event)
            #expect(dismissCount == 0)
        }

        @Test
        func outsideMouseClicksAreForwardedAndDismiss() async throws {
            for eventType in [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown] {
                let fixture = try makeMouseFixture(
                    eventType: eventType,
                    eventLocation: CGPoint(x: 150, y: 150)
                )
                var dismissCount = 0
                let coordinator = ScreenshotOverlayInputMonitor.Coordinator {
                    dismissCount += 1
                }

                let handledEvent = coordinator.handle(fixture.event, in: fixture.view)

                #expect(handledEvent === fixture.event)
                #expect(dismissCount == 0)
                await waitUntil { dismissCount == 1 }
                #expect(dismissCount == 1)
            }
        }

        @Test
        func mouseUpOutsideImageIsForwardedWithoutDismissal() throws {
            let fixture = try makeMouseFixture(
                eventType: .leftMouseUp,
                eventLocation: CGPoint(x: 150, y: 150)
            )
            var dismissCount = 0
            let coordinator = ScreenshotOverlayInputMonitor.Coordinator {
                dismissCount += 1
            }

            let handledEvent = coordinator.handle(fixture.event, in: fixture.view)

            #expect(handledEvent === fixture.event)
            #expect(dismissCount == 0)
        }

        @Test
        func installedMonitorReceivesOutsideMouseDown() async throws {
            let fixture = try makeMouseFixture(
                eventType: .leftMouseDown,
                eventLocation: CGPoint(x: 150, y: 150)
            )
            var dismissCount = 0
            let coordinator = ScreenshotOverlayInputMonitor.Coordinator {
                dismissCount += 1
            }
            coordinator.startMonitoring(view: fixture.view)
            defer { coordinator.stopMonitoring() }

            NSApp.sendEvent(fixture.event)

            await waitUntil { dismissCount == 1 }
            #expect(dismissCount == 1)
        }

        @Test
        func escapeInOverlayWindowIsConsumedAndDismisses() throws {
            let fixture = try makeKeyFixture(keyCode: 53)
            var dismissCount = 0
            let coordinator = ScreenshotOverlayInputMonitor.Coordinator {
                dismissCount += 1
            }

            let handledEvent = coordinator.handle(fixture.event, in: fixture.view)

            #expect(handledEvent == nil)
            #expect(dismissCount == 1)
        }

        @Test
        func otherKeysAreForwardedWithoutDismissal() throws {
            let fixture = try makeKeyFixture(keyCode: 36)
            var dismissCount = 0
            let coordinator = ScreenshotOverlayInputMonitor.Coordinator {
                dismissCount += 1
            }

            let handledEvent = coordinator.handle(fixture.event, in: fixture.view)

            #expect(handledEvent === fixture.event)
            #expect(dismissCount == 0)
        }

        @Test
        func arrowKeysInOverlayWindowAreConsumedAndNavigate() throws {
            let cases: [(keyCode: UInt16, expectedPrevious: Int, expectedNext: Int)] = [
                (123, 1, 0),
                (124, 0, 1),
            ]

            for testCase in cases {
                let fixture = try makeKeyFixture(keyCode: testCase.keyCode)
                var dismissCount = 0
                var previousCount = 0
                var nextCount = 0
                let coordinator = ScreenshotOverlayInputMonitor.Coordinator(
                    onDismiss: { dismissCount += 1 },
                    onPrevious: { previousCount += 1 },
                    onNext: { nextCount += 1 }
                )

                let handledEvent = coordinator.handle(fixture.event, in: fixture.view)

                #expect(handledEvent == nil)
                #expect(previousCount == testCase.expectedPrevious)
                #expect(nextCount == testCase.expectedNext)
                #expect(dismissCount == 0)
            }
        }

        @Test
        func arrowKeyInAnotherWindowIsForwardedWithoutNavigating() throws {
            let fixture = try makeKeyFixture(keyCode: 124)
            let otherWindow = makeWindow()
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: otherWindow.windowNumber,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: 124
            ))
            var nextCount = 0
            let coordinator = ScreenshotOverlayInputMonitor.Coordinator(
                onDismiss: {},
                onPrevious: {},
                onNext: { nextCount += 1 }
            )

            let handledEvent = coordinator.handle(event, in: fixture.view)

            #expect(handledEvent === event)
            #expect(nextCount == 0)
        }

        @Test
        func neighborIDStopsAtBothEndsWithoutWrapping() {
            let ids = [UUID.v7(), UUID.v7(), UUID.v7()]

            #expect(ScreenshotOverlayNavigation.neighborID(in: ids, from: ids[1], offset: -1) == ids[0])
            #expect(ScreenshotOverlayNavigation.neighborID(in: ids, from: ids[1], offset: 1) == ids[2])
            #expect(ScreenshotOverlayNavigation.neighborID(in: ids, from: ids[0], offset: -1) == nil)
            #expect(ScreenshotOverlayNavigation.neighborID(in: ids, from: ids[2], offset: 1) == nil)
        }

        @Test
        func neighborIDReturnsNilForSingleEntryOrUnlistedCurrentID() {
            let single = UUID.v7()

            #expect(ScreenshotOverlayNavigation.neighborID(in: [single], from: single, offset: 1) == nil)
            #expect(ScreenshotOverlayNavigation.neighborID(in: [single], from: single, offset: -1) == nil)
            // 拡大表示中に対象が削除された場合。
            #expect(ScreenshotOverlayNavigation.neighborID(in: [single], from: .v7(), offset: 1) == nil)
            #expect(ScreenshotOverlayNavigation.neighborID(in: [], from: single, offset: 1) == nil)
        }

        @Test
        func eventInAnotherWindowIsForwardedWithoutDismissal() throws {
            let fixture = try makeMouseFixture(
                eventType: .leftMouseDown,
                eventLocation: CGPoint(x: 150, y: 150)
            )
            let otherWindow = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 200, height: 200),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            let event = try #require(NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: CGPoint(x: 150, y: 150),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: otherWindow.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 0
            ))
            var dismissCount = 0
            let coordinator = ScreenshotOverlayInputMonitor.Coordinator {
                dismissCount += 1
            }

            let handledEvent = coordinator.handle(event, in: fixture.view)

            #expect(handledEvent === event)
            #expect(dismissCount == 0)
        }

        private func makeMouseFixture(
            eventType: NSEvent.EventType,
            eventLocation: CGPoint
        ) throws -> (event: NSEvent, view: NSView) {
            let window = makeWindow()
            let view = makeView(in: window)
            let event = try #require(NSEvent.mouseEvent(
                with: eventType,
                location: eventLocation,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 0
            ))
            return (event, view)
        }

        private func makeKeyFixture(keyCode: UInt16) throws -> (event: NSEvent, view: NSView) {
            let window = makeWindow()
            let view = makeView(in: window)
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: keyCode
            ))
            return (event, view)
        }

        private func makeWindow() -> NSWindow {
            NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 200, height: 200),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
        }

        private func makeView(in window: NSWindow) -> NSView {
            let view = NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
            window.contentView?.addSubview(view)
            return view
        }

        private func waitUntil(_ predicate: @MainActor () -> Bool) async {
            if await pollUntil({ predicate() }) { return }
            Issue.record("Timed out waiting for MainActor state")
        }
    }
#endif
