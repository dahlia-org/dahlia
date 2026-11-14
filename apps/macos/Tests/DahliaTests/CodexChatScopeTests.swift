#if canImport(Testing)
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    struct CodexChatScopeTests {
        @Test
        func savedMembershipWinsOverCurrentContextAndTracksDeletion() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let workspace = WorkspaceRecord(id: .v7(), name: "Workspace", createdAt: .now, lastOpenedAt: .now)
            let savedProject = project(workspaceID: workspace.id, name: "Saved")
            let currentProject = project(workspaceID: workspace.id, name: "Current")
            let thread = thread()
            try await database.dbQueue.write { db in
                try workspace.insert(db)
                try savedProject.insert(db)
                try currentProject.insert(db)
            }
            let store = ChatThreadStore(dbQueue: database.dbQueue)
            try store.createThread(thread, initialContext: .project(id: savedProject.id, name: savedProject.name, description: ""))
            let currentContext = CodexChatContext.project(id: currentProject.id, name: currentProject.name, description: "")
            let snapshot = try await database.dbQueue.read { db in
                try CodexChatScopeSnapshot.fetch(accountID: "local", threadID: thread.id, context: currentContext, in: db)
            }
            #expect(snapshot.projectID == savedProject.id)
            #expect(snapshot.projects.count == 2)

            try await database.dbQueue.write { db in _ = try ProjectRecord.deleteOne(db, key: savedProject.id) }
            let afterDeletion = try await database.dbQueue.read { db in
                try CodexChatScopeSnapshot.fetch(accountID: "local", threadID: thread.id, context: currentContext, in: db)
            }
            #expect(afterDeletion.projectID == nil)
            #expect(afterDeletion.projects.map(\.id) == [currentProject.id])
        }

        @Test
        func draftUsesMeetingProjectAndListsProjectsAcrossTheAccount() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let workspace = WorkspaceRecord(id: .v7(), name: "Workspace", createdAt: .now, lastOpenedAt: .now)
            let otherWorkspace = WorkspaceRecord(id: .v7(), name: "Other", createdAt: .now, lastOpenedAt: .now)
            let selectedProject = project(workspaceID: workspace.id, name: "Selected")
            let otherProject = project(workspaceID: otherWorkspace.id, name: "Other")
            let meetingID = UUID.v7()
            try await database.dbQueue.write { db in
                try workspace.insert(db)
                try otherWorkspace.insert(db)
                try selectedProject.insert(db)
                try otherProject.insert(db)
                try MeetingRecord(
                    id: meetingID, workspaceId: workspace.id, projectId: selectedProject.id,
                    name: "Meeting", status: .ready, createdAt: .now, updatedAt: .now
                ).insert(db)
            }
            let snapshot = try await database.dbQueue.read { db in
                try CodexChatScopeSnapshot.fetch(
                    accountID: "local", threadID: nil,
                    context: .meeting(id: meetingID, name: "Meeting", calendarEvent: nil), in: db
                )
            }
            #expect(snapshot.projectID == selectedProject.id)
            #expect(Set(snapshot.projects.map(\.id)) == [selectedProject.id, otherProject.id])
            let invalid = try await database.dbQueue.read { db in
                try CodexChatScopeSnapshot.fetch(
                    accountID: "local", threadID: nil,
                    context: .project(id: otherProject.id, name: "Other", description: ""), in: db
                )
            }
            #expect(invalid.projectID == otherProject.id)
            let anotherAccount = try await database.dbQueue.read { db in
                try CodexChatScopeSnapshot.fetch(
                    accountID: "another",
                    threadID: nil,
                    context: .project(id: otherProject.id, name: "Other", description: ""),
                    in: db
                )
            }
            #expect(anotherAccount.projects.isEmpty)
            #expect(anotherAccount.projectID == nil)
        }

        @Test(arguments: [false, true])
        func selectionOverridesAutomaticContextAndLocksOnFirstSubmission(includesContext: Bool) async throws {
            let settings = AppSettings()
            let workspace = WorkspaceRecord(id: .v7(), name: "Workspace", createdAt: .now, lastOpenedAt: .now)
            settings.currentWorkspace = workspace
            let selectedProject = project(workspaceID: workspace.id, name: "Selected")
            let contextProvider = TestCodexChatContextProvider(context: .meeting(id: .v7(), name: "Meeting", calendarEvent: nil))
            let service = TestCodexChatService(mode: .blockBeforeOutput)
            let session = CodexChatSessionModel(service: service, settings: settings, contextProvider: contextProvider)
            session.scopeSnapshot = CodexChatScopeSnapshot(projects: [selectedProject], projectID: nil)
            session.selectScopeProject(selectedProject.id)
            #expect(session.scopeProjectID == selectedProject.id)
            #expect(try await session.resolveContext(if: true) == .project(id: selectedProject.id, name: "Selected", description: ""))
            session.selectScopeProject(nil)
            #expect(try await session.resolveContext(if: true) == nil)
            session.selectScopeProject(selectedProject.id)
            session.submit("Question", includesCurrentContext: includesContext)
            #expect(!session.canSelectScope)
            session.selectScopeProject(nil)
            #expect(session.scopeProjectID == selectedProject.id)
            await waitUntil { await !service.initialContexts.isEmpty || !session.hasPendingGenerationWork }
            #expect(session.errorMessage == nil)
            let initialContexts = await service.initialContexts
            let initialContext = try #require(initialContexts.first)
            #expect(initialContext == .project(id: selectedProject.id, name: "Selected", description: ""))
            await waitUntil { session.activeTurnID != nil }
            await service.completeBlockedTurn()
            await waitUntil { !session.hasPendingGenerationWork }
            #expect(!session.canSelectScope)
            session.selectScopeProject(nil)
            #expect(session.selectedScopeProjectID == selectedProject.id)
        }

        @Test
        func commandsKeepTheDisplayedAutomaticProjectWithoutInjectingContext() async throws {
            let settings = AppSettings()
            let workspace = WorkspaceRecord(id: .v7(), name: "Workspace", createdAt: .now, lastOpenedAt: .now)
            settings.currentWorkspace = workspace
            let project = project(workspaceID: workspace.id, name: "Automatic")
            let service = TestCodexChatService(mode: .complete)
            let provider = TestCodexChatContextProvider(error: .invalidProtocolResponse)
            let session = CodexChatSessionModel(service: service, settings: settings, contextProvider: provider)
            session.scopeSnapshot = CodexChatScopeSnapshot(projects: [project], projectID: project.id)
            session.draft = "/mcp"
            session.sendDraft()
            await waitUntil { !session.hasPendingGenerationWork }
            #expect(session.errorMessage == nil)
            let contexts = await service.initialContexts
            let context = try #require(contexts.first)
            #expect(context == .project(id: project.id, name: project.name, description: ""))
            #expect(await service.sentTextBlocks == [["/mcp"]])
            #expect(provider.requestCount == 0)
        }

        @Test(arguments: [false, true])
        func chosenProjectPersistsBeforeFirstMessageAndCannotBeOverwritten(hasProject: Bool) async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let workspace = WorkspaceRecord(id: .v7(), name: "Workspace", createdAt: .now, lastOpenedAt: .now)
            let chosen = project(workspaceID: workspace.id, name: "Chosen")
            let other = project(workspaceID: workspace.id, name: "Other")
            try await database.dbQueue.write { db in
                try workspace.insert(db)
                try chosen.insert(db)
                try other.insert(db)
            }
            let store = ChatThreadStore(dbQueue: database.dbQueue)
            let thread = thread()
            let initialContext: CodexChatContext? = hasProject ? .project(id: chosen.id, name: "Chosen", description: "") : nil
            let expectedProjectID: UUID? = hasProject ? chosen.id : nil
            try store.createThread(thread, initialContext: initialContext)
            #expect(try store.thread(id: thread.id, accountID: "local").projectID == expectedProjectID)
            let message = ChatHistoryCodec.user(CodexChatPromptCodec.encodeTextBlocks(
                text: "Question", context: .project(id: other.id, name: "Other", description: "")
            ).map(CodexAppServerInput.text))
            try store.beginTurn(threadID: thread.id, message: message, model: nil, effort: "low")
            #expect(try store.thread(id: thread.id, accountID: "local").projectID == expectedProjectID)
            try store.beginTurn(threadID: thread.id, message: message, model: nil, effort: "low")
            #expect(try store.thread(id: thread.id, accountID: "local").projectID == expectedProjectID)
        }

        private func project(workspaceID: UUID, name: String) -> ProjectRecord {
            ProjectRecord(id: .v7(), workspaceId: workspaceID, parentProjectId: nil, name: name, createdAt: .now, projectType: .undefined)
        }

        private func thread() -> ChatThreadRecord {
            ChatThreadRecord(
                id: UUID.v7().uuidString,
                accountID: "local",
                title: "Thread",
                createdAt: .now,
                updatedAt: .now
            )
        }

        private func waitUntil(_ condition: () async -> Bool) async {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while await !condition(), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            #expect(await condition())
        }
    }
#endif
