#if canImport(Testing)
    import AppKit
    import Observation
    import SwiftUI
    import Testing
    @testable import Dahlia

    @MainActor
    struct ControlPanelViewTests {
        @Test
        func preservesSelectedTabWhenDetailViewIsRecreatedForAnotherMeeting() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let viewModel = CaptionViewModel()
            let sidebarViewModel = SidebarViewModel(settings: AppSettings())
            let navigation = MainWindowNavigation(openMainWindow: {}, openMainWindowWithoutActivation: {})
            let recordingCoordinator = RecordingCoordinator(
                viewModel: viewModel,
                sidebarViewModel: sidebarViewModel,
                mainWindowNavigation: navigation,
                onRecordingDidStart: {},
                onRecordingDidStop: {}
            )
            let state = ControlPanelViewFixtureState()
            viewModel.beginDraftMeeting(
                dbQueue: database.dbQueue,
                vaultURL: FileManager.default.temporaryDirectory
            )
            let hostingView = NSHostingView(rootView: ControlPanelViewFixture(
                state: state,
                viewModel: viewModel,
                sidebarViewModel: sidebarViewModel,
                recordingCoordinator: recordingCoordinator
            ).environment(navigation))
            hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
            hostingView.layoutSubtreeIfNeeded()
            #expect(await pollUntil { state.detailAppearanceCount == 1 })

            state.showsControlPanel = false
            #expect(await pollUntil { state.didShowLoadingPlaceholder })

            viewModel.clearCurrentMeeting()
            viewModel.beginDraftMeeting(
                dbQueue: database.dbQueue,
                vaultURL: FileManager.default.temporaryDirectory
            )
            state.showsControlPanel = true

            #expect(await pollUntil { state.detailAppearanceCount == 2 })
            #expect(state.selectedTab == .notes)
        }
    }

    @MainActor
    @Observable
    private final class ControlPanelViewFixtureState {
        var selectedTab: DetailTab = .notes
        var expandedScreenshot: ExpandedScreenshotPresentation?
        var showsControlPanel = true
        var didShowLoadingPlaceholder = false
        var detailAppearanceCount = 0
    }

    private struct ControlPanelViewFixture: View {
        @Bindable var state: ControlPanelViewFixtureState
        @ObservedObject var viewModel: CaptionViewModel
        let sidebarViewModel: SidebarViewModel
        let recordingCoordinator: RecordingCoordinator

        var body: some View {
            if state.showsControlPanel {
                ControlPanelView(
                    viewModel: viewModel,
                    sidebarViewModel: sidebarViewModel,
                    recordingCoordinator: recordingCoordinator,
                    selectedTab: $state.selectedTab,
                    expandedScreenshot: $state.expandedScreenshot
                )
                .onAppear {
                    state.detailAppearanceCount += 1
                }
            } else {
                ProgressView()
                    .onAppear {
                        state.didShowLoadingPlaceholder = true
                    }
            }
        }
    }
#endif
