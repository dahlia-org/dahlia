#if canImport(Testing)
import AppKit
import Testing
@testable import Dahlia

@MainActor
struct CodexChatOutsideClickMonitorTests {
    @Test
    func clickInsidePanelIsForwardedWithoutDismissal() async throws {
        let fixture = try makeFixture(eventLocation: CGPoint(x: 50, y: 50))
        var dismissCount = 0
        let coordinator = CodexChatOutsideClickMonitor.Coordinator {
            dismissCount += 1
        }

        let handledEvent = coordinator.handle(fixture.event, in: fixture.view)

        #expect(dismissCount == 0)
        await Task.yield()

        #expect(handledEvent === fixture.event)
        #expect(dismissCount == 0)
    }

    @Test
    func clickOutsidePanelIsForwardedAndDismisses() async throws {
        let fixture = try makeFixture(eventLocation: CGPoint(x: 150, y: 150))
        var dismissCount = 0
        let coordinator = CodexChatOutsideClickMonitor.Coordinator {
            dismissCount += 1
        }

        let handledEvent = coordinator.handle(fixture.event, in: fixture.view)

        #expect(dismissCount == 0)
        await Task.yield()

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
        let coordinator = CodexChatOutsideClickMonitor.Coordinator {
            dismissCount += 1
        }

        let handledEvent = coordinator.handle(otherEvent, in: fixture.view)
        await Task.yield()

        #expect(handledEvent === otherEvent)
        #expect(dismissCount == 0)
    }

    private func makeFixture(eventLocation: CGPoint) throws -> (event: NSEvent, view: NSView, window: NSWindow) {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.contentView?.addSubview(view)
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp,
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
