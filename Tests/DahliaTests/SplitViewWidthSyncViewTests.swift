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

            #expect(fixture.state.reportedWidths.isEmpty)
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

            #expect(fixture.state.reportedWidths.isEmpty)
        }

        @Test
        func detachingCancelsDebouncedResizeCallback() async {
            let fixture = makeFixture(
                resizeDelay: .milliseconds(20),
                onResizeTaskCompletion: { fixtureState in
                    fixtureState.completedResizeTaskCount += 1
                }
            )

            fixture.sidebar.frame.size.width = 360
            NotificationCenter.default.post(
                name: NSSplitView.didResizeSubviewsNotification,
                object: fixture.splitView
            )
            fixture.coordinator.detach()

            let didCompleteResizeTask = await pollUntil {
                fixture.state.completedResizeTaskCount == 1
            }

            #expect(didCompleteResizeTask)
            #expect(fixture.state.reportedWidths.isEmpty)
        }

        @Test
        func pendingResizeIsNotRevertedByStaleStateUpdate() async {
            let fixture = makeFixture()
            defer { fixture.coordinator.detach() }

            fixture.sidebar.frame.size.width = 360
            NotificationCenter.default.post(
                name: NSSplitView.didResizeSubviewsNotification,
                object: fixture.splitView
            )
            fixture.coordinator.update(width: 275, onWidthChange: { width in
                fixture.state.reportedWidths.append(width)
            })

            #expect(abs(fixture.sidebar.frame.width - 360) < 0.5)
            let didReportWidth = await pollUntil {
                fixture.state.reportedWidths.count == 1
            }
            #expect(didReportWidth)
            #expect(abs((fixture.state.reportedWidths.first ?? 0) - 360) < 0.5)
        }

        @Test
        func externalWidthChangeCancelsPendingResize() async {
            let fixture = makeFixture(
                resizeDelay: .milliseconds(20),
                onResizeTaskCompletion: { fixtureState in
                    fixtureState.completedResizeTaskCount += 1
                }
            )
            defer { fixture.coordinator.detach() }

            fixture.sidebar.frame.size.width = 360
            NotificationCenter.default.post(
                name: NSSplitView.didResizeSubviewsNotification,
                object: fixture.splitView
            )
            fixture.coordinator.update(width: 420, onWidthChange: { width in
                fixture.state.reportedWidths.append(width)
            })

            #expect(abs(fixture.sidebar.frame.width - 420) < 0.5)
            let didCompleteResizeTask = await pollUntil {
                fixture.state.completedResizeTaskCount == 1
            }
            #expect(didCompleteResizeTask)
            #expect(fixture.state.reportedWidths.isEmpty)
        }

        @Test
        func widthSourceChangeCancelsPendingResize() async {
            let fixture = makeFixture(
                resizeDelay: .milliseconds(20),
                onResizeTaskCompletion: { fixtureState in
                    fixtureState.completedResizeTaskCount += 1
                }
            )
            defer { fixture.coordinator.detach() }

            fixture.sidebar.frame.size.width = 360
            NotificationCenter.default.post(
                name: NSSplitView.didResizeSubviewsNotification,
                object: fixture.splitView
            )
            fixture.coordinator.update(
                width: 275,
                widthSourceID: 1,
                onWidthChange: { width in
                    fixture.state.reportedWidths.append(width)
                }
            )

            #expect(abs(fixture.sidebar.frame.width - 275) < 0.5)
            let didCompleteResizeTask = await pollUntil {
                fixture.state.completedResizeTaskCount == 1
            }
            #expect(didCompleteResizeTask)
            #expect(fixture.state.reportedWidths.isEmpty)
        }

        @Test
        func attachmentChangeConnectsCoordinatorAfterMarkerIsMounted() async {
            let state = FixtureState()
            let coordinator = SplitViewWidthSyncView.Coordinator(
                width: 360,
                resizeDelay: .zero,
                onWidthChange: { state.reportedWidths.append($0) }
            )
            defer { coordinator.detach() }

            let splitView = NSSplitView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            splitView.isVertical = true
            let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
            let detail = NSView(frame: NSRect(x: 240, y: 0, width: 560, height: 600))
            splitView.addArrangedSubview(sidebar)
            splitView.addArrangedSubview(detail)

            let markerView = SplitViewAttachmentTrackingView()
            var attachmentCount = 0
            markerView.onAttachmentChange = { markerView in
                attachmentCount += 1
                coordinator.attach(to: splitView, markerView: markerView)
            }
            sidebar.addSubview(markerView)
            let didAttach = await pollUntil { attachmentCount == 1 }

            #expect(didAttach)
            #expect(abs(sidebar.frame.width - 360) < 0.5)
        }

        @Test
        func attachmentUpdateCanBeDeferredUntilAnAnimationCompletes() async {
            let markerView = SplitViewAttachmentTrackingView()
            var attachmentCount = 0
            markerView.attachmentDelay = .milliseconds(20)
            markerView.onAttachmentChange = { _ in
                attachmentCount += 1
            }

            markerView.scheduleAttachmentUpdate()

            #expect(attachmentCount == 0)
            let didAttach = await pollUntil { attachmentCount == 1 }
            #expect(didAttach)
            #expect(markerView.attachmentDelay == .zero)
        }

        private func makeFixture(resizeDelay: Duration = .zero) -> Fixture {
            makeFixture(resizeDelay: resizeDelay, onResizeTaskCompletion: nil)
        }

        private func makeFixture(
            resizeDelay: Duration,
            onResizeTaskCompletion: ((FixtureState) -> Void)?
        ) -> Fixture {
            let state = FixtureState()
            let coordinator = SplitViewWidthSyncView.Coordinator(
                width: 275,
                resizeDelay: resizeDelay,
                onResizeTaskCompletion: {
                    onResizeTaskCompletion?(state)
                },
                onWidthChange: { state.reportedWidths.append($0) }
            )
            let splitView = NSSplitView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            splitView.isVertical = true
            let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: 275, height: 600))
            let detail = NSView(frame: NSRect(x: 275, y: 0, width: 525, height: 600))
            let markerView = SplitViewAttachmentTrackingView()
            sidebar.addSubview(markerView)
            splitView.addArrangedSubview(sidebar)
            splitView.addArrangedSubview(detail)
            coordinator.attach(to: splitView, markerView: markerView)
            state.reportedWidths.removeAll()
            return Fixture(
                coordinator: coordinator,
                splitView: splitView,
                sidebar: sidebar,
                detail: detail,
                markerView: markerView,
                state: state
            )
        }
    }

    private extension SplitViewWidthSyncViewTests {
        final class FixtureState {
            var reportedWidths: [CGFloat] = []
            var completedResizeTaskCount = 0
        }

        struct Fixture {
            let coordinator: SplitViewWidthSyncView.Coordinator
            let splitView: NSSplitView
            let sidebar: NSView
            let detail: NSView
            let markerView: SplitViewAttachmentTrackingView
            let state: FixtureState
        }
    }
#endif
