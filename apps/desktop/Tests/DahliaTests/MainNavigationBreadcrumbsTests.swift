import AppKit
import DahliaRuntimeSupport
import SwiftUI
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct MainNavigationBreadcrumbsTests {
        @Test
        func hoverPopoverDoesNotConsumeParentClicksAndReleasesClosedContent() {
            let coordinator = BreadcrumbPopover<Text>.Coordinator()
            #expect(coordinator.popover.behavior == .applicationDefined)
            #expect(coordinator.popover.contentViewController == nil)
            let anchor = NSView()
            coordinator.update(isPresented: true, content: Text("Project"), anchor: anchor, arrowEdge: .trailing)
            #expect(coordinator.popover.contentViewController is NSHostingController<Text>)
            #expect(!coordinator.popover.isShown)
            coordinator.update(isPresented: false, content: Text("Project"), anchor: anchor, arrowEdge: .trailing)
            #expect(coordinator.popover.contentViewController == nil)
        }

        @Test
        func projectPathUsesParentsAndStopsAtMissingOrCyclicLinks() {
            let root = project(name: "Root")
            let child = project(name: "Child", parentID: root.id)
            var projects = [root.id: root, child.id: child]
            #expect(MainNavigationBreadcrumbs.projectPath(projectID: child.id, projects: projects).map(\.id) == [root.id, child.id])
            #expect(MainNavigationBreadcrumbs.projectPath(projectID: nil, projects: projects).isEmpty)
            #expect(MainNavigationBreadcrumbs.projectPath(projectID: UUID(), projects: projects).isEmpty)

            projects.removeValue(forKey: root.id)
            #expect(MainNavigationBreadcrumbs.projectPath(projectID: child.id, projects: projects).map(\.id) == [child.id])
            var cyclicRoot = root
            cyclicRoot.parentProjectId = child.id
            projects[root.id] = cyclicRoot
            #expect(MainNavigationBreadcrumbs.projectPath(projectID: child.id, projects: projects).map(\.id) == [root.id, child.id])
        }

        @Test(arguments: [500.0, 1000.0], [false, true])
        func longBreadcrumbsKeepHeaderSizeAcrossSyncStates(width: Double, reservesChatControl: Bool) throws {
            let root = project(name: "01_PCA")
            let child = project(name: "IPF", parentID: root.id)
            let projects = [root.id: root, child.id: child]
            let workspace = WorkspaceRecord(id: UUID(), name: "Test", createdAt: .now, lastOpenedAt: .now)
            for state: MeetingSyncState? in [nil, .local, .pending, .synced, .blocked(.conflict)] {
                let textContentState: TextContentAvailability.State? = switch state {
                case .pending: .loading
                case .blocked(.conflict): .failed
                default: nil
                }
                let header = MainDetailHeader(
                    reservesChatControl: reservesChatControl,
                    leadingInset: 0,
                    syncState: state,
                    textContentState: textContentState,
                    retryTextContent: {}
                ) {
                    MainNavigationBreadcrumbs(
                        workspace: workspace,
                        workspaces: [workspace],
                        projects: projects,
                        projectID: child.id,
                        meetingTitle: String(repeating: "全体プロジェクト会議・設計のリカバリープラン", count: 10),
                        dbQueue: nil,
                        onOpenMeeting: { _ in },
                        appearanceForProject: { _ in .workspaceDefault },
                        onSelectWorkspace: { _ in },
                        onShowProjects: {},
                        onOpenProject: { _ in }
                    )
                }
                .frame(width: width)
                let image = try #require(ImageRenderer(content: header).nsImage)
                #expect(image.size == CGSize(width: width, height: DahliaDesign.windowHeaderHeight))
            }
        }

        @Test
        func nestedHoverKeepsAncestorsOpenAndClearsOnExit() {
            let session = BreadcrumbHoverSession()
            let parentID = UUID()
            let childID = UUID()
            let siblingID = UUID()
            session.update(id: parentID, ancestors: [], isHovered: true)
            #expect(session.isHovered(id: parentID))
            session.update(id: childID, ancestors: [parentID], isHovered: true)
            session.update(id: parentID, ancestors: [], isHovered: false)
            #expect(session.isHovered(id: parentID))
            #expect(session.isHovered(id: childID))
            #expect(!session.isHovered(id: siblingID))
            session.update(id: childID, ancestors: [parentID], isHovered: false)
            #expect(!session.isHovered(id: parentID))
            #expect(!session.isHovered(id: childID))
        }

        @Test
        func navigationDismissesAllHoverBranches() {
            let session = BreadcrumbHoverSession()
            let parentID = UUID()
            let childID = UUID()
            session.update(id: childID, ancestors: [parentID], isHovered: true)
            session.dismissAll()
            #expect(!session.isHovered(id: parentID))
            #expect(!session.isHovered(id: childID))
            #expect(session.dismissalGeneration == 1)
        }

        private func project(name: String, parentID: UUID? = nil) -> ProjectOverviewItem {
            ProjectOverviewItem(
                projectId: UUID(),
                projectName: name,
                projectDisplayName: name,
                parentProjectId: parentID,
                createdAt: .now,
                meetingCount: 0
            )
        }
    }
#endif
