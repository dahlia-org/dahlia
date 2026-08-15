#if canImport(Testing)
    import AppKit
    import Testing
    @testable import Dahlia

    @MainActor
    struct SplitViewTrailingWidthSyncTests {
        @Test
        func reportsTrailingPaneResize() async {
            let reportedWidths = ReportedWidths()
            let coordinator = SplitViewWidthSyncView.Coordinator(
                width: 380,
                pane: .last,
                resizeDelay: .zero,
                onWidthChange: { reportedWidths.values.append($0) }
            )
            let splitView = NSSplitView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            splitView.isVertical = true
            let detail = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 600))
            let sidebar = NSView(frame: NSRect(x: 420, y: 0, width: 380, height: 600))
            let markerView = NSView()
            sidebar.addSubview(markerView)
            splitView.addArrangedSubview(detail)
            splitView.addArrangedSubview(sidebar)
            coordinator.attach(to: splitView, markerView: markerView)
            reportedWidths.values.removeAll()

            sidebar.frame.size.width = 500
            NotificationCenter.default.post(
                name: NSSplitView.didResizeSubviewsNotification,
                object: splitView
            )
            let didReportWidth = await pollUntil { reportedWidths.values == [500] }

            #expect(didReportWidth)
            coordinator.detach()
        }

        private final class ReportedWidths {
            var values: [CGFloat] = []
        }
    }
#endif
