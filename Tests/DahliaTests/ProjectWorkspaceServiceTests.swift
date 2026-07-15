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

        @Test(arguments: ["", ".hidden", "_internal", "a/b", "a:b", ".."])
        func rejectsInvalidLeafNames(name: String) throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            #expect(throws: ProjectWorkspaceError.self) {
                try context.service.createProject(leafName: name, parentProjectId: nil)
            }
            #expect(try context.repository.fetchAllProjects(vaultId: context.vault.id).isEmpty)
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
            try context.repository.updateProjectDescription(id: child.id, description: "Keep me")
            let meeting = try insertMeeting(projectId: child.id, context: context)
            try insertSummary(meetingId: meeting.id, path: "Original/Child/Summary.md", context: context)

            let renamed = try context.service.renameProject(id: parent.id, newLeafName: "Renamed")

            let fetchedChildRecord = try context.repository.fetchProject(id: child.id)
            let fetchedSummary = try context.repository.fetchSummary(forMeetingId: meeting.id)
            let vaultExport = try context.repository.fetchSummaryExport(
                forMeetingId: meeting.id,
                type: .vault
            )
            let fetchedChild = try #require(fetchedChildRecord)
            let summary = try #require(fetchedSummary)
            #expect(renamed.name == "Renamed")
            #expect(fetchedChild.name == "Renamed/Child")
            #expect(fetchedChild.description == "Keep me")
            #expect(summary.vaultRelativePath == "Renamed/Child/Summary.md")
            #expect(vaultExport?.url == "vault:///Renamed/Child/Summary.md")
            #expect(vaultExport?.vaultRelativePath == "Renamed/Child/Summary.md")
            #expect(FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Renamed/Child").path))
            #expect(!FileManager.default.fileExists(atPath: context.vaultURL.appending(path: "Original").path))
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
                BEFORE UPDATE OF name ON projects
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

        @Test
        func deletesHierarchyAfterMovingMeetings() async throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let source = try context.service.createProject(leafName: "Source", parentProjectId: nil)
            let child = try context.service.createProject(leafName: "Child", parentProjectId: source.id)
            let destination = try context.service.createProject(leafName: "Destination", parentProjectId: nil)
            let meeting = try insertMeeting(projectId: child.id, context: context)
            try insertSummary(meetingId: meeting.id, path: "Source/Child/Summary.md", context: context)
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
            #expect(summary.vaultRelativePath == nil)
            #expect(vaultExport == nil)
            #expect(summary.summary == "Body")
            #expect(try context.repository.fetchSegments(forMeetingId: meeting.id).count == 1)
            #expect(try context.repository.fetchTagsForMeeting(id: meeting.id).map(\.name) == ["important"])
            #expect(FileManager.default.fileExists(atPath: audioURL.path))
            #expect(try context.repository.fetchProject(id: source.id) == nil)
            #expect(try context.repository.fetchProject(id: child.id) == nil)
            #expect(FileManager.default.fileExists(atPath: context.trashURL.appending(path: "Source").path))
        }

        @Test
        func movingMeetingsPreservesSummaryPathsOutsideDeletedHierarchy() async throws {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.rootURL) }

            let source = try context.service.createProject(leafName: "Source", parentProjectId: nil)
            let destination = try context.service.createProject(leafName: "Destination", parentProjectId: nil)
            let meeting = try insertMeeting(projectId: source.id, context: context)
            try insertSummary(meetingId: meeting.id, path: "Archive/Summary.md", context: context)

            try await context.service.deleteProjectHierarchy(id: source.id, meetingDisposition: .move(to: destination.id))

            let fetchedSummary = try context.repository.fetchSummary(forMeetingId: meeting.id)
            let summary = try #require(fetchedSummary)
            #expect(summary.vaultRelativePath == "Archive/Summary.md")
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
    }

    private extension ProjectWorkspaceServiceTests {
        private func makeContext() throws -> ProjectWorkspaceTestContext {
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
                }
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
            context: ProjectWorkspaceTestContext
        ) throws {
            try context.repository.upsertSummary(
                SummaryRecord(
                    meetingId: meetingId,
                    title: "Summary",
                    summary: "Body",
                    vaultRelativePath: path,
                    createdAt: .now
                )
            )
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
                maximumActiveSegmentByteCount: 64 * 1_024 * 1_024,
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
