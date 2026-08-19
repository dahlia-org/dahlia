import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct ProjectDescriptionEditingStateTests {
        @Test
        func restoredDraftKeepsPersistedDescriptionAndBaseRevision() {
            let state = ProjectDescriptionEditingState(
                persistedText: "Saved description",
                draftText: "Unsaved description",
                persistedRevision: 2,
                draftRevision: 1
            )

            #expect(state.text == "Unsaved description")
            #expect(state.persistedText == "Saved description")
            #expect(state.expectedRevision == 1)
        }

        @Test
        func restoredDraftKeepsItsBaseRevisionAfterExternalUpdate() {
            let viewModel = SidebarViewModel()
            let projectId = UUID.v7()
            viewModel.stageProjectDescriptionDraft(
                id: projectId,
                description: "Unsaved description",
                baseRevision: 1
            )

            let state = ProjectDescriptionEditingState(
                persistedText: "Externally updated description",
                draftText: viewModel.projectDescriptionDraft(id: projectId),
                persistedRevision: 2,
                draftRevision: viewModel.projectDescriptionDraftBaseRevision(id: projectId)
            )

            #expect(state.text == "Unsaved description")
            #expect(state.persistedText == "Externally updated description")
            #expect(state.expectedRevision == 1)

            let request = ProjectEditorRequest.edit(
                ProjectOverviewItem(
                    projectId: projectId,
                    projectName: "Project",
                    revision: 2,
                    createdAt: .now,
                    meetingCount: 0,
                    latestMeetingDate: nil
                ),
                initialDescription: state.text,
                expectedRevision: state.expectedRevision
            )
            #expect(request.expectedRevision == 1)
        }

        @Test
        func stagingDescriptionDraftDoesNotPersistIt() throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: database.dbQueue)
            let vault = VaultRecord(
                id: .v7(),
                path: "/tmp/test-vault",
                name: "Test Vault",
                createdAt: Date(),
                lastOpenedAt: Date()
            )
            try repository.insertVault(vault)
            let project = try repository.fetchOrCreateProject(name: "Project A", vaultId: vault.id)
            let viewModel = SidebarViewModel()
            viewModel.setAppDatabase(database)

            viewModel.stageProjectDescriptionDraft(id: project.id, description: "Unsaved description")

            #expect(viewModel.projectDescriptionDraft(id: project.id) == "Unsaved description")
            #expect(viewModel.projectDescription(id: project.id)?.isEmpty == true)
        }

        @Test
        func clearingDescriptionDraftRemovesStagedDraft() {
            let viewModel = SidebarViewModel()
            let projectId = UUID.v7()
            viewModel.stageProjectDescriptionDraft(id: projectId, description: "Unsaved description")

            viewModel.clearProjectDescriptionDraft(id: projectId)

            #expect(viewModel.projectDescriptionDraft(id: projectId) == nil)
        }

        @Test
        func clearingRevertedModalDraftRestoresPersistedDescription() {
            let viewModel = SidebarViewModel()
            let projectId = UUID.v7()
            viewModel.stageProjectDescriptionDraft(
                id: projectId,
                description: "Unsaved description",
                baseRevision: 1
            )

            viewModel.clearProjectDescriptionDraft(id: projectId)
            let state = ProjectDescriptionEditingState(
                persistedText: "Saved description",
                draftText: viewModel.projectDescriptionDraft(id: projectId),
                persistedRevision: 1,
                draftRevision: viewModel.projectDescriptionDraftBaseRevision(id: projectId)
            )

            #expect(state.text == "Saved description")
            #expect(state.expectedRevision == 1)
        }

        @Test
        func missingProjectDoesNotRemainAFailedDraft() throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let viewModel = SidebarViewModel()
            let deletedProjectId = UUID.v7()
            viewModel.setAppDatabase(database)
            viewModel.stageProjectDescriptionDraft(id: deletedProjectId, description: "Unsaved description")

            let result = viewModel.updateProjectDescription(
                id: deletedProjectId,
                description: "Unsaved description"
            )

            #expect(result == .projectNotFound)
            #expect(viewModel.projectDescriptionDraft(id: deletedProjectId) == nil)
        }

        @Test
        func localProjectRevisionObservationIsNotReportedAsExternal() {
            let projectId = UUID.v7()
            var tracker = ProjectRevisionObservationTracker()

            tracker.record(projectId: projectId, revision: 2)
            let consumedLocalRevision = tracker.consume(projectId: projectId, revision: 2)
            let consumedUnknownRevision = tracker.consume(projectId: projectId, revision: 3)

            #expect(consumedLocalRevision)
            #expect(!consumedUnknownRevision)
        }

        @Test
        func coalescedLocalProjectRevisionObservationsAreConsumed() {
            let projectId = UUID.v7()
            var tracker = ProjectRevisionObservationTracker()

            tracker.record(projectId: projectId, revision: 2)
            tracker.record(projectId: projectId, revision: 3)
            let consumedLatestRevision = tracker.consume(projectId: projectId, revision: 3)
            let consumedSupersededRevision = tracker.consume(projectId: projectId, revision: 2)

            #expect(consumedLatestRevision)
            #expect(!consumedSupersededRevision)
        }
    }
#endif
