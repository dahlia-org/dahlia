@preconcurrency import AVFoundation
import Foundation
import GRDB
#if canImport(Testing)
    import Testing
    @testable import Dahlia

    @MainActor
    struct ProjectWorkspaceServiceTests {
        @Test
        func createsTopLevelAndNestedProjects() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let parent = try context.service.createProject(leafName: "Parent", parentProjectId: nil)
            let child = try context.service.createProject(leafName: "Child", parentProjectId: parent.id)
            let grandchild = try context.service.createProject(leafName: "Grandchild", parentProjectId: child.id)

            #expect(parent.name == "Parent")
            #expect(child.name == "Parent/Child")
            #expect(grandchild.name == "Parent/Child/Grandchild")
            #expect(FileManager.default.fileExists(atPath: context.vaultURL.appending(path: grandchild.name).path))
        }

        @Test(arguments: ["", ".hidden", "_internal", "a/b", "a:b", "..", "../Outside", "A/../../Outside"])
        func rejectsInvalidLeafNames(name: String) throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            #expect(throws: ProjectWorkspaceError.self) {
                try context.service.createProject(leafName: name, parentProjectId: nil)
            }
            #expect(try context.repository.fetchAllProjects(vaultId: context.vault.id).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: context.rootURL.appending(path: "Outside").path))
        }

        @Test
        func rejectsDuplicateSiblingNamesIgnoringCase() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            _ = try context.service.createProject(leafName: "Project", parentProjectId: nil)

            #expect(throws: ProjectWorkspaceError.self) {
                try context.service.createProject(leafName: "project", parentProjectId: nil)
            }
            #expect(try context.repository.fetchAllProjects(vaultId: context.vault.id).count == 1)
        }

        @Test
        func fetchOrCreateReturnsExistingNormalizedRootIdentity() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let original = try context.service.createProject(leafName: "Project", parentProjectId: nil)
            let fetched = try context.service.fetchOrCreateRootProject(leafName: "project")

            #expect(fetched.id == original.id)
            #expect(fetched.name == "Project")
            #expect(try context.repository.fetchAllProjects(vaultId: context.vault.id).count == 1)
        }

        @Test
        func rejectsUnicodeEquivalentSiblingNames() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            _ = try context.service.createProject(leafName: "Équipe", parentProjectId: nil)

            #expect(throws: ProjectWorkspaceError.self) {
                try context.service.createProject(leafName: "e\u{301}QUIPE", parentProjectId: nil)
            }
            #expect(try context.repository.fetchAllProjects(vaultId: context.vault.id).count == 1)
        }

        @Test
        func rejectsExistingFolderCollisionAndOverlongName() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            try FileManager.default.createDirectory(
                at: context.vaultURL.appending(path: "Existing"),
                withIntermediateDirectories: false
            )

            #expect(throws: ProjectWorkspaceError.self) {
                try context.service.createProject(leafName: "existing", parentProjectId: nil)
            }
            #expect(throws: ProjectWorkspaceError.self) {
                try context.service.createProject(leafName: String(repeating: "é", count: 128), parentProjectId: nil)
            }
            #expect(try context.repository.fetchAllProjects(vaultId: context.vault.id).isEmpty)
        }

        @Test
        func rejectsCreatingChildWhenParentFolderIsMissing() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let parent = try context.service.createProject(leafName: "Parent", parentProjectId: nil)
            try FileManager.default.removeItem(at: context.vaultURL.appending(path: parent.name))
            try context.database.dbQueue.write { db in
                try ProjectRecord.setMissingByPrefix(parent.name, missing: true, vaultId: context.vault.id, in: db)
            }

            #expect(throws: ProjectWorkspaceError.self) {
                try context.service.createProject(leafName: "Child", parentProjectId: parent.id)
            }
            #expect(try context.repository.fetchAllProjects(vaultId: context.vault.id).count == 1)
        }

        @Test
        func rejectsCreatingChildThroughSymlinkOutsideVault() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let parent = try context.service.createProject(leafName: "Parent", parentProjectId: nil)
            let parentURL = context.vaultURL.appending(path: parent.name, directoryHint: .isDirectory)
            let outsideURL = context.rootURL.appending(path: "Outside", directoryHint: .isDirectory)
            try FileManager.default.removeItem(at: parentURL)
            try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: parentURL, withDestinationURL: outsideURL)

            #expect(throws: ProjectWorkspaceError.invalidMoveDestination) {
                try context.service.createProject(leafName: "Child", parentProjectId: parent.id)
            }
            #expect(!FileManager.default.fileExists(atPath: outsideURL.appending(path: "Child").path))
            #expect(try context.repository.fetchAllProjects(vaultId: context.vault.id).count == 1)
        }

        @Test
        func rejectsRenamingProjectThroughSourceSymlinkOutsideVault() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let project = try context.service.createProject(leafName: "Source", parentProjectId: nil)
            let projectURL = context.vaultURL.appending(path: project.name, directoryHint: .isDirectory)
            let outsideURL = context.rootURL.appending(path: "Outside", directoryHint: .isDirectory)
            try FileManager.default.removeItem(at: projectURL)
            try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: projectURL, withDestinationURL: outsideURL)

            #expect(throws: ProjectWorkspaceError.invalidMoveDestination) {
                try context.service.renameProject(id: project.id, newLeafName: "Renamed")
            }
            #expect(FileManager.default.fileExists(atPath: outsideURL.path))
            #expect(try context.repository.fetchProject(id: project.id)?.name == "Source")
        }

        @Test
        func deletingNameWithSQLWildcardDoesNotDeleteSiblingPrefix() async throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let source = try context.service.createProject(leafName: "100%", parentProjectId: nil)
            let sibling = try context.service.createProject(leafName: "1000", parentProjectId: nil)

            try await context.service.deleteProjectHierarchy(id: source.id, meetingDisposition: .deleteMeetings)

            #expect(try context.repository.fetchProject(id: source.id) == nil)
            #expect(try context.repository.fetchProject(id: sibling.id)?.name == "1000")
            #expect(FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "1000").path))
        }

        @Test
        func renamesHierarchyAndStoredSummaryPaths() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let parent = try context.service.createProject(leafName: "Original", parentProjectId: nil)
            let child = try context.service.createProject(leafName: "Child", parentProjectId: parent.id)
            try context.repository.updateProjectDescription(
                id: child.id,
                vaultId: context.vault.id,
                description: "Keep me"
            )
            let meeting = try insertMeeting(projectId: child.id, context: context)
            try insertSummary(meetingId: meeting.id, path: "Original/Child/Summary.md", context: context)

            let renamed = try context.service.renameProject(id: parent.id, newLeafName: "Renamed")

            let fetchedChildRecord = try context.repository.fetchProject(id: child.id)
            let vaultExport = try context.repository.fetchSummaryExport(
                forMeetingId: meeting.id,
                type: .vault
            )
            let fetchedChild = try #require(fetchedChildRecord)
            #expect(renamed.name == "Renamed")
            #expect(fetchedChild.name == "Renamed/Child")
            #expect(fetchedChild.description == "Keep me")
            #expect(vaultExport?.url == "vault:///Renamed/Child/Summary.md")
            #expect(vaultExport?.vaultRelativePath == "Renamed/Child/Summary.md")
            #expect(FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Renamed/Child").path))
            #expect(!FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Original").path))
        }

        @Test
        func descriptionUpdateRejectsStaleRevision() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let project = try context.service.createProject(leafName: "Project", parentProjectId: nil)
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
        func reparentsHierarchyPreservesUUIDsAndUpdatesInheritedTypeAndSummaryPaths() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let customer = try context.service.createProject(
                leafName: "Customer",
                parentProjectId: nil,
                projectType: .customer
            )
            let work = try context.service.createProject(leafName: "Work", parentProjectId: customer.id)
            let child = try context.service.createProject(leafName: "Child", parentProjectId: work.id)
            let internalRoot = try context.service.createProject(
                leafName: "Internal",
                parentProjectId: nil,
                projectType: .internal
            )
            let meeting = try insertMeeting(projectId: child.id, context: context)
            try insertSummary(meetingId: meeting.id, path: "Customer/Work/Child/Summary.md", context: context)

            let moved = try context.service.reparentProject(id: work.id, parentProjectId: internalRoot.id)
            let projects = try context.repository.fetchAllProjects(vaultId: context.vault.id)
            let fetchedChild = try #require(projects.first(where: { $0.id == child.id }))
            let childType = ProjectRecord.effectiveType(for: child.id, records: projects)

            #expect(moved.id == work.id)
            #expect(fetchedChild.id == child.id)
            #expect(fetchedChild.name == "Internal/Work/Child")
            #expect(childType?.type == .internal)
            #expect(childType?.ownerProjectId == internalRoot.id)
            #expect(try context.repository.fetchSummaryVaultRelativePath(forMeetingId: meeting.id)
                == "Internal/Work/Child/Summary.md")
            #expect(FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Internal/Work/Child").path))
            #expect(!FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Customer/Work").path))
        }

        @Test
        func movingChildToVaultRootPreservesItsPreviousEffectiveType() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let root = try context.service.createProject(
                leafName: "Customer",
                parentProjectId: nil,
                projectType: .customer
            )
            let child = try context.service.createProject(leafName: "Work", parentProjectId: root.id)

            let moved = try context.service.reparentProject(id: child.id, parentProjectId: nil)
            let projects = try context.repository.fetchAllProjects(vaultId: context.vault.id)

            #expect(moved.id == child.id)
            #expect(moved.parentProjectId == nil)
            #expect(moved.projectType == .customer)
            #expect(ProjectRecord.effectiveType(for: child.id, records: projects)?.type == .customer)
        }

        @Test
        func rootTypeChangePropagatesAndChildTypeUpdateIsRejected() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let root = try context.service.createProject(leafName: "Root", parentProjectId: nil)
            let child = try context.service.createProject(leafName: "Child", parentProjectId: root.id)
            let grandchild = try context.service.createProject(leafName: "Grandchild", parentProjectId: child.id)

            _ = try context.service.updateRootProjectType(id: root.id, projectType: .personal)
            let projects = try context.repository.fetchAllProjects(vaultId: context.vault.id)

            #expect(ProjectRecord.effectiveType(for: child.id, records: projects)?.type == .personal)
            #expect(ProjectRecord.effectiveType(for: grandchild.id, records: projects)?.type == .personal)
            #expect(throws: ProjectWorkspaceError.typeOwnedByRoot) {
                try context.service.updateRootProjectType(id: child.id, projectType: .internal)
            }
        }

        @Test
        func rejectsSelfDescendantAndOtherVaultParents() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let root = try context.service.createProject(leafName: "Root", parentProjectId: nil)
            let child = try context.service.createProject(leafName: "Child", parentProjectId: root.id)
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
                    leafName: "Other",
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

            let project = try context.service.createProject(leafName: "Project", parentProjectId: nil)
            let renamed = try context.service.renameProject(id: project.id, newLeafName: "project")

            #expect(renamed.id == project.id)
            #expect(renamed.name == "project")
            #expect(FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "project").path))
        }

        @Test
        func restoresFolderWhenRenameDatabaseUpdateFails() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let project = try context.service.createProject(leafName: "Original", parentProjectId: nil)
            try context.database.dbQueue.write { db in
                try db.execute(sql: """
                CREATE TRIGGER fail_project_rename
                BEFORE UPDATE OF leafName ON projects
                BEGIN
                    SELECT RAISE(ABORT, 'forced rename failure');
                END
                """)
            }

            #expect(throws: (any Error).self) {
                try context.service.renameProject(id: project.id, newLeafName: "Renamed")
            }
            #expect(try context.repository.fetchProject(id: project.id)?.name == "Original")
            #expect(FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Original").path))
            #expect(!FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Renamed").path))
        }
    }

    extension ProjectWorkspaceServiceTests {
        @Test
        func movesStoredSummaryWithMeeting() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let source = try context.service.createProject(leafName: "Source", parentProjectId: nil)
            let destination = try context.service.createProject(leafName: "Destination", parentProjectId: nil)
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

            let source = try context.service.createProject(leafName: "Source", parentProjectId: nil)
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

            let source = try context.service.createProject(leafName: "Source", parentProjectId: nil)
            let destination = try context.service.createProject(leafName: "Destination", parentProjectId: nil)
            let meeting = try insertMeeting(projectId: source.id, context: context)
            try insertSummary(meetingId: meeting.id, path: "Source/Missing.md", context: context)

            try context.service.moveMeeting(id: meeting.id, toProjectId: destination.id)

            let movedMeeting = try context.database.dbQueue.read { db in
                try MeetingRecord.fetchOne(db, key: meeting.id)
            }
            #expect(movedMeeting?.projectId == destination.id)
            #expect(try context.repository.fetchSummaryVaultRelativePath(forMeetingId: meeting.id) == nil)
        }

        @Test
        func doesNotMoveSummaryThroughProjectSymlinkOutsideVault() throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let source = try context.service.createProject(leafName: "Source", parentProjectId: nil)
            let destination = try context.service.createProject(leafName: "Destination", parentProjectId: nil)
            let meeting = try insertMeeting(projectId: source.id, context: context)
            let sourceURL = context.vaultURL.appending(path: "Source", directoryHint: .isDirectory)
            let outsideURL = context.rootURL.appending(path: "Outside", directoryHint: .isDirectory)
            try FileManager.default.removeItem(at: sourceURL)
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

            let source = try context.service.createProject(leafName: "Source", parentProjectId: nil)
            let destination = try context.service.createProject(leafName: "Destination", parentProjectId: nil)
            let meeting = try insertMeeting(projectId: source.id, context: context)
            try insertSummary(
                meetingId: meeting.id,
                path: "Source/Summary.md",
                context: context,
                writeFile: true
            )
            let destinationURL = context.vaultURL.appending(path: "Destination", directoryHint: .isDirectory)
            let outsideURL = context.rootURL.appending(path: "Outside", directoryHint: .isDirectory)
            try FileManager.default.removeItem(at: destinationURL)
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

            let source = try context.service.createProject(leafName: "Source", parentProjectId: nil)
            let destination = try context.service.createProject(leafName: "Destination", parentProjectId: nil)
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

            let source = try context.service.createProject(leafName: "Source", parentProjectId: nil)
            let destination = try context.service.createProject(leafName: "Destination", parentProjectId: nil)
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

            let source = try context.service.createProject(leafName: "Source", parentProjectId: nil)
            let destination = try context.service.createProject(leafName: "Destination", parentProjectId: nil)
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

            let source = try context.service.createProject(leafName: "Source", parentProjectId: nil)
            let destination = try context.service.createProject(leafName: "Destination", parentProjectId: nil)
            let meeting = try insertMeeting(projectId: source.id, context: context)
            try insertSummary(
                meetingId: meeting.id,
                path: "Source/Summary.md",
                context: context,
                writeFile: true
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

            let firstSource = try context.service.createProject(leafName: "First", parentProjectId: nil)
            let secondSource = try context.service.createProject(leafName: "Second", parentProjectId: nil)
            let destination = try context.service.createProject(leafName: "Destination", parentProjectId: nil)
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

            let source = try context.service.createProject(leafName: "Source", parentProjectId: nil)
            let destination = try context.service.createProject(leafName: "Destination", parentProjectId: nil)
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

            let source = try context.service.createProject(leafName: "Source", parentProjectId: nil)
            let child = try context.service.createProject(leafName: "Child", parentProjectId: source.id)
            let destination = try context.service.createProject(leafName: "Destination", parentProjectId: nil)
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
            #expect(FileManager.default.fileExists(atPath: context.trashURL.appending(path: "Source").path))
        }

        @Test
        func movingMeetingsRelocatesSummariesOutsideDeletedHierarchy() async throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let source = try context.service.createProject(leafName: "Source", parentProjectId: nil)
            let destination = try context.service.createProject(leafName: "Destination", parentProjectId: nil)
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

            let source = try context.service.createProject(leafName: "Source", parentProjectId: nil)
            let meeting = try insertMeeting(projectId: source.id, context: context)
            try insertSummary(meetingId: meeting.id, path: "Source/Summary.md", context: context)
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
        }

        @Test
        func rejectsDeleteWhileBatchTranscriptionReadsSegmentedAudio() async throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let project = try context.service.createProject(leafName: "Project", parentProjectId: nil)
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
        func restoresFolderWhenDeleteDatabaseUpdateFails() async throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let project = try context.service.createProject(leafName: "Project", parentProjectId: nil)
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
            #expect(FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Project").path))
            #expect(!FileManager.default.fileExists(atPath: context.trashURL.appending(path: "Project").path))
        }

        @Test
        func restoresAudioWhenProjectDeleteDatabaseUpdateFails() async throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let project = try context.service.createProject(leafName: "Project", parentProjectId: nil)
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
        func restoresFolderAndSummaryWhenDeleteAfterMeetingMoveFails() async throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let source = try context.service.createProject(leafName: "Source", parentProjectId: nil)
            let destination = try context.service.createProject(leafName: "Destination", parentProjectId: nil)
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
            summaryFileResolver: @escaping ProjectWorkspaceService.SummaryFileResolver = ProjectWorkspaceService.resolveSummaryFile
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
                summaryFileResolver: summaryFileResolver
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
                try Data("Summary".utf8).write(to: context.vaultURL.appending(path: path), options: .atomic)
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
