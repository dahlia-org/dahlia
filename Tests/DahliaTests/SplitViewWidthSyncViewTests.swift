#if canImport(Testing)
import AppKit
import Testing
@testable import Dahlia

@MainActor
struct SplitViewWidthSyncViewTests {
    @Test
    func ignoresDetailWidthAfterTrackedSidebarIsRemoved() {
        let fixture = makeFixture()
        defer { fixture.coordinator.detach() }

        fixture.sidebar.removeFromSuperview()
        fixture.detail.frame.size.width = 800
        NotificationCenter.default.post(
            name: NSSplitView.didResizeSubviewsNotification,
            object: fixture.splitView
        )

        #expect(fixture.reportedWidths.values.isEmpty)
    }

    @Test
    func dismantlingStopsResizeCallbacks() {
        let fixture = makeFixture()

        SplitViewWidthSyncView.dismantleNSView(
            fixture.markerView,
            coordinator: fixture.coordinator
        )
        fixture.sidebar.frame.size.width = 360
        NotificationCenter.default.post(
            name: NSSplitView.didResizeSubviewsNotification,
            object: fixture.splitView
        )

        #expect(fixture.reportedWidths.values.isEmpty)
    }

    private func makeFixture() -> Fixture {
        let reportedWidths = ReportedWidths()
        let coordinator = SplitViewWidthSyncView.Coordinator(width: 275) {
            reportedWidths.values.append($0)
        }
        let splitView = NSSplitView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        splitView.isVertical = true
        let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: 275, height: 600))
        let detail = NSView(frame: NSRect(x: 275, y: 0, width: 525, height: 600))
        let markerView = NSView()
        sidebar.addSubview(markerView)
        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(detail)
        coordinator.attach(to: splitView, markerView: markerView)
        reportedWidths.values.removeAll()
        return Fixture(
            coordinator: coordinator,
            splitView: splitView,
            sidebar: sidebar,
            detail: detail,
            markerView: markerView,
            reportedWidths: reportedWidths
        )
    }
}

private extension SplitViewWidthSyncViewTests {
    final class ReportedWidths {
        var values: [CGFloat] = []
    }

    struct Fixture {
        let coordinator: SplitViewWidthSyncView.Coordinator
        let splitView: NSSplitView
        let sidebar: NSView
        let detail: NSView
        let markerView: NSView
        let reportedWidths: ReportedWidths
    }
}
#endif
