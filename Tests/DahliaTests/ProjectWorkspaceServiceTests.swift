@preconcurrency import AVFoundation
import Foundation
import GRDB
#if canImport(Testing)
    import Testing
    @testable import Dahlia

    @MainActor
    struct ProjectWorkspaceServiceTests {
        @Test
        func createsRootAndOneSubprojectWithoutCreatingDirectories() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let parent = try context.service.createProject(name: "Parent", parentProjectId: nil)
            let child = try context.service.createProject(name: "Child", parentProjectId: parent.id)

            #expect(parent.path == "Parent")
            #expect(child.path == "Parent/Child")
            #expect(throws: ProjectWorkspaceError.hierarchyTooDeep) {
                try context.service.createProject(name: "Grandchild", parentProjectId: child.id)
            }
            #expect(!FileManager.default.fileExists(atPath: context.vaultURL.appending(path: parent.path).path))
            #expect(!FileManager.default.fileExists(atPath: context.vaultURL.appending(path: child.path).path))
        }

        @Test(arguments: ["", ".hidden", "_internal", "a/b", "a:b", "..", "../Outside", "A/../../Outside"])
        func rejectsInvalidNames(name: String) throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            #expect(throws: ProjectWorkspaceError.self) {
                try context.service.createProject(name: name, parentProjectId: nil)
            }
            #expect(try context.repository.fetchAllProjects(vaultId: context.vault.id).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: context.rootURL.appending(path: "Outside").path))
        }

        @Test
        func rejectsDuplicateSiblingNamesIgnoringCase() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            _ = try context.service.createProject(name: "Project", parentProjectId: nil)

            #expect(throws: ProjectWorkspaceError.self) {
                try context.service.createProject(name: "project", parentProjectId: nil)
            }
            #expect(try context.repository.fetchAllProjects(vaultId: context.vault.id).count == 1)
        }

        @Test
        func fetchOrCreateReturnsExistingNormalizedRootIdentity() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let original = try context.service.createProject(name: "Project", parentProjectId: nil)
            let fetched = try context.service.fetchOrCreateRootProject(name: "project")

            #expect(fetched.id == original.id)
            #expect(fetched.name == "Project")
            #expect(try context.repository.fetchAllProjects(vaultId: context.vault.id).count == 1)
        }

        @Test
        func rejectsUnicodeEquivalentSiblingNames() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            _ = try context.service.createProject(name: "Équipe", parentProjectId: nil)

            #expect(throws: ProjectWorkspaceError.self) {
                try context.service.createProject(name: "e\u{301}QUIPE", parentProjectId: nil)
            }
            #expect(try context.repository.fetchAllProjects(vaultId: context.vault.id).count == 1)
        }

        @Test
        func existingDirectoryDoesNotBlockProjectCreationButOverlongNameDoes() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            try FileManager.default.createDirectory(
                at: context.vaultURL.appending(path: "Existing"),
                withIntermediateDirectories: false
            )

            let project = try context.service.createProject(name: "existing", parentProjectId: nil)
            #expect(throws: ProjectWorkspaceError.self) {
                try context.service.createProject(name: String(repeating: "é", count: 128), parentProjectId: nil)
            }
            #expect(project.path == "existing")
            #expect(try context.repository.fetchAllProjects(vaultId: context.vault.id).count == 1)
        }

        @Test
        func createsChildWithoutParentDirectory() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let parent = try context.service.createProject(name: "Parent", parentProjectId: nil)
            let child = try context.service.createProject(name: "Child", parentProjectId: parent.id)

            #expect(child.path == "Parent/Child")
            #expect(!FileManager.default.fileExists(atPath: context.vaultURL.appending(path: parent.path).path))
        }

        @Test
        func projectCreationNeverWritesThroughAnExistingSymlink() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let outsideURL = context.rootURL.appending(path: "Outside", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: false)
            let parentURL = context.vaultURL.appending(path: "Parent", directoryHint: .isDirectory)
            try FileManager.default.createSymbolicLink(at: parentURL, withDestinationURL: outsideURL)

            let parent = try context.service.createProject(name: "Parent", parentProjectId: nil)
            let child = try context.service.createProject(name: "Child", parentProjectId: parent.id)

            #expect(!FileManager.default.fileExists(atPath: outsideURL.appending(path: "Child").path))
            #expect(child.path == "Parent/Child")
        }

        @Test
        func renamingProjectWithoutTrackedSummaryDoesNotTouchSymlinkedDirectory() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let outsideURL = context.rootURL.appending(path: "Outside", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: false)
            let projectURL = context.vaultURL.appending(path: "Source", directoryHint: .isDirectory)
            try FileManager.default.createSymbolicLink(at: projectURL, withDestinationURL: outsideURL)

            let project = try context.service.createProject(name: "Source", parentProjectId: nil)
            let renamed = try context.service.renameProject(id: project.id, newName: "Renamed")

            #expect(FileManager.default.fileExists(atPath: outsideURL.path))
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: projectURL.path) == outsideURL.path)
            #expect(renamed.id == project.id)
            #expect(renamed.path == "Renamed")
        }

        @Test
        func deletingNameWithSQLWildcardDoesNotDeleteSiblingPrefix() async throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let source = try context.service.createProject(name: "100%", parentProjectId: nil)
            let sibling = try context.service.createProject(name: "1000", parentProjectId: nil)

            try await context.service.deleteProjectHierarchy(id: source.id, meetingDisposition: .deleteMeetings)

            #expect(try context.repository.fetchProject(id: source.id) == nil)
            #expect(try context.repository.fetchProject(id: sibling.id)?.name == "1000")
            #expect(!FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "1000").path))
        }

        @Test
        func renamesHierarchyAndStoredSummaryPaths() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let parent = try context.service.createProject(name: "Original", parentProjectId: nil)
            let child = try context.service.createProject(name: "Child", parentProjectId: parent.id)
            try context.repository.updateProjectDescription(
                id: child.id,
                vaultId: context.vault.id,
                description: "Keep me"
            )
            let meeting = try insertMeeting(projectId: child.id, context: context)
            try insertSummary(
                meetingId: meeting.id,
                path: "Original/Child/Summary.md",
                context: context,
                writeFile: true
            )
            try Data("Unrelated".utf8).write(
                to: context.vaultURL.appending(path: "Original/keep.txt"),
                options: .atomic
            )

            let renamed = try context.service.renameProject(id: parent.id, newName: "Renamed")

            let fetchedChildRecord = try context.repository.fetchProject(id: child.id)
            let vaultExport = try context.repository.fetchSummaryExport(
                forMeetingId: meeting.id,
                type: .vault
            )
            let fetchedChild = try #require(fetchedChildRecord)
            #expect(renamed.path == "Renamed")
            #expect(fetchedChild.path == "Renamed/Child")
            #expect(fetchedChild.description == "Keep me")
            #expect(vaultExport?.url == "vault:///Renamed/Child/Summary.md")
            #expect(vaultExport?.vaultRelativePath == "Renamed/Child/Summary.md")
            #expect(FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Renamed/Child/Summary.md").path))
            #expect(FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Original/keep.txt").path))
            #expect(FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Original/Child").path))
        }

        @Test
        func renameLeavesLegacySummaryOutsideDerivedProjectPathUntouched() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let project = try context.service.createProject(name: "Original", parentProjectId: nil)
            let meeting = try insertMeeting(projectId: project.id, context: context)
            try FileManager.default.createDirectory(
                at: context.vaultURL.appending(path: "Legacy", directoryHint: .isDirectory),
                withIntermediateDirectories: false
            )
            try insertSummary(
                meetingId: meeting.id,
                path: "Legacy/Summary.md",
                context: context,
                writeFile: true
            )

            _ = try context.service.renameProject(id: project.id, newName: "Renamed")

            #expect(try context.repository.fetchSummaryVaultRelativePath(forMeetingId: meeting.id) == "Legacy/Summary.md")
            #expect(FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Legacy/Summary.md").path))
        }

        @Test
        func renameRejectsSummarySharedWithRetainedLegacyExport() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let root = try context.service.createProject(name: "Acme", parentProjectId: nil)
            let child = try context.service.createProject(name: "Child", parentProjectId: root.id)
            let rootMeeting = try insertMeeting(projectId: root.id, context: context)
            let childMeeting = try insertMeeting(projectId: child.id, context: context)
            try insertSummary(
                meetingId: rootMeeting.id,
                path: "Acme/Shared.md",
                context: context,
                writeFile: true
            )
            try insertSummary(
                meetingId: childMeeting.id,
                path: "Acme/Shared.md",
                context: context
            )

            #expect(throws: ProjectWorkspaceError.summaryFileShared("Shared.md")) {
                try context.service.renameProject(id: root.id, newName: "Renamed")
            }

            #expect(try context.repository.fetchProject(id: root.id)?.name == "Acme")
            #expect(try context.repository.fetchSummaryVaultRelativePath(forMeetingId: rootMeeting.id)
                == "Acme/Shared.md")
            #expect(try context.repository.fetchSummaryVaultRelativePath(forMeetingId: childMeeting.id)
                == "Acme/Shared.md")
            #expect(FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Acme/Shared.md").path))
            #expect(!FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Renamed/Shared.md").path))
        }

        @Test
        func descriptionUpdateRejectsStaleRevision() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let project = try context.service.createProject(name: "Project", parentProjectId: nil)
            _ = try context.repository.updateProjectDescription(
                id: project.id,
                vaultId: context.vault.id,
                description: "External update"
            )

            #expect(throws: ProjectWorkspaceError.staleRevision(current: project.revision + 1)) {
                try context.service.updateProjectDescription(
                    id: project.id,
                    description: "Stale draft",
                    expectedRevision: project.revision
                )
            }
            #expect(try context.repository.fetchProject(id: project.id)?.description == "External update")
        }

        @Test
        func locationAndTypeUpdatesRejectStaleRevision() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let root = try context.service.createProject(
                name: "Root",
                parentProjectId: nil,
                projectType: .customer
            )
            let destination = try context.service.createProject(name: "Destination", parentProjectId: nil)
            _ = try context.repository.updateProjectDescription(
                id: root.id,
                vaultId: context.vault.id,
                description: "External update"
            )

            #expect(throws: ProjectWorkspaceError.staleRevision(current: root.revision + 1)) {
                try context.service.renameProject(
                    id: root.id,
                    newName: "Renamed",
                    expectedRevision: root.revision
                )
            }
            #expect(throws: ProjectWorkspaceError.staleRevision(current: root.revision + 1)) {
                try context.service.reparentProject(
                    id: root.id,
                    parentProjectId: destination.id,
                    expectedRevision: root.revision
                )
            }
            #expect(throws: ProjectWorkspaceError.staleRevision(current: root.revision + 1)) {
                try context.service.updateRootProjectType(
                    id: root.id,
                    projectType: .internal,
                    expectedRevision: root.revision
                )
            }

            let unchanged = try context.repository.fetchProject(id: root.id)
            #expect(unchanged?.name == "Root")
            #expect(unchanged?.parentProjectId == nil)
            #expect(unchanged?.projectType == .customer)
        }

        @Test
        func reparentsChildPreservesUUIDAndUpdatesInheritedTypeAndSummaryPath() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let customer = try context.service.createProject(
                name: "Customer",
                parentProjectId: nil,
                projectType: .customer
            )
            let work = try context.service.createProject(name: "Work", parentProjectId: customer.id)
            let internalRoot = try context.service.createProject(
                name: "Internal",
                parentProjectId: nil,
                projectType: .internal
            )
            let meeting = try insertMeeting(projectId: work.id, context: context)
            try insertSummary(
                meetingId: meeting.id,
                path: "Customer/Work/Summary.md",
                context: context,
                writeFile: true
            )

            let moved = try context.service.reparentProject(id: work.id, parentProjectId: internalRoot.id)
            let projects = try context.repository.fetchAllProjects(vaultId: context.vault.id)
            let effectiveType = ProjectRecord.effectiveType(for: work.id, records: projects)

            #expect(moved.id == work.id)
            #expect(moved.path == "Internal/Work")
            #expect(effectiveType?.type == .internal)
            #expect(effectiveType?.ownerProjectId == internalRoot.id)
            #expect(try context.repository.fetchSummaryVaultRelativePath(forMeetingId: meeting.id)
                == "Internal/Work/Summary.md")
            #expect(FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Internal/Work/Summary.md").path))
            #expect(FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Customer/Work").path))
        }

        @Test
        func rejectsMovingRootWithChildUnderAnotherRoot() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let source = try context.service.createProject(name: "Source", parentProjectId: nil)
            _ = try context.service.createProject(name: "Child", parentProjectId: source.id)
            let destination = try context.service.createProject(name: "Destination", parentProjectId: nil)

            #expect(throws: ProjectWorkspaceError.hierarchyTooDeep) {
                try context.service.reparentProject(id: source.id, parentProjectId: destination.id)
            }
            #expect(try context.repository.fetchProject(id: source.id)?.parentProjectId == nil)
        }

        @Test
        func movingChildToVaultRootPreservesItsPreviousEffectiveType() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let root = try context.service.createProject(
                name: "Customer",
                parentProjectId: nil,
                projectType: .customer
            )
            let child = try context.service.createProject(name: "Work", parentProjectId: root.id)

            let moved = try context.service.reparentProject(id: child.id, parentProjectId: nil)
            let projects = try context.repository.fetchAllProjects(vaultId: context.vault.id)

            #expect(moved.id == child.id)
            #expect(moved.parentProjectId == nil)
            #expect(moved.projectType == .customer)
            #expect(ProjectRecord.effectiveType(for: child.id, records: projects)?.type == .customer)
        }

        @Test
        func movingChildlessRootUnderRootDropsExplicitType() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let customer = try context.service.createProject(
                name: "Customer",
                parentProjectId: nil,
                projectType: .customer
            )
            let internalRoot = try context.service.createProject(
                name: "Internal",
                parentProjectId: nil,
                projectType: .internal
            )

            let moved = try context.service.reparentProject(id: customer.id, parentProjectId: internalRoot.id)
            let projects = try context.repository.fetchAllProjects(vaultId: context.vault.id)

            #expect(moved.parentProjectId == internalRoot.id)
            #expect(moved.projectType == nil)
            #expect(ProjectRecord.effectiveType(for: customer.id, records: projects)?.type == .internal)
        }

        @Test
        func rootTypeChangePropagatesAndChildTypeUpdateIsRejected() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let root = try context.service.createProject(name: "Root", parentProjectId: nil)
            let child = try context.service.createProject(name: "Child", parentProjectId: root.id)

            _ = try context.service.updateRootProjectType(id: root.id, projectType: .personal)
            let projects = try context.repository.fetchAllProjects(vaultId: context.vault.id)

            #expect(ProjectRecord.effectiveType(for: child.id, records: projects)?.type == .personal)
            #expect(throws: ProjectWorkspaceError.typeOwnedByRoot) {
                try context.service.updateRootProjectType(id: child.id, projectType: .internal)
            }
        }

        @Test
        func rejectsSelfDescendantAndOtherVaultParents() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let root = try context.service.createProject(name: "Root", parentProjectId: nil)
            let child = try context.service.createProject(name: "Child", parentProjectId: root.id)
            #expect(throws: ProjectWorkspaceError.cycleDetected) {
                try context.service.reparentProject(id: root.id, parentProjectId: child.id)
            }

            let otherVaultID = UUID.v7()
            let otherProjectID = UUID.v7()
            try context.database.dbQueue.write { db in
                try VaultRecord(
                    id: otherVaultID,
                    path: context.rootURL.appending(path: "Other").path,
                    name: "Other",
                    createdAt: .now,
                    lastOpenedAt: .now
                ).insert(db)
                try ProjectRecord(
                    id: otherProjectID,
                    vaultId: otherVaultID,
                    parentProjectId: nil,
                    name: "Other",
                    createdAt: .now,
                    projectType: .undefined
                ).insert(db)
            }
            #expect(throws: ProjectWorkspaceError.projectNotFound) {
                try context.service.reparentProject(id: child.id, parentProjectId: otherProjectID)
            }
            #expect(throws: ProjectWorkspaceError.projectNotFound) {
                try context.service.updateRootProjectType(id: otherProjectID, projectType: .customer)
            }
            #expect(throws: ProjectWorkspaceError.projectNotFound) {
                try context.service.updateProjectDescription(id: otherProjectID, description: "Cross Vault")
            }
        }

        @Test
        func safelyRenamesWhenOnlyLetterCaseChanges() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let project = try context.service.createProject(name: "Project", parentProjectId: nil)
            let renamed = try context.service.renameProject(id: project.id, newName: "project")

            #expect(renamed.id == project.id)
            #expect(renamed.name == "project")
            #expect(!FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "project").path))
        }

        @Test
        func updatesProjectFromAWorkerExecutor() async throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let project = try context.service.createProject(name: "Original", parentProjectId: nil)
            let service = context.service
            let updated = try await Task.detached(priority: .userInitiated) {
                try service.updateProject(
                    id: project.id,
                    name: "Updated",
                    parentProjectId: nil,
                    projectType: .customer,
                    description: "Edited away from MainActor",
                    expectedRevision: project.revision
                )
            }.value

            #expect(updated.name == "Updated")
            #expect(updated.description == "Edited away from MainActor")
            #expect(updated.projectType == .customer)
        }

        @Test
        func restoresSummaryAndRemovesNewOutputDirectoryWhenRenameDatabaseUpdateFails() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let project = try context.service.createProject(name: "Original", parentProjectId: nil)
            let meeting = try insertMeeting(projectId: project.id, context: context)
            try insertSummary(
                meetingId: meeting.id,
                path: "Original/Summary.md",
                context: context,
                writeFile: true
            )
            try context.database.dbQueue.write { db in
                try db.execute(sql: """
                CREATE TRIGGER fail_project_rename
                BEFORE UPDATE OF name ON projects
                BEGIN
                    SELECT RAISE(ABORT, 'forced rename failure');
                END
                """)
            }

            #expect(throws: (any Error).self) {
                try context.service.renameProject(id: project.id, newName: "Renamed")
            }
            #expect(try context.repository.fetchProject(id: project.id)?.name == "Original")
            #expect(FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Original/Summary.md").path))
            #expect(!FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Renamed").path))
        }
    }

    extension ProjectWorkspaceServiceTests {
        @Test
        func movesStoredSummaryWithMeeting() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let source = try context.service.createProject(name: "Source", parentProjectId: nil)
            let destination = try context.service.createProject(name: "Destination", parentProjectId: nil)
            let meeting = try insertMeeting(projectId: source.id, context: context)
            try insertSummary(
                meetingId: meeting.id,
                path: "Source/Summary.md",
                context: context,
                writeFile: true
            )
            try context.repository.updateSummaryGoogleFileId(
                forMeetingId: meeting.id,
                googleFileId: "google-document-id"
            )

            try context.service.moveMeeting(id: meeting.id, toProjectId: destination.id)
            let movedMeeting = try context.database.dbQueue.read { db in
                try MeetingRecord.fetchOne(db, key: meeting.id)
            }
            let vaultExport = try context.repository.fetchSummaryExport(
                forMeetingId: meeting.id,
                type: .vault
            )
            #expect(movedMeeting?.projectId == destination.id)
            #expect(vaultExport?.vaultRelativePath == "Destination/Summary.md")
            #expect(
                try context.repository.fetchSummaryExport(forMeetingId: meeting.id, type: .googleDocs)?.googleDocumentID
                    == "google-document-id"
            )
            #expect(!FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Source/Summary.md").path))
            #expect(FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Destination/Summary.md").path))
        }

        @Test
        func movesStoredSummaryToVaultRootWhenProjectIsCleared() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let source = try context.service.createProject(name: "Source", parentProjectId: nil)
            let meeting = try insertMeeting(projectId: source.id, context: context)
            try insertSummary(
                meetingId: meeting.id,
                path: "Source/Summary.md",
                context: context,
                writeFile: true
            )

            try context.service.moveMeeting(id: meeting.id, toProjectId: nil)

            let movedMeeting = try context.database.dbQueue.read { db in
                try MeetingRecord.fetchOne(db, key: meeting.id)
            }
            #expect(movedMeeting?.projectId == nil)
            #expect(try context.repository.fetchSummaryVaultRelativePath(forMeetingId: meeting.id) == "Summary.md")
            #expect(FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Summary.md").path))
        }

        @Test
        func clearsMissingSummaryExportAndStillMovesMeeting() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let source = try context.service.createProject(name: "Source", parentProjectId: nil)
            let destination = try context.service.createProject(name: "Destination", parentProjectId: nil)
            let meeting = try insertMeeting(projectId: source.id, context: context)
            try insertSummary(meetingId: meeting.id, path: "Source/Missing.md", context: context)
            let outsideURL = context.rootURL.appending(path: "Outside", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(
                at: context.vaultURL.appending(path: "Destination", directoryHint: .isDirectory),
                withDestinationURL: outsideURL
            )

            try context.service.moveMeeting(id: meeting.id, toProjectId: destination.id)

            let movedMeeting = try context.database.dbQueue.read { db in
                try MeetingRecord.fetchOne(db, key: meeting.id)
            }
            #expect(movedMeeting?.projectId == destination.id)
            #expect(try context.repository.fetchSummaryVaultRelativePath(forMeetingId: meeting.id) == nil)
            #expect(!FileManager.default.fileExists(atPath: outsideURL.appending(path: "Missing.md").path))
        }

        @Test
        func doesNotMoveSummaryThroughProjectSymlinkOutsideVault() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let source = try context.service.createProject(name: "Source", parentProjectId: nil)
            let destination = try context.service.createProject(name: "Destination", parentProjectId: nil)
            let meeting = try insertMeeting(projectId: source.id, context: context)
            let sourceURL = context.vaultURL.appending(path: "Source", directoryHint: .isDirectory)
            let outsideURL = context.rootURL.appending(path: "Outside", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: false)
            try Data("Outside".utf8).write(to: outsideURL.appending(path: "Summary.md"), options: .atomic)
            try FileManager.default.createSymbolicLink(at: sourceURL, withDestinationURL: outsideURL)
            try insertSummary(meetingId: meeting.id, path: "Source/Summary.md", context: context)

            #expect(throws: ProjectWorkspaceError.invalidMoveDestination) {
                try context.service.moveMeeting(id: meeting.id, toProjectId: destination.id)
            }

            let unchangedMeeting = try context.database.dbQueue.read { db in
                try MeetingRecord.fetchOne(db, key: meeting.id)
            }
            #expect(unchangedMeeting?.projectId == source.id)
            #expect(try context.repository.fetchSummaryVaultRelativePath(forMeetingId: meeting.id) == "Source/Summary.md")
            #expect(FileManager.default.fileExists(atPath: outsideURL.appending(path: "Summary.md").path))
            #expect(!FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Destination/Summary.md").path))
        }

        @Test
        func rejectsDestinationProjectSymlinkOutsideVault() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let source = try context.service.createProject(name: "Source", parentProjectId: nil)
            let destination = try context.service.createProject(name: "Destination", parentProjectId: nil)
            let meeting = try insertMeeting(projectId: source.id, context: context)
            try insertSummary(
                meetingId: meeting.id,
                path: "Source/Summary.md",
                context: context,
                writeFile: true
            )
            let destinationURL = context.vaultURL.appending(path: "Destination", directoryHint: .isDirectory)
            let outsideURL = context.rootURL.appending(path: "Outside", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: destinationURL, withDestinationURL: outsideURL)

            #expect(throws: ProjectWorkspaceError.invalidMoveDestination) {
                try context.service.moveMeeting(id: meeting.id, toProjectId: destination.id)
            }

            #expect(try context.repository.fetchSummaryVaultRelativePath(forMeetingId: meeting.id) == "Source/Summary.md")
            #expect(FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Source/Summary.md").path))
            #expect(!FileManager.default.fileExists(atPath: outsideURL.appending(path: "Summary.md").path))
        }

        @Test
        func preservesSummaryAndExportWhenFileInspectionFails() throws {
            struct InspectionFailure: Error {}

            let context = try makeContext(summaryFileResolver: { _, _ in throw InspectionFailure() })
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let source = try context.service.createProject(name: "Source", parentProjectId: nil)
            let destination = try context.service.createProject(name: "Destination", parentProjectId: nil)
            let meeting = try insertMeeting(projectId: source.id, context: context)
            try insertSummary(
                meetingId: meeting.id,
                path: "Source/Summary.md",
                context: context,
                writeFile: true
            )

            #expect(throws: InspectionFailure.self) {
                try context.service.moveMeeting(id: meeting.id, toProjectId: destination.id)
            }

            #expect(try context.repository.fetchSummaryVaultRelativePath(forMeetingId: meeting.id) == "Source/Summary.md")
            #expect(FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Source/Summary.md").path))
            #expect(!FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Destination/Summary.md").path))
        }

        @Test
        func rejectsMovingOneMeetingWhenSummaryFileIsShared() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let source = try context.service.createProject(name: "Source", parentProjectId: nil)
            let destination = try context.service.createProject(name: "Destination", parentProjectId: nil)
            let movingMeeting = try insertMeeting(projectId: source.id, context: context)
            let remainingMeeting = try insertMeeting(projectId: source.id, context: context)
            try insertSummary(
                meetingId: movingMeeting.id,
                path: "Source/Summary.md",
                context: context,
                writeFile: true
            )
            try insertSummary(meetingId: remainingMeeting.id, path: "source/summary.md", context: context)

            #expect(throws: ProjectWorkspaceError.summaryFileShared("Summary.md")) {
                try context.service.moveMeeting(id: movingMeeting.id, toProjectId: destination.id)
            }

            #expect(try context.repository.fetchSummaryVaultRelativePath(forMeetingId: movingMeeting.id) == "Source/Summary.md")
            #expect(try context.repository.fetchSummaryVaultRelativePath(forMeetingId: remainingMeeting.id) == "source/summary.md")
            #expect(FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Source/Summary.md").path))
            #expect(!FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Destination/Summary.md").path))
        }

        @Test
        func movesSharedSummaryOnceWhenAllReferencingMeetingsMove() async throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let source = try context.service.createProject(name: "Source", parentProjectId: nil)
            let destination = try context.service.createProject(name: "Destination", parentProjectId: nil)
            let firstMeeting = try insertMeeting(projectId: source.id, context: context)
            let secondMeeting = try insertMeeting(projectId: source.id, context: context)
            try insertSummary(
                meetingId: firstMeeting.id,
                path: "Source/Summary.md",
                context: context,
                writeFile: true
            )
            try insertSummary(meetingId: secondMeeting.id, path: "Source/Summary.md", context: context)

            try await context.service.deleteProjectHierarchy(
                id: source.id,
                meetingDisposition: .move(to: destination.id)
            )

            #expect(
                try context.repository.fetchSummaryVaultRelativePath(forMeetingId: firstMeeting.id)
                    == "Destination/Summary.md"
            )
            #expect(
                try context.repository.fetchSummaryVaultRelativePath(forMeetingId: secondMeeting.id)
                    == "Destination/Summary.md"
            )
            #expect(FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Destination/Summary.md").path))
            #expect(!FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Source/Summary.md").path))
        }

        @Test
        func rejectsSummaryNameCollisionWithoutChangingMeeting() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let source = try context.service.createProject(name: "Source", parentProjectId: nil)
            let destination = try context.service.createProject(name: "Destination", parentProjectId: nil)
            let meeting = try insertMeeting(projectId: source.id, context: context)
            try insertSummary(
                meetingId: meeting.id,
                path: "Source/Summary.md",
                context: context,
                writeFile: true
            )
            try FileManager.default.createDirectory(
                at: context.vaultURL.appending(path: "Destination", directoryHint: .isDirectory),
                withIntermediateDirectories: false
            )
            try Data("Existing".utf8).write(
                to: context.vaultURL.appending(path: "Destination/Summary.md"),
                options: .atomic
            )

            #expect(throws: ProjectWorkspaceError.summaryFileAlreadyExists("Summary.md")) {
                try context.service.moveMeeting(id: meeting.id, toProjectId: destination.id)
            }

            let unchangedMeeting = try context.database.dbQueue.read { db in
                try MeetingRecord.fetchOne(db, key: meeting.id)
            }
            #expect(unchangedMeeting?.projectId == source.id)
            #expect(try context.repository.fetchSummaryVaultRelativePath(forMeetingId: meeting.id) == "Source/Summary.md")
            #expect(FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Source/Summary.md").path))
        }

        @Test
        func rejectsDuplicateSummaryNamesInBatchBeforeMovingFiles() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let firstSource = try context.service.createProject(name: "First", parentProjectId: nil)
            let secondSource = try context.service.createProject(name: "Second", parentProjectId: nil)
            let destination = try context.service.createProject(name: "Destination", parentProjectId: nil)
            let firstMeeting = try insertMeeting(projectId: firstSource.id, context: context)
            let secondMeeting = try insertMeeting(projectId: secondSource.id, context: context)
            try insertSummary(
                meetingId: firstMeeting.id,
                path: "First/Summary.md",
                context: context,
                writeFile: true
            )
            try insertSummary(
                meetingId: secondMeeting.id,
                path: "Second/Summary.md",
                context: context,
                writeFile: true
            )

            #expect(throws: ProjectWorkspaceError.summaryFileAlreadyExists("Summary.md")) {
                try context.service.moveMeetings(
                    ids: [firstMeeting.id, secondMeeting.id],
                    toProjectId: destination.id
                )
            }

            #expect(FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "First/Summary.md").path))
            #expect(FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Second/Summary.md").path))
            #expect(!FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Destination/Summary.md").path))
        }

        @Test
        func restoresSummaryWhenMeetingDatabaseUpdateFails() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let source = try context.service.createProject(name: "Source", parentProjectId: nil)
            let destination = try context.service.createProject(name: "Destination", parentProjectId: nil)
            let meeting = try insertMeeting(projectId: source.id, context: context)
            try insertSummary(
                meetingId: meeting.id,
                path: "Source/Summary.md",
                context: context,
                writeFile: true
            )
            try context.database.dbQueue.write { db in
                try db.execute(sql: """
                CREATE TRIGGER fail_meeting_move
                BEFORE UPDATE OF projectId ON meetings
                BEGIN
                    SELECT RAISE(ABORT, 'forced meeting move failure');
                END
                """)
            }

            #expect(throws: (any Error).self) {
                try context.service.moveMeeting(id: meeting.id, toProjectId: destination.id)
            }

            let unchangedMeeting = try context.database.dbQueue.read { db in
                try MeetingRecord.fetchOne(db, key: meeting.id)
            }
            #expect(unchangedMeeting?.projectId == source.id)
            #expect(try context.repository.fetchSummaryVaultRelativePath(forMeetingId: meeting.id) == "Source/Summary.md")
            #expect(FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Source/Summary.md").path))
            #expect(!FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Destination/Summary.md").path))
        }

        @Test
        func deletesHierarchyAfterMovingMeetings() async throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let source = try context.service.createProject(name: "Source", parentProjectId: nil)
            let child = try context.service.createProject(name: "Child", parentProjectId: source.id)
            let destination = try context.service.createProject(name: "Destination", parentProjectId: nil)
            let meeting = try insertMeeting(projectId: child.id, context: context)
            try insertSummary(
                meetingId: meeting.id,
                path: "Source/Child/Summary.md",
                context: context,
                writeFile: true
            )
            try insertSegment(meetingId: meeting.id, context: context)
            try context.repository.addTag(name: "important", toMeetingId: meeting.id, colorHex: "#FF0000")
            let audioURL = try await insertAudio(meetingId: meeting.id, context: context)

            try await context.service.deleteProjectHierarchy(id: source.id, meetingDisposition: .move(to: destination.id))

            let fetchedMeeting = try await context.database.dbQueue.read { db in
                try MeetingRecord.fetchOne(db, key: meeting.id)
            }
            let fetchedSummary = try context.repository.fetchSummary(forMeetingId: meeting.id)
            let vaultExport = try context.repository.fetchSummaryExport(
                forMeetingId: meeting.id,
                type: .vault
            )
            let summary = try #require(fetchedSummary)
            #expect(fetchedMeeting?.projectId == destination.id)
            #expect(vaultExport?.vaultRelativePath == "Destination/Summary.md")
            #expect(try summary.loadDocument().sections.first?.blocks == [.paragraph("Body")])
            #expect(try context.repository.fetchSegments(forMeetingId: meeting.id).count == 1)
            #expect(try context.repository.fetchTagsForMeeting(id: meeting.id).map(\.name) == ["important"])
            #expect(FileManager.default.fileExists(atPath: audioURL.path))
            #expect(FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Destination/Summary.md").path))
            #expect(try context.repository.fetchProject(id: source.id) == nil)
            #expect(try context.repository.fetchProject(id: child.id) == nil)
            #expect(FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Source/Child").path))
            #expect(!FileManager.default.fileExists(atPath: context.trashURL.appending(path: "Source").path))
        }

        @Test
        func movingMeetingsRelocatesSummariesOutsideDeletedHierarchy() async throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let source = try context.service.createProject(name: "Source", parentProjectId: nil)
            let destination = try context.service.createProject(name: "Destination", parentProjectId: nil)
            let meeting = try insertMeeting(projectId: source.id, context: context)
            try FileManager.default.createDirectory(
                at: context.vaultURL.appending(path: "Archive", directoryHint: .isDirectory),
                withIntermediateDirectories: false
            )
            try insertSummary(
                meetingId: meeting.id,
                path: "Archive/Summary.md",
                context: context,
                writeFile: true
            )

            try await context.service.deleteProjectHierarchy(id: source.id, meetingDisposition: .move(to: destination.id))

            let vaultExport = try context.repository.fetchSummaryExport(
                forMeetingId: meeting.id,
                type: .vault
            )
            #expect(vaultExport?.vaultRelativePath == "Destination/Summary.md")
            #expect(!FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Archive/Summary.md").path))
            #expect(FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Destination/Summary.md").path))
        }

        @Test
        func deletesMeetingsAndDependentContentWithHierarchy() async throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let source = try context.service.createProject(name: "Source", parentProjectId: nil)
            let meeting = try insertMeeting(projectId: source.id, context: context)
            try insertSummary(
                meetingId: meeting.id,
                path: "Source/Summary.md",
                context: context,
                writeFile: true
            )
            try insertSegment(meetingId: meeting.id, context: context)
            let audioURL = try await insertAudio(meetingId: meeting.id, context: context)

            try await context.service.deleteProjectHierarchy(id: source.id, meetingDisposition: .deleteMeetings)

            let counts = try await context.database.dbQueue.read { db in
                try (
                    MeetingRecord.filter(Column("id") == meeting.id).fetchCount(db),
                    SummaryRecord.filter(Column("meetingId") == meeting.id).fetchCount(db),
                    TranscriptSegmentRecord.filter(Column("meetingId") == meeting.id).fetchCount(db)
                )
            }
            #expect(counts.0 == 0)
            #expect(counts.1 == 0)
            #expect(counts.2 == 0)
            #expect(!FileManager.default.fileExists(atPath: audioURL.path))
            #expect(try context.repository.fetchProject(id: source.id) == nil)
            #expect(FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Source/Summary.md").path))
        }

        @Test
        func optionallyMovesTrackedSummaryToTrashWhenDeletingMeetings() async throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let source = try context.service.createProject(name: "Source", parentProjectId: nil)
            let meeting = try insertMeeting(projectId: source.id, context: context)
            try insertSummary(
                meetingId: meeting.id,
                path: "Source/Summary.md",
                context: context,
                writeFile: true
            )

            try await context.service.deleteProjectHierarchy(
                id: source.id,
                meetingDisposition: .deleteMeetings,
                deletesSummaryFiles: true
            )

            #expect(!FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Source/Summary.md").path))
            #expect(FileManager.default.fileExists(atPath: context.trashURL.appending(path: "Summary.md").path))
            #expect(FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Source").path))
        }

        @Test
        func deletingProjectRejectsSummaryThroughSymlinkOutsideVault() async throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let project = try context.service.createProject(name: "Project", parentProjectId: nil)
            let meeting = try insertMeeting(projectId: project.id, context: context)
            let outsideDirectory = context.rootURL.appending(path: "Outside", directoryHint: .isDirectory)
            let outsideSummary = outsideDirectory.appending(path: "Summary.md")
            try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: false)
            try Data("Outside".utf8).write(to: outsideSummary, options: .atomic)
            try FileManager.default.createSymbolicLink(
                at: context.vaultURL.appending(path: "Project", directoryHint: .isDirectory),
                withDestinationURL: outsideDirectory
            )
            try insertSummary(meetingId: meeting.id, path: "Project/Summary.md", context: context)

            await #expect(throws: ProjectWorkspaceError.invalidMoveDestination) {
                try await context.service.deleteProjectHierarchy(
                    id: project.id,
                    meetingDisposition: .deleteMeetings,
                    deletesSummaryFiles: true
                )
            }

            #expect(try context.repository.fetchProject(id: project.id) != nil)
            #expect(FileManager.default.fileExists(atPath: outsideSummary.path))
            #expect(!FileManager.default.fileExists(atPath: context.trashURL.appending(path: "Summary.md").path))
        }

        @Test
        func rejectsDeleteWhileBatchTranscriptionReadsSegmentedAudio() async throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let project = try context.service.createProject(name: "Project", parentProjectId: nil)
            let meeting = try insertMeeting(projectId: project.id, context: context)
            let audioURL = try await insertAudio(meetingId: meeting.id, context: context)
            let sessionId = try await context.database.dbQueue.read { db in
                try #require(
                    try UUID.fetchOne(
                        db,
                        sql: "SELECT id FROM recording_sessions WHERE meetingId = ?",
                        arguments: [meeting.id]
                    )
                )
            }
            let store = try RecordingAudioStore(
                dbQueue: context.database.dbQueue,
                managedRootURL: context.rootURL.appending(path: "ManagedAudio", directoryHint: .isDirectory)
            )
            let started = AsyncStream<Void>.makeStream()
            let release = AsyncStream<Void>.makeStream()
            let reader = Task {
                try await store.withVerifiedTranscribableSegments(sessionId: sessionId) { _ in
                    started.continuation.yield()
                    for await _ in release.stream {
                        break
                    }
                }
            }
            var startedIterator = started.stream.makeAsyncIterator()
            #expect(await startedIterator.next() != nil)

            await #expect(throws: RecordingAudioStoreError.activeSession) {
                try await context.service.deleteProjectHierarchy(
                    id: project.id,
                    meetingDisposition: .deleteMeetings
                )
            }
            #expect(FileManager.default.fileExists(atPath: audioURL.path))
            #expect(try context.repository.fetchProject(id: project.id) != nil)
            #expect(try context.repository.fetchMeeting(id: meeting.id) != nil)

            release.continuation.finish()
            try await reader.value
        }

        @Test
        func failedDeleteKeepsDatabaseProjectAndDoesNotTouchDirectories() async throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let project = try context.service.createProject(name: "Project", parentProjectId: nil)
            try await context.database.dbQueue.write { db in
                try db.execute(sql: """
                CREATE TRIGGER fail_project_delete
                BEFORE DELETE ON projects
                BEGIN
                    SELECT RAISE(ABORT, 'forced delete failure');
                END
                """)
            }

            await #expect(throws: (any Error).self) {
                try await context.service.deleteProjectHierarchy(id: project.id, meetingDisposition: .deleteMeetings)
            }
            #expect(try context.repository.fetchProject(id: project.id)?.name == "Project")
            #expect(!FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Project").path))
            #expect(!FileManager.default.fileExists(atPath: context.trashURL.appending(path: "Project").path))
        }

        @Test
        func restoresAudioWhenProjectDeleteDatabaseUpdateFails() async throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let project = try context.service.createProject(name: "Project", parentProjectId: nil)
            let meeting = try insertMeeting(projectId: project.id, context: context)
            let audioURL = try await insertAudio(meetingId: meeting.id, context: context)
            try await context.database.dbQueue.write { db in
                try db.execute(sql: """
                CREATE TRIGGER fail_project_delete_with_audio
                BEFORE DELETE ON projects
                BEGIN
                    SELECT RAISE(ABORT, 'forced delete failure with audio');
                END
                """)
            }

            await #expect(throws: (any Error).self) {
                try await context.service.deleteProjectHierarchy(
                    id: project.id,
                    meetingDisposition: .deleteMeetings
                )
            }
            #expect(FileManager.default.fileExists(atPath: audioURL.path))
            #expect(try context.repository.fetchProject(id: project.id) != nil)
            #expect(try await context.database.dbQueue.read { db in
                try MeetingRecord.fetchOne(db, key: meeting.id)
            } != nil)
        }

        @Test
        func reportsAudioRollbackFailureWhenProjectDeleteFails() async throws {
            let rollbackError = CocoaError(.fileWriteNoPermission)
            let context = try makeContext(stagedAudioRestorer: { _ in throw rollbackError })
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let project = try context.service.createProject(name: "Project", parentProjectId: nil)
            let meeting = try insertMeeting(projectId: project.id, context: context)
            _ = try await insertAudio(meetingId: meeting.id, context: context)
            try await context.database.dbQueue.write { db in
                try db.execute(sql: """
                CREATE TRIGGER fail_project_delete_audio_rollback
                BEFORE DELETE ON projects
                BEGIN
                    SELECT RAISE(ABORT, 'forced delete failure with rollback failure');
                END
                """)
            }

            do {
                try await context.service.deleteProjectHierarchy(
                    id: project.id,
                    meetingDisposition: .deleteMeetings
                )
                Issue.record("Expected project deletion to fail")
            } catch let ProjectWorkspaceError.rollbackFailed(operation, rollback) {
                #expect(operation.contains("forced delete failure"))
                #expect(rollback == rollbackError.localizedDescription)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
            #expect(try context.repository.fetchProject(id: project.id) != nil)
            #expect(try await context.database.dbQueue.read { db in
                try MeetingRecord.fetchOne(db, key: meeting.id)
            } != nil)
        }

        @Test
        func restoresFolderAndSummaryWhenDeleteAfterMeetingMoveFails() async throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let source = try context.service.createProject(name: "Source", parentProjectId: nil)
            let destination = try context.service.createProject(name: "Destination", parentProjectId: nil)
            let meeting = try insertMeeting(projectId: source.id, context: context)
            try insertSummary(
                meetingId: meeting.id,
                path: "Source/Summary.md",
                context: context,
                writeFile: true
            )
            try await context.database.dbQueue.write { db in
                try db.execute(sql: """
                CREATE TRIGGER fail_project_delete_after_move
                BEFORE DELETE ON projects
                BEGIN
                    SELECT RAISE(ABORT, 'forced delete failure after move');
                END
                """)
            }

            await #expect(throws: (any Error).self) {
                try await context.service.deleteProjectHierarchy(
                    id: source.id,
                    meetingDisposition: .move(to: destination.id)
                )
            }

            let unchangedMeeting = try await context.database.dbQueue.read { db in
                try MeetingRecord.fetchOne(db, key: meeting.id)
            }
            #expect(unchangedMeeting?.projectId == source.id)
            #expect(try context.repository.fetchSummaryVaultRelativePath(forMeetingId: meeting.id) == "Source/Summary.md")
            #expect(FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Source/Summary.md").path))
            #expect(!FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Destination/Summary.md").path))
            #expect(!FileManager.default.fileExists(atPath: context.trashURL.appending(path: "Source").path))
        }
    }

    private extension ProjectWorkspaceServiceTests {
        private func makeContext(
            summaryFileResolver: @escaping ProjectWorkspaceService.SummaryFileResolver =
                ProjectWorkspaceService.resolveSummaryFile,
            stagedAudioRestorer: @escaping ProjectWorkspaceService.StagedAudioRestorer =
                BatchAudioCleanupService.restoreStagedFiles
        ) throws -> ProjectWorkspaceTestContext {
            let rootURL = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            let vaultURL = rootURL.appending(path: "Vault", directoryHint: .isDirectory)
            let trashURL = rootURL.appending(path: "Trash", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)

            let database = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: database.dbQueue)
            let vault = VaultRecord(
                id: .v7(),
                path: vaultURL.path,
                name: "Test Vault",
                createdAt: .now,
                lastOpenedAt: .now
            )
            try repository.insertVault(vault)
            let service = ProjectWorkspaceService(
                repository: repository,
                vault: vault,
                managedAudioRootURL: rootURL.appending(path: "ManagedAudio", directoryHint: .isDirectory),
                trashHandler: { sourceURL in
                    let destinationURL = trashURL.appending(path: sourceURL.lastPathComponent, directoryHint: .isDirectory)
                    try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
                    return destinationURL
                },
                summaryFileResolver: summaryFileResolver,
                stagedAudioRestorer: stagedAudioRestorer
            )
            return ProjectWorkspaceTestContext(
                rootURL: rootURL,
                vaultURL: vaultURL,
                trashURL: trashURL,
                database: database,
                repository: repository,
                vault: vault,
                service: service
            )
        }

        private func insertMeeting(
            projectId: UUID,
            context: ProjectWorkspaceTestContext
        ) throws -> MeetingRecord {
            let meeting = MeetingRecord(
                id: .v7(),
                vaultId: context.vault.id,
                projectId: projectId,
                name: "Meeting",
                createdAt: .now,
                updatedAt: .now
            )
            try context.database.dbQueue.write { db in try meeting.insert(db) }
            return meeting
        }

        private func insertSummary(
            meetingId: UUID,
            path: String,
            context: ProjectWorkspaceTestContext,
            writeFile: Bool = false
        ) throws {
            try context.repository.upsertSummary(
                SummaryRecord(
                    meetingId: meetingId,
                    title: "Summary",
                    document: SummaryDocument(
                        title: "Summary",
                        sections: [SummarySection(id: .v7(), heading: "Summary", blocks: [.paragraph("Body")])]
                    ).databaseJSONString(),
                    createdAt: .now
                )
            )
            try context.repository.updateSummaryVaultRelativePath(
                forMeetingId: meetingId,
                relativePath: path
            )
            if writeFile {
                let fileURL = context.vaultURL.appending(path: path)
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data("Summary".utf8).write(to: fileURL, options: .atomic)
            }
        }

        private func insertSegment(
            meetingId: UUID,
            context: ProjectWorkspaceTestContext
        ) throws {
            try context.database.dbQueue.write { db in
                try TranscriptSegmentRecord(
                    id: .v7(),
                    meetingId: meetingId,
                    startTime: .now,
                    text: "Transcript",
                    isConfirmed: true
                ).insert(db)
            }
        }

        private func insertAudio(
            meetingId: UUID,
            context: ProjectWorkspaceTestContext
        ) async throws -> URL {
            let now = Date.now
            let session = RecordingSessionRecord(
                id: .v7(),
                meetingId: meetingId,
                startedAt: now,
                endedAt: now,
                duration: 1,
                offsetSeconds: 0,
                createdAt: now,
                updatedAt: now
            )
            try await context.database.dbQueue.write { db in
                try session.insert(db)
            }
            let configuration = RecordingAudioStore.Configuration(
                targetSegmentDuration: .seconds(60),
                maximumFinalizingSegmentCountPerSource: 2,
                maximumActiveSegmentDuration: .seconds(600),
                maximumActiveSegmentByteCount: 64 * 1024 * 1024,
                minimumAvailableCapacity: 0,
                capacityCheckInterval: .seconds(5)
            )
            let managedRootURL = context.rootURL.appending(path: "ManagedAudio", directoryHint: .isDirectory)
            let recorder = try BatchAudioRecordingSession(
                dbQueue: context.database.dbQueue,
                managedRootURL: managedRootURL,
                meetingId: meetingId,
                recordingSessionId: session.id,
                recordingStartTime: now,
                sampleRate: 16000,
                configuration: configuration
            )
            let writer = try await recorder.beginRange(
                source: .microphone,
                locale: Locale(identifier: "ja_JP"),
                at: now
            )
            let buffer = try #require(
                AVAudioPCMBuffer(pcmFormat: recorder.targetFormat, frameCapacity: 160)
            )
            buffer.frameLength = 160
            writer.appendBuffer(buffer)
            try await recorder.finish()
            let audioSegment = try await context.database.dbQueue.read { db in
                try #require(
                    try RecordingAudioSegmentRecord
                        .filter(Column("recordingSessionId") == session.id)
                        .fetchOne(db)
                )
            }
            return managedRootURL.appending(path: audioSegment.finalRelativePath)
        }
    }
#endif
