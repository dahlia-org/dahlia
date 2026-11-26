#if canImport(Testing)
    import AppKit
    import Testing
    @testable import Dahlia

    @MainActor
    struct ChatRowHoverTests {
        @Test func containmentUsesTheRowsWindowRatherThanAnotherWindowsCoordinates() {
            let host = window(origin: NSPoint(x: 100, y: 100))
            let detached = window(origin: NSPoint(x: 600, y: 100))
            defer {
                host.close()
                detached.close()
            }
            let row = ChatRowHoverView(frame: NSRect(x: 20, y: 20, width: 100, height: 28))
            host.contentView?.addSubview(row)
            defer { row.invalidate() }

            #expect(row.containsPointer(at: host.convertPoint(toScreen: NSPoint(x: 40, y: 30))))
            #expect(!row.containsPointer(at: detached.convertPoint(toScreen: NSPoint(x: 40, y: 30))))
            row.updateTrackingAreas()
            #expect(row.trackingAreas.first?.rect == row.bounds.intersection(row.visibleRect))
            #expect(row.hitTest(NSPoint(x: 10, y: 10)) == nil)
        }

        @Test func stationaryPointerUsesCurrentGeometryAndDetachedRowsAreNotHovered() {
            let host = window(origin: NSPoint(x: 100, y: 100))
            defer { host.close() }
            let row = ChatRowHoverView(frame: NSRect(x: 20, y: 60, width: 100, height: 28))
            host.contentView?.addSubview(row)
            defer { row.invalidate() }
            let pointer = host.convertPoint(toScreen: NSPoint(x: 40, y: 30))

            #expect(!row.containsPointer(at: pointer))
            row.setFrameOrigin(NSPoint(x: 20, y: 20))
            #expect(row.containsPointer(at: pointer))
            row.isHidden = true
            #expect(!row.containsPointer(at: pointer))
            row.isHidden = false
            row.removeFromSuperview()
            #expect(!row.containsPointer(at: pointer))
        }

        private func window(origin: NSPoint) -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(origin: origin, size: NSSize(width: 300, height: 300)),
                styleMask: .borderless, backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            return window
        }
    }
#endif
