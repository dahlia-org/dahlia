#if canImport(Testing)
    import AppKit
    import SwiftUI
    import Testing
    @testable import Dahlia

    @MainActor
    struct DahliaSimpleWindowStyleTests {
        private final class ProbeCapture {
            weak var view: NSView?
        }

        private struct LayoutProbe: NSViewRepresentable {
            let capture: ProbeCapture

            func makeNSView(context _: Context) -> NSView {
                let view = NSView()
                capture.view = view
                return view
            }

            func updateNSView(_: NSView, context _: Context) {}
        }

        private func distanceFromWindowTop(
            for content: some View,
            capture: ProbeCapture
        ) throws -> CGFloat {
            let hostingView = NSHostingView(rootView: content)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.contentView = hostingView
            DahliaSimpleWindowStyle.apply(to: window)
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil) }
            window.layoutIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
            hostingView.layoutSubtreeIfNeeded()

            let contentView = try #require(window.contentView)
            let probeView = try #require(capture.view)
            let probeFrame = probeView.convert(probeView.bounds, to: contentView)
            if contentView.isFlipped {
                return probeFrame.minY - contentView.bounds.minY
            }
            return contentView.bounds.maxY - probeFrame.maxY
        }

        private func verticalCenterDistancesFromWindowTop(
            for content: some View,
            capture: ProbeCapture
        ) throws -> (header: CGFloat, windowControls: CGFloat) {
            let hostingView = NSHostingView(rootView: content)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.contentView = hostingView
            DahliaSimpleWindowStyle.apply(to: window)
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil) }
            window.layoutIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
            hostingView.layoutSubtreeIfNeeded()

            let contentView = try #require(window.contentView)
            let headerView = try #require(capture.view)
            let closeButton = try #require(window.standardWindowButton(.closeButton))
            return (
                verticalCenterDistanceFromWindowTop(of: headerView, in: contentView),
                verticalCenterDistanceFromWindowTop(of: closeButton, in: contentView)
            )
        }

        private func verticalCenterDistanceFromWindowTop(of view: NSView, in contentView: NSView) -> CGFloat {
            let frame = view.convert(view.bounds, to: contentView)
            if contentView.isFlipped {
                return frame.midY - contentView.bounds.minY
            }
            return contentView.bounds.maxY - frame.midY
        }

        @Test
        func preservesStandardWindowControlsWhileRemovingToolbarChrome() {
            let hostingController = NSHostingController(rootView: EmptyView())
            let attachmentView = DahliaSimpleWindowStyle.AttachmentView()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.contentViewController = hostingController
            hostingController.view.addSubview(attachmentView)
            window.toolbar = NSToolbar(identifier: "test-toolbar")

            attachmentView.configureWindow()

            #expect(window.toolbar == nil)
            #expect(window.styleMask.contains(.fullSizeContentView))
            #expect(window.titleVisibility == .hidden)
            #expect(window.titlebarAppearsTransparent)
            #expect(window.titlebarSeparatorStyle == .none)
            #expect(window.standardWindowButton(.closeButton) != nil)
            #expect(window.standardWindowButton(.miniaturizeButton) != nil)
            #expect(window.standardWindowButton(.zoomButton) != nil)

            attachmentView.configureWindow()

            #expect(window.titleVisibility == .hidden)
        }

        @Test
        func styledContentExtendsThroughTheTitlebarSafeArea() throws {
            let unstyledCapture = ProbeCapture()
            let unstyledDistance = try distanceFromWindowTop(
                for: VStack(spacing: 0) {
                    LayoutProbe(capture: unstyledCapture)
                        .frame(height: DahliaDesign.windowHeaderHeight)
                    Spacer()
                },
                capture: unstyledCapture
            )
            let styledCapture = ProbeCapture()
            let styledDistance = try distanceFromWindowTop(
                for: VStack(spacing: 0) {
                    LayoutProbe(capture: styledCapture)
                        .frame(height: DahliaDesign.windowHeaderHeight)
                    Spacer()
                }
                .dahliaSimpleWindowStyle(),
                capture: styledCapture
            )

            #expect(abs((unstyledDistance - styledDistance) - DahliaDesign.windowHeaderHeight) < 0.5)
        }

        @Test
        func splitViewHeaderAlignsWithWindowControls() throws {
            let capture = ProbeCapture()
            let distances = try verticalCenterDistancesFromWindowTop(
                for: HSplitView {
                    Color.clear
                        .overlay(alignment: .top) {
                            DahliaWindowHeader {
                                LayoutProbe(capture: capture)
                                    .frame(width: 1)
                                    .frame(maxHeight: .infinity)
                            }
                        }
                    Color.clear
                }
                .dahliaSimpleWindowStyle(),
                capture: capture
            )

            #expect(abs(distances.header - distances.windowControls) < 0.5)
        }

        @Test
        func splitViewContentStartsBelowWindowHeader() throws {
            let capture = ProbeCapture()
            let distance = try distanceFromWindowTop(
                for: HSplitView {
                    VStack(spacing: 0) {
                        LayoutProbe(capture: capture)
                            .frame(height: 1)
                        Spacer()
                    }
                    Color.clear
                }
                .dahliaSimpleWindowStyle(),
                capture: capture
            )

            #expect(abs(distance - DahliaDesign.windowHeaderHeight) < 0.5)
        }

        @Test
        func projectSplitViewPanesStartBelowWindowHeader() throws {
            for probesDetailPane in [false, true] {
                let capture = ProbeCapture()
                let distance = try distanceFromWindowTop(
                    for: HSplitView {
                        HSplitView {
                            VStack(spacing: 0) {
                                if !probesDetailPane {
                                    LayoutProbe(capture: capture)
                                        .frame(height: 1)
                                }
                                Spacer()
                            }
                            VStack(spacing: 0) {
                                if probesDetailPane {
                                    LayoutProbe(capture: capture)
                                        .frame(height: 1)
                                }
                                Spacer()
                            }
                        }
                        Color.clear
                    }
                    .dahliaSimpleWindowStyle(),
                    capture: capture
                )

                #expect(abs(distance - DahliaDesign.windowHeaderHeight) < 0.5)
            }
        }
    }
#endif
