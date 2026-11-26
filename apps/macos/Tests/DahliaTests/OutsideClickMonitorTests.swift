#if canImport(Testing)
    import AppKit
    import Testing
    @testable import Dahlia

    @MainActor
    struct OutsideClickMonitorTests {
        final class FocusOnlyTextView: NSTextView {
            override func mouseDown(with _: NSEvent) {
                // Avoid AppKit's nested event-tracking loop in the test runner.
                window?.makeFirstResponder(self)
            }
        }

        @Test
        func textInputClickDismissesAndKeepsFocus() async throws {
            let fixture = try makeFixture(eventLocation: CGPoint(x: 150, y: 150), eventType: .leftMouseDown)
            let textView = FocusOnlyTextView(frame: CGRect(x: 100, y: 100, width: 100, height: 100))
            textView.string = "Draft"
            fixture.window.contentView?.addSubview(textView)
            fixture.window.isReleasedWhenClosed = false
            defer { fixture.window.close() }
            fixture.window.makeKeyAndOrderFront(nil)
            var dismissCount = 0
            let coordinator = OutsideClickMonitor.Coordinator {
                dismissCount += 1
            }
            coordinator.startMonitoring(view: fixture.view)
            defer { coordinator.stopMonitoring() }

            NSApplication.shared.sendEvent(fixture.event)

            #expect(await pollUntil(timeout: .seconds(1)) { dismissCount == 1 })
            #expect(fixture.window.firstResponder === textView)
        }

        @Test
        func clickInsidePanelIsForwardedWithoutDismissal() async throws {
            let fixture = try makeFixture(eventLocation: CGPoint(x: 50, y: 50))
            var dismissCount = 0
            let coordinator = OutsideClickMonitor.Coordinator {
                dismissCount += 1
            }

            let handledEvent = coordinator.handle(fixture.event, in: fixture.view)

            #expect(handledEvent === fixture.event)
            #expect(!(await pollUntil(timeout: .milliseconds(100)) { dismissCount > 0 }))
            #expect(dismissCount == 0)
        }

        @Test
        func clickOutsidePanelIsForwardedAndDismisses() async throws {
            let fixture = try makeFixture(eventLocation: CGPoint(x: 150, y: 150))
            var dismissCount = 0
            let coordinator = OutsideClickMonitor.Coordinator {
                dismissCount += 1
            }

            let handledEvent = coordinator.handle(fixture.event, in: fixture.view)

            #expect(dismissCount == 0)
            #expect(await pollUntil { dismissCount == 1 })

            #expect(handledEvent === fixture.event)
            #expect(dismissCount == 1)
        }

        @Test
        func clickInAnotherWindowIsForwardedWithoutDismissal() async throws {
            let fixture = try makeFixture(eventLocation: CGPoint(x: 150, y: 150))
            let otherWindow = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 200, height: 200),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            let otherEvent = try #require(NSEvent.mouseEvent(
                with: .leftMouseUp,
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
            let coordinator = OutsideClickMonitor.Coordinator {
                dismissCount += 1
            }

            let handledEvent = coordinator.handle(otherEvent, in: fixture.view)

            #expect(handledEvent === otherEvent)
            #expect(!(await pollUntil(timeout: .milliseconds(100)) { dismissCount > 0 }))
            #expect(dismissCount == 0)
        }

        private func makeFixture(
            eventLocation: CGPoint,
            eventType: NSEvent.EventType = .leftMouseUp
        ) throws -> (event: NSEvent, view: NSView, window: NSWindow) {
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 200, height: 200),
                styleMask: .titled,
                backing: .buffered,
                defer: false
            )
            let view = NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
            window.contentView?.addSubview(view)
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
            return (event, view, window)
        }
    }
#endif
