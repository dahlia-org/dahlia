import Foundation
import GRDB
import ImageIO
@testable import Dahlia
@testable import DahliaMeetingAccess
@testable import DahliaRuntimeSupport

// swiftlint:disable file_length
#if canImport(Testing)
    import Testing

    @MainActor
    // swiftlint:disable:next type_body_length
    struct MeetingAccessStoreTests {
        @Test
        func projectWorkspaceReadAndWriteOperationsEnforceHierarchyTypeAndRevision() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)

            let initial = try store.queryProjects()
            let root = try #require(initial.projects.first(where: { $0.projectID == fixture.primaryProjectID }))
            #expect(root.path == "Acme")
            #expect(root.explicitType == .undefined)
            #expect(root.effectiveType == .undefined)
            #expect(root.directMeetingCount == 2)
            #expect(throws: MeetingAccessError.projectNotFound) {
                try store.createProject(
                    name: "Cross Vault",
                    parentProjectID: fixture.otherVaultProjectID,
                    projectType: nil
                )
            }

            let created = try store.createProject(
                name: "Platform",
                parentProjectID: root.projectID,
                projectType: nil,
                description: "Platform work"
            )
            #expect(created.project.path == "Acme/Platform")
            #expect(created.project.isTypeInherited)
            #expect(!FileManager.default.fileExists(
                atPath: fixture.primaryVaultURL.appending(path: "Acme/Platform").path
            ))
            #expect(throws: MeetingAccessError.projectHierarchyTooDeep) {
                try store.createProject(
                    name: "API",
                    parentProjectID: created.project.projectID,
                    projectType: nil
                )
            }
            let otherRoot = try store.createProject(
                name: "Internal",
                parentProjectID: nil,
                projectType: .internal
            )
            #expect(throws: MeetingAccessError.projectHierarchyTooDeep) {
                try store.updateProject(
                    id: root.projectID,
                    update: ProjectUpdate(
                        parent: .project(otherRoot.project.projectID),
                        expectedRevision: root.revision
                    )
                )
            }

            #expect(throws: MeetingAccessError.projectTypeOwnedByRoot) {
                try store.updateProject(
                    id: created.project.projectID,
                    update: ProjectUpdate(projectType: .personal, expectedRevision: created.project.revision)
                )
            }
            #expect(throws: MeetingAccessError.projectConflict("expected revision 999, current revision 1")) {
                try store.updateProject(
                    id: created.project.projectID,
                    update: ProjectUpdate(name: "Renamed", expectedRevision: 999)
                )
            }

            let reparented = try store.updateProject(
                id: created.project.projectID,
                update: ProjectUpdate(
                    parent: .project(otherRoot.project.projectID),
                    expectedRevision: created.project.revision
                )
            )
            #expect(reparented.project.path == "Internal/Platform")
            #expect(reparented.project.effectiveType == .internal)
            #expect(reparented.project.isTypeInherited)
            #expect(reparented.effectiveTypeChangedProjectIDs == [created.project.projectID])

            let promoted = try store.updateProject(
                id: created.project.projectID,
                update: ProjectUpdate(parent: .vaultRoot, expectedRevision: reparented.project.revision)
            )
            #expect(promoted.project.projectID == created.project.projectID)
            #expect(promoted.project.path == "Platform")
            #expect(promoted.project.explicitType == .internal)
            #expect(!promoted.project.isTypeInherited)
        }

        @Test
        func meetingMembershipBatchRejectsOneConflictWithoutPartialUpdates() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            let destination = try store.createProject(
                name: "Destination",
                parentProjectID: nil,
                projectType: .internal
            )
            let outsideURL = fixture.rootURL.appending(path: "membership-external", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(
                at: fixture.primaryVaultURL.appending(path: "Destination", directoryHint: .isDirectory),
                withDestinationURL: outsideURL
            )
            try fixture.manager.dbQueue.write { db in
                try SummaryExportRecord(
                    meetingId: fixture.firstMeetingID,
                    type: .vault,
                    url: "vault:///Acme/Missing.md",
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
            }

            #expect(throws: MeetingAccessError.meetingMembershipConflict) {
                try store.setMeetingProjectMemberships(
                    [
                        .init(
                            meetingID: fixture.firstMeetingID,
                            expectedProjectID: fixture.primaryProjectID
                        ),
                        .init(
                            meetingID: fixture.recurringMeetingID,
                            expectedProjectID: fixture.primaryProjectID
                        ),
                    ],
                    projectID: destination.project.projectID
                )
            }
            #expect(try store.meeting(id: fixture.firstMeetingID).meeting.projectID == fixture.primaryProjectID)
            #expect(try store.meeting(id: fixture.recurringMeetingID).meeting.projectID == nil)

            let moved = try store.setMeetingProjectMemberships(
                [
                    .init(meetingID: fixture.firstMeetingID, expectedProjectID: fixture.primaryProjectID),
                    .init(meetingID: fixture.recurringMeetingID, expectedProjectID: nil),
                ],
                projectID: destination.project.projectID
            )
            #expect(moved.changed)
            #expect(Set(moved.changedMeetingIDs) == [fixture.firstMeetingID, fixture.recurringMeetingID])
            #expect(try store.meeting(id: fixture.firstMeetingID).meeting.projectID == destination.project.projectID)
            #expect(try store.meeting(id: fixture.recurringMeetingID).meeting.projectID == destination.project.projectID)
            let unchanged = try store.setMeetingProjectMemberships(
                [
                    .init(meetingID: fixture.firstMeetingID, expectedProjectID: destination.project.projectID),
                    .init(meetingID: fixture.recurringMeetingID, expectedProjectID: destination.project.projectID),
                ],
                projectID: destination.project.projectID
            )
            #expect(!unchanged.changed)
            #expect(unchanged.changedMeetingIDs.isEmpty)
            let staleExportCount = try fixture.manager.dbQueue.read { db in
                try SummaryExportRecord
                    .filter(Column("meetingId") == fixture.firstMeetingID)
                    .filter(Column("type") == SummaryExportType.vault)
                    .fetchCount(db)
            }
            #expect(staleExportCount == 0)
            #expect(!FileManager.default.fileExists(atPath: outsideURL.appending(path: "Missing.md").path))
        }

        @Test
        func meetingMembershipNeverMovesDirectoryReferencedAsSummary() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            let destination = try store.createProject(
                name: "Destination",
                parentProjectID: nil,
                projectType: .internal
            )
            try fixture.manager.dbQueue.write { db in
                try SummaryExportRecord(
                    meetingId: fixture.firstMeetingID,
                    type: .vault,
                    url: "vault:///Acme",
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
            }

            let result = try store.setMeetingProjectMemberships(
                [.init(meetingID: fixture.firstMeetingID, expectedProjectID: fixture.primaryProjectID)],
                projectID: destination.project.projectID
            )

            #expect(result.changed)
            #expect(FileManager.default.fileExists(atPath: fixture.primaryVaultURL.appending(path: "Acme").path))
            #expect(!FileManager.default.fileExists(
                atPath: fixture.primaryVaultURL.appending(path: "Destination/Acme").path
            ))
            let exportCount = try fixture.manager.dbQueue.read { db in
                try SummaryExportRecord
                    .filter(Column("meetingId") == fixture.firstMeetingID)
                    .filter(Column("type") == SummaryExportType.vault)
                    .fetchCount(db)
            }
            #expect(exportCount == 0)
        }

        @Test
        func meetingMembershipRejectsVaultExportPathOutsideScopedVault() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            try fixture.manager.dbQueue.write { db in
                try SummaryExportRecord(
                    meetingId: fixture.firstMeetingID,
                    type: .vault,
                    url: "vault:///../../Outside.md",
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
            }

            #expect(throws: MeetingAccessError.projectFileConflict(
                fixture.primaryVaultURL.appending(path: "../../Outside.md").standardizedFileURL.path
            )) {
                try store.setMeetingProjectMemberships(
                    [.init(meetingID: fixture.firstMeetingID, expectedProjectID: fixture.primaryProjectID)],
                    projectID: nil
                )
            }
            #expect(try store.meeting(id: fixture.firstMeetingID).meeting.projectID == fixture.primaryProjectID)
            let export = try fixture.manager.dbQueue.read { db in
                try SummaryExportRecord.fetchOne(
                    meetingId: fixture.firstMeetingID,
                    type: .vault,
                    in: db
                )
            }
            #expect(export?.url == "vault:///../../Outside.md")
        }

        @Test
        func projectMutationWithoutTrackedSummaryDoesNotTouchSourceSymlink() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            let project = try #require(try store.queryProjects(ProjectQuery(
                projectID: fixture.primaryProjectID
            )).projects.first)
            let external = fixture.rootURL.appending(path: "external", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
            let projectURL = fixture.primaryVaultURL.appending(path: "Acme", directoryHint: .isDirectory)
            try FileManager.default.removeItem(at: projectURL)
            try FileManager.default.createSymbolicLink(at: projectURL, withDestinationURL: external)

            let renamed = try store.updateProject(
                id: project.projectID,
                update: ProjectUpdate(name: "Renamed", expectedRevision: project.revision)
            )

            #expect(renamed.project.path == "Renamed")
            #expect(FileManager.default.fileExists(atPath: external.path))
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: projectURL.path) == external.path)
        }

        @Test
        func projectSiblingIdentityNormalizesUnicodeAndCase() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            _ = try store.createProject(
                name: "Équipe",
                parentProjectID: nil,
                projectType: .customer
            )

            #expect(throws: MeetingAccessError.projectAlreadyExists("e\u{301}QUIPE")) {
                try store.createProject(
                    name: "e\u{301}QUIPE",
                    parentProjectID: nil,
                    projectType: .customer
                )
            }
        }

        @Test
        func projectCreateRejectsDuplicateSiblingWithoutFilesystemMutation() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            try FileManager.default.removeItem(at: fixture.primaryVaultURL.appending(path: "Acme"))

            #expect(throws: MeetingAccessError.projectAlreadyExists("acme")) {
                try store.createProject(
                    name: "acme",
                    parentProjectID: nil,
                    projectType: .customer
                )
            }
            #expect(!FileManager.default.fileExists(atPath: fixture.primaryVaultURL.appending(path: "acme").path))
        }

        @Test
        func projectMutationReportsVaultLockConflict() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)

            _ = try DahliaVaultMutationLock.withLock(
                vaultURL: fixture.primaryVaultURL,
                vaultID: fixture.primaryVaultID
            ) {
                #expect(throws: MeetingAccessError.workspaceBusy) {
                    try store.createProject(
                        name: "Blocked",
                        parentProjectID: nil,
                        projectType: .undefined
                    )
                }
            }
            #expect(!FileManager.default.fileExists(
                atPath: fixture.primaryVaultURL.appending(path: "Blocked").path
            ))
        }

        @Test
        func projectUpdateRollsSummaryBackWhenDatabaseCommitFails() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            let project = try #require(try store.queryProjects(ProjectQuery(
                projectID: fixture.primaryProjectID
            )).projects.first)
            let sourceSummary = fixture.primaryVaultURL.appending(path: "Acme/Summary.md")
            try Data("Summary".utf8).write(to: sourceSummary, options: .atomic)
            try fixture.manager.dbQueue.write { db in
                try SummaryExportRecord(
                    meetingId: fixture.firstMeetingID,
                    type: .vault,
                    url: "vault:///Acme/Summary.md",
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
                try db.execute(sql: """
                CREATE TRIGGER fail_mcp_project_update
                BEFORE UPDATE OF name ON projects
                BEGIN
                    SELECT RAISE(ABORT, 'forced MCP update failure');
                END
                """)
            }

            #expect(throws: (any Error).self) {
                try store.updateProject(
                    id: project.projectID,
                    update: ProjectUpdate(name: "Renamed", expectedRevision: project.revision)
                )
            }
            #expect(FileManager.default.fileExists(atPath: sourceSummary.path))
            #expect(!FileManager.default.fileExists(atPath: fixture.primaryVaultURL.appending(path: "Renamed").path))
        }

        @Test
        func projectRenameMovesAlignedSummaryAndLeavesLegacyOutputUntouched() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            let root = try #require(try store.queryProjects(ProjectQuery(
                projectID: fixture.primaryProjectID
            )).projects.first)
            let child = try store.createProject(
                name: "Platform",
                parentProjectID: root.projectID,
                projectType: nil
            ).project
            let alignedSummary = fixture.primaryVaultURL.appending(path: "Acme/Summary.md")
            let legacyDirectory = fixture.primaryVaultURL.appending(path: "Legacy", directoryHint: .isDirectory)
            let legacySummary = legacyDirectory.appending(path: "Budget.md")
            let unrelatedFile = fixture.primaryVaultURL.appending(path: "Acme/keep.txt")
            try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: false)
            try Data("Aligned".utf8).write(to: alignedSummary, options: .atomic)
            try Data("Legacy".utf8).write(to: legacySummary, options: .atomic)
            try Data("Keep".utf8).write(to: unrelatedFile, options: .atomic)
            try fixture.manager.dbQueue.write { db in
                try SummaryRecord(
                    meetingId: fixture.secondMeetingID,
                    title: "Budget",
                    document: "{}",
                    createdAt: .now
                ).insert(db)
                for (meetingID, path) in [
                    (fixture.firstMeetingID, "vault:///Acme/Summary.md"),
                    (fixture.secondMeetingID, "vault:///Legacy/Budget.md"),
                ] {
                    try SummaryExportRecord(
                        meetingId: meetingID,
                        type: .vault,
                        url: path,
                        createdAt: .now,
                        updatedAt: .now
                    ).insert(db)
                }
            }

            let result = try store.updateProject(
                id: root.projectID,
                update: ProjectUpdate(name: "Renamed", expectedRevision: root.revision)
            )

            #expect(Set(result.affectedProjectIDs) == [root.projectID, child.projectID])
            let updatedChild = try #require(try store.queryProjects(ProjectQuery(
                projectID: child.projectID
            )).projects.first)
            #expect(updatedChild.path == "Renamed/Platform")
            #expect(updatedChild.revision == child.revision + 1)
            #expect(FileManager.default.fileExists(
                atPath: fixture.primaryVaultURL.appending(path: "Renamed/Summary.md").path
            ))
            #expect(FileManager.default.fileExists(atPath: legacySummary.path))
            #expect(FileManager.default.fileExists(atPath: unrelatedFile.path))
            let paths = try fixture.manager.dbQueue.read { db in
                try [
                    SummaryExportRecord.fetchOne(
                        meetingId: fixture.firstMeetingID,
                        type: .vault,
                        in: db
                    )?.vaultRelativePath,
                    SummaryExportRecord.fetchOne(
                        meetingId: fixture.secondMeetingID,
                        type: .vault,
                        in: db
                    )?.vaultRelativePath,
                ]
            }
            #expect(paths == ["Renamed/Summary.md", "Legacy/Budget.md"])
        }

        @Test
        func projectRenameRejectsSummarySharedWithRetainedLegacyExport() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            let root = try #require(try store.queryProjects(ProjectQuery(
                projectID: fixture.primaryProjectID
            )).projects.first)
            let child = try store.createProject(
                name: "Child",
                parentProjectID: root.projectID,
                projectType: nil
            ).project
            let sharedSummary = fixture.primaryVaultURL.appending(path: "Acme/Shared.md")
            try Data("Shared".utf8).write(to: sharedSummary, options: .atomic)
            try fixture.manager.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE meetings SET projectId = ? WHERE id = ?",
                    arguments: [child.projectID, fixture.secondMeetingID]
                )
                try SummaryRecord(
                    meetingId: fixture.secondMeetingID,
                    title: "Shared",
                    document: "{}",
                    createdAt: .now
                ).insert(db)
                for meetingID in [fixture.firstMeetingID, fixture.secondMeetingID] {
                    try SummaryExportRecord(
                        meetingId: meetingID,
                        type: .vault,
                        url: "vault:///Acme/Shared.md",
                        createdAt: .now,
                        updatedAt: .now
                    ).insert(db)
                }
            }

            #expect(throws: MeetingAccessError.projectFileConflict(sharedSummary.path)) {
                try store.updateProject(
                    id: root.projectID,
                    update: ProjectUpdate(name: "Renamed", expectedRevision: root.revision)
                )
            }

            #expect(try store.queryProjects(ProjectQuery(projectID: root.projectID)).projects.first?.path == "Acme")
            #expect(FileManager.default.fileExists(atPath: sharedSummary.path))
            #expect(!FileManager.default.fileExists(
                atPath: fixture.primaryVaultURL.appending(path: "Renamed/Shared.md").path
            ))
        }

        @Test
        func querySearchesMetadataPaginatesAndNeverCrossesVaults() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID)

            let firstPage = try store.queryMeetings(MeetingQuery(limit: 2))
            #expect(firstPage.vault.id == fixture.primaryVaultID)
            #expect(firstPage.meetings.count == 2)
            let cursor = try #require(firstPage.nextCursor)
            let secondPage = try store.queryMeetings(MeetingQuery(limit: 2, cursor: cursor))
            #expect(secondPage.meetings.count == 1)
            #expect(Set(firstPage.meetings.map(\.id) + secondPage.meetings.map(\.id)) == fixture.primaryMeetingIDs)

            let calendarMatch = try store.queryMeetings(MeetingQuery(query: "Roadmap"))
            #expect(calendarMatch.meetings.map(\.id) == [fixture.firstMeetingID])
            let descriptionMatch = try store.queryMeetings(MeetingQuery(query: "planning decisions"))
            #expect(descriptionMatch.meetings.map(\.id) == [fixture.firstMeetingID])
            let tagMatch = try store.queryMeetings(MeetingQuery(query: "launch-tag"))
            #expect(tagMatch.meetings.map(\.id) == [fixture.firstMeetingID])
            let literalWildcardMatch = try store.queryMeetings(MeetingQuery(query: "%"))
            #expect(literalWildcardMatch.meetings.map(\.id) == [fixture.secondMeetingID])
            #expect(try store.queryMeetings(MeetingQuery(query: "_")).meetings.isEmpty)
            let projectMatch = try store.queryMeetings(MeetingQuery(project: "Acme"))
            #expect(projectMatch.meetings.count == 2)
            let projectIDMatch = try store.queryMeetings(MeetingQuery(projectID: fixture.primaryProjectID))
            #expect(Set(projectIDMatch.meetings.map(\.id)) == fixture.projectMeetingIDs)
            #expect(Set(projectIDMatch.meetings.compactMap(\.icalUID)) == ["roadmap@example.com", "budget@example.com"])
            let icalUIDMatch = try store.queryMeetings(MeetingQuery(icalUID: " roadmap@example.com "))
            #expect(icalUIDMatch.meetings.map(\.id) == [fixture.firstMeetingID, fixture.recurringMeetingID])
            #expect(try store.queryMeetings(MeetingQuery(
                projectID: fixture.primaryProjectID,
                icalUID: "missing@example.com"
            )).meetings.isEmpty)
            #expect(try store.queryMeetings(MeetingQuery(projectID: fixture.otherVaultProjectID)).meetings.isEmpty)
            #expect(try store.queryMeetings(MeetingQuery(query: "secret body")).meetings.isEmpty)
            #expect(!firstPage.meetings.contains { $0.id == fixture.otherVaultMeetingID })

            let otherStore = try fixture.store(vaultID: fixture.otherVaultID)
            #expect(throws: MeetingAccessError.invalidCursor) {
                try otherStore.queryMeetings(MeetingQuery(cursor: cursor))
            }
        }

        @Test
        func meetingReturnsSummaryAndCrossVaultIDsAreNotFound() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID)

            let detail = try store.meeting(id: fixture.firstMeetingID)
            #expect(detail.meeting.name == "AI planning title")
            #expect(detail.meeting.description == "Product planning decisions")
            #expect(detail.meeting.projectID == fixture.primaryProjectID)
            #expect(detail.meeting.icalUID == "roadmap@example.com")
            #expect(detail.meeting.recurrenceID?.isEmpty == true)
            #expect(detail.meeting.calendarTitle == "Roadmap review")
            #expect(detail.summary?.contains("Markdown secret body [Transcript 00:00:15]") == true)
            #expect(detail.summary?.contains("[Screenshot \(fixture.firstScreenshotID.uuidString) at 00:00:16]") == true)
            guard case let .object(document)? = detail.summaryDocument,
                  case let .array(sections)? = document["sections"],
                  case let .object(section)? = sections.first,
                  case let .array(blocks)? = section["blocks"],
                  case let .object(paragraph)? = blocks.first,
                  case let .object(content)? = paragraph["content"] else {
                Issue.record("Expected a structured summary document")
                return
            }
            #expect(content["transcript_ref"] == .string("00:00:15"))
            #expect(document["schema_version"] == .number(3))
            #expect(document["schemaVersion"] == nil)
            #expect(section["id"] != nil)
            #expect(paragraph["id"] != nil)
            #expect(detail.meeting.transcriptSegmentCount == 2)
            #expect(try store.meeting(id: fixture.secondMeetingID).summary == nil)
            #expect(throws: MeetingAccessError.meetingNotFound) {
                try store.meeting(id: fixture.otherVaultMeetingID)
            }
        }

        @Test
        func transcriptReturnsOnlyConfirmedOriginalTextAndSessionElapsedTime() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID)

            let firstPage = try store.transcript(meetingID: fixture.firstMeetingID, limit: 1)
            let cursor = try #require(firstPage.nextCursor)
            let secondPage = try store.transcript(
                meetingID: fixture.firstMeetingID,
                limit: 1,
                cursor: cursor
            )
            let segments = firstPage.segments + secondPage.segments
            let segment = try #require(segments.first(where: { $0.id == fixture.firstSegmentID }))
            #expect(segment.text == "Original secret body")
            #expect(segment.speaker == "mic")
            #expect(segment.elapsedSeconds == 15)
            #expect(segment.endedElapsedSeconds == 17)
            #expect(segment.timestamp == "00:00:15")
            #expect(Set(segments.map(\.id)) == [fixture.firstSegmentID, fixture.secondSegmentID])
            #expect(secondPage.nextCursor == nil)
            #expect(throws: MeetingAccessError.invalidCursor) {
                try store.transcript(meetingID: fixture.secondMeetingID, cursor: cursor)
            }
            #expect(throws: MeetingAccessError.meetingNotFound) {
                try store.transcript(meetingID: fixture.otherVaultMeetingID)
            }

            let range = try store.transcript(
                meetingID: fixture.firstMeetingID,
                fromElapsedSeconds: 15,
                toElapsedSeconds: 16,
                limit: 1
            )
            #expect(range.segments.count == 1)
            #expect(try store.transcript(
                meetingID: fixture.firstMeetingID,
                fromElapsedSeconds: 0,
                toElapsedSeconds: 15
            ).segments.isEmpty)
            let rangeCursor = try #require(range.nextCursor)
            #expect(throws: MeetingAccessError.invalidCursor) {
                try store.transcript(
                    meetingID: fixture.firstMeetingID,
                    fromElapsedSeconds: 14,
                    toElapsedSeconds: 16,
                    cursor: rangeCursor
                )
            }
        }

        @Test
        func transcriptEndElapsedSecondsUsesTheSamePrecisionAsStart() throws {
            let fixture = try Fixture()
            let endedAt = Date(timeIntervalSince1970: 1_800_000_007.123_456)
            try fixture.manager.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE transcript_segments SET endTime = ? WHERE id = ?",
                    arguments: [endedAt, fixture.firstSegmentID]
                )
            }

            let page = try fixture.store(vaultID: fixture.primaryVaultID).transcript(
                meetingID: fixture.firstMeetingID
            )
            let segment = try #require(page.segments.first { $0.id == fixture.firstSegmentID })
            #expect(segment.endedElapsedSeconds == 17.123)
        }

        @Test
        func screenshotsArePagedFilteredAndReturnedOneAtATimeAsResizedImages() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID)

            let firstPage = try store.screenshots(
                meetingID: fixture.firstMeetingID,
                query: ScreenshotQuery(limit: 1)
            )
            #expect(firstPage.screenshots.count == 1)
            #expect(firstPage.nextCursor != nil)
            let secondPage = try store.screenshots(
                meetingID: fixture.firstMeetingID,
                query: ScreenshotQuery(limit: 1, cursor: firstPage.nextCursor)
            )
            #expect(Set((firstPage.screenshots + secondPage.screenshots).map(\.id)) == fixture.primaryScreenshotIDs)

            let filtered = try store.screenshots(
                meetingID: fixture.firstMeetingID,
                query: ScreenshotQuery(fromElapsedSeconds: 15, toElapsedSeconds: 17)
            )
            #expect(filtered.screenshots.map(\.id) == [fixture.firstScreenshotID])
            #expect(filtered.screenshots.first?.timestamp == "00:00:16")
            #expect(filtered.screenshots.first?.isReferencedInSummary == true)
            #expect(try store.screenshots(
                meetingID: fixture.firstMeetingID,
                query: ScreenshotQuery(fromElapsedSeconds: 15, toElapsedSeconds: 16)
            ).screenshots.isEmpty)

            let rangedPage = try store.screenshots(
                meetingID: fixture.firstMeetingID,
                query: ScreenshotQuery(fromElapsedSeconds: 0, toElapsedSeconds: 100, limit: 1)
            )
            let rangedCursor = try #require(rangedPage.nextCursor)
            #expect(throws: MeetingAccessError.invalidCursor) {
                try store.screenshots(
                    meetingID: fixture.firstMeetingID,
                    query: ScreenshotQuery(fromElapsedSeconds: 0, toElapsedSeconds: 99, cursor: rangedCursor)
                )
            }

            let image = try store.screenshot(
                meetingID: fixture.firstMeetingID,
                screenshotID: fixture.firstScreenshotID
            )
            #expect(image.imageData != fixture.imageData)
            #expect(["image/webp", "image/jpeg"].contains(image.mimeType))
            let source = CGImageSourceCreateWithData(image.imageData as CFData, nil)
            let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
            #expect((properties?[kCGImagePropertyPixelWidth] as? Int ?? 0) <= 1024)
            #expect((properties?[kCGImagePropertyPixelHeight] as? Int ?? 0) <= 1024)
            #expect(throws: MeetingAccessError.screenshotNotFound) {
                try store.screenshot(meetingID: fixture.firstMeetingID, screenshotID: fixture.otherVaultScreenshotID)
            }
        }

        @Test
        func screenshotImagesAreActuallyDownsampledAndRejectCorruptData() throws {
            let fixture = try Fixture()
            let largeImage = try #require(Self.makeImage(width: 2048, height: 512))
            let largeData = try #require(ImageEncoder.encode(largeImage, quality: 0.9))
            try fixture.updateFirstScreenshot(data: largeData)
            let store = try fixture.store(vaultID: fixture.primaryVaultID)

            let image = try store.screenshot(meetingID: fixture.firstMeetingID, screenshotID: fixture.firstScreenshotID)
            let source = try #require(CGImageSourceCreateWithData(image.imageData as CFData, nil))
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            #expect(properties[kCGImagePropertyPixelWidth] as? Int == 1024)
            #expect(properties[kCGImagePropertyPixelHeight] as? Int == 256)

            try fixture.updateFirstScreenshot(data: Data("not an image".utf8))
            #expect(throws: MeetingAccessError.screenshotEncodingFailed) {
                try store.screenshot(meetingID: fixture.firstMeetingID, screenshotID: fixture.firstScreenshotID)
            }

            let range = try store.screenshotImages(
                meetingID: fixture.firstMeetingID,
                query: ScreenshotQuery(fromElapsedSeconds: 0, toElapsedSeconds: 100)
            )
            #expect(range.images.map(\.metadata.id) == [fixture.secondScreenshotID])
            #expect(range.page.screenshots.map(\.id) == [fixture.secondScreenshotID])
        }

        @Test
        func elapsedTimelineUsesOffsetsAcrossPausedRecordingSessions() throws {
            let fixture = try Fixture()
            let inserted = try fixture.insertPausedSessionContent()
            let store = try fixture.store(vaultID: fixture.primaryVaultID)

            let transcript = try store.transcript(
                meetingID: fixture.firstMeetingID,
                fromElapsedSeconds: 35,
                toElapsedSeconds: 36
            )
            #expect(transcript.segments.map(\.id) == [inserted.segmentID])
            #expect(transcript.segments.first?.timestamp == "00:00:35")

            let screenshots = try store.screenshots(
                meetingID: fixture.firstMeetingID,
                query: ScreenshotQuery(fromElapsedSeconds: 36, toElapsedSeconds: 37)
            )
            #expect(screenshots.screenshots.map(\.id) == [inserted.screenshotID])
            #expect(screenshots.screenshots.first?.timestamp == "00:00:36")
        }

        @Test
        func relatedRecordsCannotCrossTheVaultBoundary() throws {
            let fixture = try Fixture()
            try fixture.corruptPrimaryProjectAssociation()
            try fixture.corruptPrimarySessionAssociation()
            try fixture.corruptPrimaryScreenshotSessionAssociation()
            let store = try fixture.store(vaultID: fixture.primaryVaultID)

            let detail = try store.meeting(id: fixture.firstMeetingID)
            #expect(detail.meeting.project == nil)
            #expect(detail.meeting.projectID == nil)
            #expect(try store.queryMeetings(MeetingQuery(query: "Other vault project")).meetings.isEmpty)
            #expect(try store.queryMeetings(MeetingQuery(projectID: fixture.otherVaultProjectID)).meetings.isEmpty)
            let transcript = try store.transcript(meetingID: fixture.firstMeetingID)
            let segment = try #require(transcript.segments.first(where: { $0.id == fixture.firstSegmentID }))
            #expect(segment.elapsedSeconds == 0)
            let screenshots = try store.screenshots(meetingID: fixture.firstMeetingID)
            #expect(screenshots.screenshots.first(where: { $0.id == fixture.firstScreenshotID })?.elapsedSeconds == 0)
        }

        @Test
        // swiftlint:disable:next function_body_length
        func customerIntelligenceAccessIsVaultScopedAndResolvesTypedReferences() throws {
            let fixture = try Fixture()
            let repository = MeetingRepository(dbQueue: fixture.manager.dbQueue)
            let organization = try repository.createOrganization(
                vaultId: fixture.primaryVaultID,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Acme",
                description: "Strategic customer"
            )
            let unit = try repository.createOrganization(
                vaultId: fixture.primaryVaultID,
                parentOrganizationId: organization.id,
                nodeKind: .unit,
                name: "Platform"
            )
            _ = try repository.addOrganizationDomain(
                organizationId: organization.id,
                vaultId: fixture.primaryVaultID,
                domainName: "acme.example"
            )
            let contact = try repository.upsertContact(
                vaultId: fixture.primaryVaultID,
                email: "owner@acme.example",
                displayName: "Owner"
            )
            _ = try repository.upsertContact(
                vaultId: fixture.otherVaultID,
                email: "owner@acme.example",
                displayName: "Other Owner"
            )
            _ = try repository.addOrganizationMembership(
                organizationId: unit.id,
                contactId: contact.id,
                roleLabel: "Lead"
            )
            try fixture.manager.dbQueue.write { db in
                for meetingID in [fixture.firstMeetingID, fixture.secondMeetingID] {
                    try MeetingParticipantRecord(
                        meetingId: meetingID,
                        contactId: contact.id,
                        role: .required,
                        responseStatus: .accepted,
                        source: "calendar",
                        createdAt: .now,
                        updatedAt: .now
                    ).insert(db)
                }
            }
            _ = try repository.addProjectResourceReference(
                projectId: fixture.primaryProjectID,
                resourceType: .organization,
                resourceId: organization.id,
                relationLabel: "customer"
            )
            _ = try repository.addProjectResourceReference(
                projectId: fixture.primaryProjectID,
                resourceType: .contact,
                resourceId: contact.id,
                relationLabel: "sponsor"
            )
            let insight = try repository.createInsight(
                vaultId: fixture.primaryVaultID,
                content: "Owner is the technical sponsor",
                metadataJSON: #"{"decisionMaker":"Owner","foo_bar":"kept","rank":2}"#
            )
            _ = try repository.addInsightReference(
                insightId: insight.id,
                resourceType: .contact,
                resourceId: contact.id,
                role: .evidence
            )
            let topic = try repository.createConversationTopic(
                vaultId: fixture.primaryVaultID,
                title: "Platform rollout",
                currentState: "Owner aligned",
                references: [
                    .init(resourceType: .organization, resourceID: unit.id),
                    .init(
                        resourceType: .meeting,
                        resourceID: fixture.firstMeetingID,
                        note: "Rollout owner confirmed"
                    ),
                ]
            )

            let store = try fixture.store(vaultID: fixture.primaryVaultID)
            let firstPage = try store.queryOrganizations(OrganizationAccessQuery(limit: 1))
            #expect(firstPage.organizations.count == 1)
            let cursor = try #require(firstPage.nextCursor)
            let secondPage = try store.queryOrganizations(OrganizationAccessQuery(limit: 1, cursor: cursor))
            #expect(secondPage.organizations.count == 1)
            #expect(Set((firstPage.organizations + secondPage.organizations).map(\.id)) == [
                organization.id,
                unit.id,
            ])
            let organizationDetail = try store.organization(id: organization.id)
            #expect(organizationDetail.organization.description == "Strategic customer")
            #expect(organizationDetail.domains.map(\.domainName) == ["acme.example"])
            #expect(organizationDetail.projectResources.map(\.relationLabel) == ["customer"])
            #expect(
                try store.queryOrganizations(.init(query: "Strategic customer")).organizations.map(\.id)
                    == [organization.id]
            )

            let contacts = try store.queryContacts()
            #expect(contacts.contacts.map(\.id) == [contact.id])
            let contactDetail = try store.contact(id: contact.id)
            #expect(contactDetail.memberships.map(\.organizationID) == [unit.id])
            #expect(contactDetail.projectResources.map(\.relationLabel) == ["sponsor"])
            let projectResources = try store.queryProjectResources(ProjectResourceAccessQuery(
                projectID: fixture.primaryProjectID
            ))
            #expect(Set(projectResources.resources.map(\.resourceID)) == [organization.id, contact.id])
            let insights = try store.queryInsights(InsightAccessQuery(
                resourceType: .contact,
                resourceID: contact.id
            ))
            #expect(insights.insights.map(\.id) == [insight.id])
            #expect(insights.insights.first?.references.first?.resourceName == "Owner")
            let topicPage = try store.queryConversationTopics(.init(organizationID: unit.id))
            #expect(topicPage.topics.map(\.id) == [topic.id])
            let topicDetail = try store.conversationTopic(id: topic.id)
            #expect(topicDetail.references.count == 2)
            let meetingsByTopic = try store.queryMeetings(.init(topicID: topic.id))
            #expect(meetingsByTopic.meetings.map(\.id) == [fixture.firstMeetingID])
            let meetingsByRoot = try store.queryMeetings(.init(
                organizationID: organization.id,
                includeOrganizationDescendants: true,
                limit: 1
            ))
            #expect(meetingsByRoot.meetings.count == 1)
            let organizationCursor = try #require(meetingsByRoot.nextCursor)
            #expect(throws: MeetingAccessError.invalidCursor) {
                try store.queryMeetings(.init(topicID: topic.id, limit: 1, cursor: organizationCursor))
            }

            let server = DahliaMCPServer(store: store)
            _ = try Self.json(server.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#))
            #expect(server.handleLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
            let contactCall = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"query_contacts","arguments":{"organization_id":"\#(unit
                .id.uuidString)"}}}
            """#))
            let contactContent = (contactCall["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
            #expect((contactContent?["contacts"] as? [[String: Any]])?.first?["id"] as? String == contact.id.uuidString)
            let invalidFilterCall = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"query_insights","arguments":{"resource_type":"contact"}}}
            """#))
            #expect((invalidFilterCall["error"] as? [String: Any])?["code"] as? Int == -32602)
            let insightCall = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"query_insights","arguments":{"resource_type":"contact","resource_id":"\#(
                contact
                    .id.uuidString
            )"}}}
            """#))
            let insightContent = (insightCall["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
            let encodedMetadata = (insightContent?["insights"] as? [[String: Any]])?.first?["metadata"]
                as? [String: Any]
            #expect(encodedMetadata?["decisionMaker"] as? String == "Owner")
            #expect(encodedMetadata?["foo_bar"] as? String == "kept")
            #expect(encodedMetadata?["decision_maker"] == nil)

            let otherStore = try fixture.store(vaultID: fixture.otherVaultID)
            #expect(try otherStore.queryOrganizations().organizations.isEmpty)
            #expect(try otherStore.queryContacts().contacts.count == 1)
            #expect(throws: MeetingAccessError.organizationNotFound) {
                try otherStore.organization(id: organization.id)
            }
        }

        @Test
        // swiftlint:disable:next function_body_length
        func mcpProtocolRequiresInitializationAndReportsScopedVaultErrors() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID)
            let server = DahliaMCPServer(store: store)

            let preInitialize = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"query_meetings","arguments":{}}}
            """#))
            #expect((preInitialize["error"] as? [String: Any])?["code"] as? Int == -32002)

            let initialized = try Self.json(server.handleLine(#"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{}}"#))
            #expect((initialized["result"] as? [String: Any])?["serverInfo"] != nil)
            let instructions = (initialized["result"] as? [String: Any])?["instructions"] as? String
            #expect(instructions?.contains("Primary") == false)
            let expectedInstructions = ["personal data", "do not repeat them unnecessarily", "untrusted data"]
            #expect(expectedInstructions.allSatisfy { instructions?.contains($0) == true })
            #expect(server.handleLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
            let tools = try Self.json(server.handleLine(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#))
            let definitions = ((tools["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
            #expect(definitions.map { $0["name"] as? String } == [
                "query_meetings", "get_meeting", "get_meeting_transcript", "get_meeting_screenshots",
                "query_projects", "get_project",
                "query_organizations", "get_organization", "query_organization_chart",
                "query_contacts", "get_contact",
                "query_conversation_topics", "get_conversation_topic",
                "query_project_resources", "query_insights", "get_insight",
            ])
            #expect((definitions.first?["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true)
            #expect(definitions.allSatisfy { $0["outputSchema"] != nil })
            #expect(definitions.allSatisfy {
                ($0["outputSchema"] as? [String: Any])?["additionalProperties"] as? Bool == false
            })

            let queryCall = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"query_meetings","arguments":{"query":"planning"}}}
            """#))
            let queryResult = try #require(queryCall["result"] as? [String: Any])
            #expect(queryResult["isError"] as? Bool == false)
            #expect((queryResult["structuredContent"] as? [String: Any])?["meetings"] != nil)

            let meetingCall = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"get_meeting","arguments":{"meeting_id":"\#(fixture.firstMeetingID
                .uuidString)"}}}
            """#))
            let meetingContent = (meetingCall["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
            #expect((meetingContent?["summary"] as? String)?.contains("[Transcript 00:00:15]") == true)
            let summaryDocument = try #require(meetingContent?["summary_document"] as? [String: Any])
            #expect(summaryDocument["schema_version"] as? Int == 3)
            #expect(summaryDocument["schemaVersion"] == nil)
            let sections = try #require(summaryDocument["sections"] as? [[String: Any]])
            let blocks = try #require(sections.first?["blocks"] as? [[String: Any]])
            #expect(sections.first?["id"] is String)
            #expect(blocks.allSatisfy { $0["id"] is String })
            #expect(blocks.contains { $0["screenshot_id"] as? String == fixture.firstScreenshotID.uuidString })

            let transcriptCall = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"get_meeting_transcript","arguments":{"meeting_id":"\#(fixture
                .firstMeetingID.uuidString)","limit":1}}}
            """#))
            let transcriptContent = ((transcriptCall["result"] as? [String: Any])?["structuredContent"] as? [String: Any])
            #expect(transcriptContent?["segments"] != nil)
            #expect(transcriptContent?["next_cursor"] is String)

            let screenshotCall = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"get_meeting_screenshots","arguments":{"meeting_id":"\#(fixture
                .firstMeetingID.uuidString)","screenshot_ids":["\#(fixture.firstScreenshotID.uuidString)","\#(fixture.secondScreenshotID
                .uuidString)"]}}}
            """#))
            let screenshotResult = try #require(screenshotCall["result"] as? [String: Any])
            let screenshotContent = try #require(screenshotResult["content"] as? [[String: Any]])
            #expect(screenshotContent.map { $0["type"] as? String } == ["text", "text", "image", "text", "image"])
            #expect((screenshotContent.last?["data"] as? String)?.isEmpty == false)
            let screenshotStructured = try #require(screenshotResult["structuredContent"] as? [String: Any])
            let selectedScreenshots = try #require(screenshotStructured["screenshots"] as? [[String: Any]])
            #expect(selectedScreenshots.compactMap { $0["id"] as? String } == [
                fixture.firstScreenshotID.uuidString,
                fixture.secondScreenshotID.uuidString,
            ])

            let rangedScreenshotCall = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"get_meeting_screenshots","arguments":{"meeting_id":"\#(fixture
                .firstMeetingID.uuidString)","from_elapsed_seconds":15,"to_elapsed_seconds":17}}}
            """#))
            let rangedContent = ((rangedScreenshotCall["result"] as? [String: Any])?["content"] as? [[String: Any]])
            #expect(rangedContent?.map { $0["type"] as? String } == ["text", "text", "image"])

            let missingSelector = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":15,"method":"tools/call","params":{"name":"get_meeting_screenshots","arguments":{"meeting_id":"\#(fixture
                .firstMeetingID.uuidString)"}}}
            """#))
            #expect((missingSelector["error"] as? [String: Any])?["code"] as? Int == -32602)

            let invalid = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"query_meetings","arguments":{"unexpected":true}}}
            """#))
            #expect((invalid["error"] as? [String: Any])?["code"] as? Int == -32602)
            let unknown = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"unknown","arguments":{}}}
            """#))
            #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32602)
            let nonObjectArguments = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"query_meetings","arguments":"invalid"}}
            """#))
            #expect((nonObjectArguments["error"] as? [String: Any])?["code"] as? Int == -32602)
            let invalidVersion = try Self.json(server.handleLine(#"""
            {"jsonrpc":"1.0","id":11,"method":"ping"}
            """#))
            #expect((invalidVersion["error"] as? [String: Any])?["code"] as? Int == -32600)

            let missingVaultStore = try fixture.store(vaultID: UUID.v7())
            let missingVaultServer = DahliaMCPServer(store: missingVaultStore)
            let missing = try Self.json(missingVaultServer.handleLine(#"{"jsonrpc":"2.0","id":4,"method":"initialize","params":{}}"#))
            #expect((missing["error"] as? [String: Any])?["code"] as? Int == -32000)
        }

        @Test
        // swiftlint:disable:next function_body_length
        func organizationDomainWriteToolsPreserveSharingRootAndPrimaryContracts() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            let first = try store.createOrganization(
                name: "First",
                nodeKind: .organization,
                parentOrganizationID: nil
            )
            let second = try store.createOrganization(
                name: "Second",
                nodeKind: .organization,
                parentOrganizationID: nil
            )

            let firstDomain = try store.setOrganizationDomain(
                organizationID: first.resourceID,
                expectedOrganizationRevision: first.revision,
                domainName: " Shared.Example. ",
                isPrimary: false
            )
            #expect(firstDomain.changed)
            #expect(try store.organization(id: first.resourceID).domains.first?.domainName == "shared.example")
            #expect(try store.organization(id: first.resourceID).domains.first?.isPrimary == true)

            let onlyPrimaryNoOp = try store.setOrganizationDomain(
                organizationID: first.resourceID,
                expectedOrganizationRevision: try #require(firstDomain.revision),
                domainName: "shared.example",
                isPrimary: false
            )
            #expect(!onlyPrimaryNoOp.changed)

            let secondDomain = try store.setOrganizationDomain(
                organizationID: first.resourceID,
                expectedOrganizationRevision: try #require(onlyPrimaryNoOp.revision),
                domainName: "second.example",
                isPrimary: false
            )
            _ = try store.setOrganizationDomain(
                organizationID: first.resourceID,
                expectedOrganizationRevision: try #require(secondDomain.revision),
                domainName: "alpha.example",
                isPrimary: false
            )
            try fixture.manager.dbQueue.write { db in
                try db.execute(
                    sql: """
                    UPDATE organization_domains SET firstObservedAt = ?
                    WHERE organizationId = ? AND domainName IN ('alpha.example', 'second.example')
                    """,
                    arguments: [Date(timeIntervalSince1970: 1_700_000_000), first.resourceID]
                )
            }
            let revisionAfterObservationUpdate = try store.organization(id: first.resourceID).organization.revision
            let promotedReplacement = try store.setOrganizationDomain(
                organizationID: first.resourceID,
                expectedOrganizationRevision: revisionAfterObservationUpdate,
                domainName: "shared.example",
                isPrimary: false
            )
            #expect(promotedReplacement.changed)
            let firstDomains = try store.organization(id: first.resourceID).domains
            #expect(firstDomains.count(where: \.isPrimary) == 1)
            #expect(firstDomains.first(where: \.isPrimary)?.domainName == "alpha.example")

            let shared = try store.setOrganizationDomain(
                organizationID: second.resourceID,
                expectedOrganizationRevision: second.revision,
                domainName: "shared.example",
                isPrimary: false
            )
            #expect(shared.changed)
            #expect(try store.organization(id: second.resourceID).domains.map(\.domainName) == ["shared.example"])

            #expect(throws: MeetingAccessError.customerIntelligenceRevisionConflict) {
                try store.setOrganizationDomain(
                    organizationID: second.resourceID,
                    expectedOrganizationRevision: second.revision,
                    domainName: "stale.example",
                    isPrimary: false
                )
            }
            #expect(throws: MeetingAccessError.invalidCustomerIntelligenceMutation) {
                try store.setOrganizationDomain(
                    organizationID: second.resourceID,
                    expectedOrganizationRevision: try #require(shared.revision),
                    domainName: "not a domain",
                    isPrimary: false
                )
            }

            let unit = try store.createOrganization(
                name: "Unit",
                nodeKind: .unit,
                parentOrganizationID: first.resourceID
            )
            #expect(throws: MeetingAccessError.invalidCustomerIntelligenceMutation) {
                try store.setOrganizationDomain(
                    organizationID: unit.resourceID,
                    expectedOrganizationRevision: unit.revision,
                    domainName: "unit.example",
                    isPrimary: false
                )
            }
            let nestedOrganization = try store.createOrganization(
                name: "Nested organization",
                nodeKind: .organization,
                parentOrganizationID: first.resourceID
            )
            #expect(throws: MeetingAccessError.invalidCustomerIntelligenceMutation) {
                try store.setOrganizationDomain(
                    organizationID: nestedOrganization.resourceID,
                    expectedOrganizationRevision: nestedOrganization.revision,
                    domainName: "nested.example",
                    isPrimary: false
                )
            }

            let removed = try store.removeOrganizationDomain(
                organizationID: second.resourceID,
                expectedOrganizationRevision: try #require(shared.revision),
                domainName: "shared.example"
            )
            #expect(removed.changed)
            let removeNoOp = try store.removeOrganizationDomain(
                organizationID: second.resourceID,
                expectedOrganizationRevision: try #require(removed.revision),
                domainName: "shared.example"
            )
            #expect(!removeNoOp.changed)
        }

        @Test
        // swiftlint:disable:next function_body_length
        func organizationDomainMCPToolsDeclareDispatchAndEnforceWriteAccess() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            let organization = try store.createOrganization(
                name: "Domain MCP",
                nodeKind: .organization,
                parentOrganizationID: nil
            )
            let server = DahliaMCPServer(store: store)
            let initialized = try Self.json(server.handleLine(
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
            ))
            let instructions = try #require(
                (initialized["result"] as? [String: Any])?["instructions"] as? String
            )
            #expect(instructions.contains("domain may be shared"))
            #expect(instructions.contains("set_contact_organization_membership"))
            _ = server.handleLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)

            let tools = try Self.json(server.handleLine(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
            let definitions = ((tools["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
            let setDefinition = try #require(
                definitions.first { $0["name"] as? String == "set_organization_domain" }
            )
            let setSchema = try #require(setDefinition["inputSchema"] as? [String: Any])
            #expect(Set(setSchema["required"] as? [String] ?? []) == [
                "organization_id", "expected_organization_revision", "domain_name", "is_primary",
            ])
            let setProperties = try #require(setSchema["properties"] as? [String: Any])
            let setDomainSchema = try #require(setProperties["domain_name"] as? [String: Any])
            #expect(
                setDomainSchema["maxLength"] as? Int
                    == CustomerIdentityNormalizer.maximumDomainNameLength
            )
            let removeDefinition = try #require(
                definitions.first { $0["name"] as? String == "remove_organization_domain" }
            )
            let removeSchema = try #require(removeDefinition["inputSchema"] as? [String: Any])
            #expect(Set(removeSchema["required"] as? [String] ?? []) == [
                "organization_id", "expected_organization_revision", "domain_name",
            ])
            let removeProperties = try #require(removeSchema["properties"] as? [String: Any])
            let removeDomainSchema = try #require(removeProperties["domain_name"] as? [String: Any])
            #expect(
                removeDomainSchema["maxLength"] as? Int
                    == CustomerIdentityNormalizer.maximumDomainNameLength
            )

            let setCall = try Self.json(server.handleLine("""
            {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"set_organization_domain","arguments":{\
            "organization_id":"\(organization.resourceID.uuidString)",\
            "expected_organization_revision":\(organization.revision),\
            "domain_name":"mcp.example","is_primary":false}}}
            """))
            let setContent = try #require(
                (setCall["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
            )
            #expect(setContent["changed"] as? Bool == true)
            let revision = try #require(setContent["revision"] as? Int)

            let removeCall = try Self.json(server.handleLine("""
            {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"remove_organization_domain","arguments":{\
            "organization_id":"\(organization.resourceID.uuidString)",\
            "expected_organization_revision":\(revision),\
            "domain_name":"mcp.example"}}}
            """))
            let removeContent = try #require(
                (removeCall["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
            )
            #expect(removeContent["changed"] as? Bool == true)

            let readOnlyServer = try DahliaMCPServer(
                store: fixture.store(vaultID: fixture.primaryVaultID)
            )
            _ = try Self.json(readOnlyServer.handleLine(
                #"{"jsonrpc":"2.0","id":5,"method":"initialize","params":{}}"#
            ))
            _ = readOnlyServer.handleLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
            let readOnlyTools = try Self.json(
                readOnlyServer.handleLine(#"{"jsonrpc":"2.0","id":6,"method":"tools/list"}"#)
            )
            let readOnlyDefinitions =
                ((readOnlyTools["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
            #expect(!readOnlyDefinitions.contains { $0["name"] as? String == "set_organization_domain" })
            let denied = try Self.json(readOnlyServer.handleLine("""
            {"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"set_organization_domain","arguments":{\
            "organization_id":"\(organization.resourceID.uuidString)",\
            "expected_organization_revision":1,\
            "domain_name":"denied.example","is_primary":false}}}
            """))
            #expect((denied["result"] as? [String: Any])?["isError"] as? Bool == true)
        }

        @Test
        // swiftlint:disable:next function_body_length
        func writeMCPPublishesSimpleCrudToolsOnlyWhenEnabled() throws {
            let fixture = try Fixture()
            let readOnlyServer = try DahliaMCPServer(store: fixture.store(vaultID: fixture.primaryVaultID))
            _ = try Self.json(readOnlyServer.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#))
            _ = readOnlyServer.handleLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
            let readOnlyTools = try Self.json(
                readOnlyServer.handleLine(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
            )
            let readOnlyDefinitions = ((readOnlyTools["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
            #expect(!readOnlyDefinitions.contains { $0["name"] as? String == "create_project" })
            #expect(!readOnlyDefinitions.contains { $0["name"] as? String == "create_organization" })
            #expect(!readOnlyDefinitions.contains { ($0["name"] as? String)?.hasPrefix("delete_") == true })
            let deniedWrite = try Self.json(readOnlyServer.handleLine(#"""
            {"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"create_project","arguments":{"name":"Denied"}}}
            """#))
            #expect((deniedWrite["result"] as? [String: Any])?["isError"] as? Bool == true)
            #expect(!FileManager.default.fileExists(
                atPath: fixture.primaryVaultURL.appending(path: "Denied").path
            ))

            let writeServer = try DahliaMCPServer(
                store: fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            )
            _ = try Self.json(writeServer.handleLine(#"{"jsonrpc":"2.0","id":3,"method":"initialize","params":{}}"#))
            _ = writeServer.handleLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
            let writeTools = try Self.json(writeServer.handleLine(#"{"jsonrpc":"2.0","id":4,"method":"tools/list"}"#))
            let writeDefinitions = ((writeTools["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
            let names = Set(writeDefinitions.compactMap { $0["name"] as? String })
            let customerWriteNames: Set<String> = [
                "create_organization", "update_organization", "delete_organization",
                "create_contact", "update_contact", "delete_contact", "resolve_contact",
                "create_conversation_topic", "update_conversation_topic", "delete_conversation_topic",
                "create_insight", "update_insight", "delete_insight",
                "set_organization_domain", "remove_organization_domain",
                "set_contact_organization_membership", "remove_contact_organization_membership",
                "set_project_resource_reference", "remove_project_resource_reference",
                "set_conversation_topic_resource_reference",
                "remove_conversation_topic_resource_reference",
                "set_insight_resource_reference", "remove_insight_resource_reference",
                "set_meeting_project_assignment", "remove_meeting_project_assignment",
            ]
            #expect(customerWriteNames.isSubset(of: names))
            for definition in writeDefinitions where customerWriteNames.contains(definition["name"] as? String ?? "") {
                let inputSchema = try #require(definition["inputSchema"] as? [String: Any])
                let properties = try #require(inputSchema["properties"] as? [String: Any])
                #expect(inputSchema["type"] as? String == "object")
                #expect(properties["operations"] == nil)
                #expect(properties["records"] == nil)
            }
            for removedName in [
                "mutate_customer_intelligence",
                "begin_customer_intelligence_import",
                "append_customer_intelligence_import",
                "get_customer_intelligence_import",
                "commit_customer_intelligence_import",
                "apply_customer_intelligence_proposals",
                "reject_customer_intelligence_proposals",
                "set_meeting_project_memberships",
            ] {
                #expect(!names.contains(removedName))
            }
            #expect(!names.contains { $0.contains("participant") })
            let destructiveByName: [String: Bool] = Dictionary(
                uniqueKeysWithValues: writeDefinitions.compactMap { definition -> (String, Bool)? in
                    guard let name = definition["name"] as? String,
                          let annotations = definition["annotations"] as? [String: Any],
                          let destructive = annotations["destructiveHint"] as? Bool else {
                        return nil
                    }
                    return (name, destructive)
                }
            )
            #expect(destructiveByName["create_project"] == false)
            #expect(destructiveByName["update_project"] == true)
            #expect(destructiveByName["create_organization"] == false)
            #expect(destructiveByName["update_organization"] == true)
            #expect(destructiveByName["delete_organization"] == true)
            #expect(destructiveByName["delete_contact"] == true)
            #expect(destructiveByName["delete_conversation_topic"] == true)
            #expect(destructiveByName["delete_insight"] == true)
            #expect(destructiveByName["remove_contact_organization_membership"] == true)
            for name in customerWriteNames where name.hasPrefix("set_") {
                #expect(destructiveByName[name] == true)
            }
            let createContactDefinition = try #require(writeDefinitions.first {
                $0["name"] as? String == "create_contact"
            })
            let createContactSchema = try #require(createContactDefinition["inputSchema"] as? [String: Any])
            let createContactProperties = try #require(createContactSchema["properties"] as? [String: Any])
            let emailSchema = try #require(createContactProperties["email"] as? [String: Any])
            let displayNameSchema = try #require(createContactProperties["display_name"] as? [String: Any])
            #expect(emailSchema["maxLength"] as? Int == CustomerIntelligenceWriteLimits.email)
            #expect(displayNameSchema["maxLength"] as? Int == CustomerIntelligenceWriteLimits.shortText)
            let projectReferenceDefinition = try #require(writeDefinitions.first {
                $0["name"] as? String == "set_project_resource_reference"
            })
            let projectReferenceSchema = try #require(
                projectReferenceDefinition["inputSchema"] as? [String: Any]
            )
            let projectReferenceProperties = try #require(
                projectReferenceSchema["properties"] as? [String: Any]
            )
            let projectResourceTypeSchema = try #require(
                projectReferenceProperties["resource_type"] as? [String: Any]
            )
            #expect(projectResourceTypeSchema["enum"] as? [String] == ["organization", "contact"])
            let deleteNames: Set<String> = [
                "delete_organization", "delete_contact", "delete_conversation_topic",
                "delete_insight",
            ]
            for definition in writeDefinitions where deleteNames.contains(definition["name"] as? String ?? "") {
                let inputSchema = try #require(definition["inputSchema"] as? [String: Any])
                let inputProperties = try #require(inputSchema["properties"] as? [String: Any])
                let outputSchema = try #require(definition["outputSchema"] as? [String: Any])
                let outputProperties = try #require(outputSchema["properties"] as? [String: Any])
                let annotations = try #require(definition["annotations"] as? [String: Any])
                #expect(inputProperties["revision"] != nil)
                #expect(outputProperties["revision"] == nil)
                #expect(annotations["idempotentHint"] as? Bool == false)
            }

            let create = try Self.json(writeServer.handleLine(#"""
            {"jsonrpc":"2.0","id":5,"method":"tools/call","params":{
                "name":"create_project","arguments":{"name":"MCP Root","project_type":"personal"}
            }}
            """#))
            let created = try #require(
                ((create["result"] as? [String: Any])?["structuredContent"] as? [String: Any])?["project"]
                    as? [String: Any]
            )
            let projectID = try #require(created["project_id"] as? String)
            let revision = try #require(created["revision"] as? Int)

            let rename = try Self.json(writeServer.handleLine("""
            {"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"update_project","arguments":{
                "project_id":"\(projectID)","revision":\(revision),"name":"Renamed Root"
            }}}
            """))
            let renamed = try #require(
                ((rename["result"] as? [String: Any])?["structuredContent"] as? [String: Any])?["project"]
                    as? [String: Any]
            )
            #expect(renamed["path"] as? String == "Renamed Root")

            let childResponse = try Self.json(writeServer.handleLine("""
            {"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"create_project","arguments":{
                "name":"Child","parent_project_id":"\(projectID)"
            }}}
            """))
            let child = try #require(
                ((childResponse["result"] as? [String: Any])?["structuredContent"] as? [String: Any])?["project"]
                    as? [String: Any]
            )
            let childID = try #require(child["project_id"] as? String)
            let childRevision = try #require(child["revision"] as? Int)

            let descriptionUpdate = try Self.json(writeServer.handleLine("""
            {"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"update_project","arguments":{
                "project_id":"\(childID)","revision":\(childRevision),"description":"Still nested"
            }}}
            """))
            let describedChild = try #require(
                ((descriptionUpdate["result"] as? [String: Any])?["structuredContent"] as? [String: Any])?["project"]
                    as? [String: Any]
            )
            #expect(describedChild["parent_project_id"] as? String == projectID)

            let describedRevision = try #require(describedChild["revision"] as? Int)
            let promote = try Self.json(writeServer.handleLine("""
            {"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"update_project","arguments":{
                "project_id":"\(childID)","revision":\(describedRevision),"parent_project_id":null
            }}}
            """))
            let promoted = try #require(
                ((promote["result"] as? [String: Any])?["structuredContent"] as? [String: Any])?["project"]
                    as? [String: Any]
            )
            #expect(promoted["parent_project_id"] == nil)

            let promotedRevision = try #require(promoted["revision"] as? Int)
            let nullName = try Self.json(writeServer.handleLine("""
            {"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"update_project","arguments":{
                "project_id":"\(childID)","revision":\(promotedRevision),"name":null
            }}}
            """))
            #expect((nullName["error"] as? [String: Any])?["code"] as? Int == -32602)
        }

        @Test
        func customerIntelligenceMCPReturnsStableWriteErrorCodes() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            let contact = try store.createContact(email: "alice@example.com", displayName: "Alice")
            let organization = try store.createOrganization(
                name: "Acme",
                nodeKind: .organization,
                parentOrganizationID: nil
            )
            let membership = try store.setContactOrganizationMembership(
                contactID: contact.resourceID,
                organizationID: organization.resourceID,
                expectedOrganizationRevision: organization.revision,
                roleLabel: nil
            )
            let project = try #require(store.queryProjects(
                ProjectQuery(projectID: fixture.primaryProjectID)
            ).projects.first)
            let server = DahliaMCPServer(store: store)
            _ = try Self.json(server.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#))
            _ = server.handleLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)

            func errorCode(for request: String) throws -> String {
                let response = try Self.json(server.handleLine(request))
                let result = try #require(response["result"] as? [String: Any])
                let content = try #require(result["structuredContent"] as? [String: Any])
                let error = try #require(content["error"] as? [String: Any])
                return try #require(error["code"] as? String)
            }

            let duplicateCode = try errorCode(for: #"""
            {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"create_contact","arguments":{
                "email":"ALICE@example.com","display_name":"Duplicate"
            }}}
            """#)
            #expect(duplicateCode == "duplicate_email")

            let revisionCode = try errorCode(for: """
            {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"update_organization","arguments":{
                "organization_id":"\(organization.resourceID.uuidString)","revision":999,"name":"Stale"
            }}}
            """)
            #expect(revisionCode == "revision_conflict")

            let referenceCode = try errorCode(for: """
            {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{
                "name":"set_project_resource_reference","arguments":{
                    "project_id":"\(project.projectID.uuidString)","project_revision":\(project.revision),
                    "resource_type":"contact","resource_id":"\(UUID.v7().uuidString)"
                }
            }}
            """)
            #expect(referenceCode == "invalid_reference")

            let membershipRevision = try #require(membership.revision)
            let resourceInUseCode = try errorCode(for: """
            {"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"delete_organization","arguments":{
                "organization_id":"\(organization.resourceID.uuidString)","revision":\(membershipRevision)
            }}}
            """)
            #expect(resourceInUseCode == "resource_in_use")
        }

        @Test
        // swiftlint:disable:next function_body_length
        func organizationDeletionRequiresAnEmptyLeafAndCleansTypedReferences() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            let root = try store.createOrganization(
                name: "Acme",
                nodeKind: .organization,
                parentOrganizationID: nil
            )
            let child = try store.createOrganization(
                name: "Platform",
                nodeKind: .unit,
                parentOrganizationID: root.resourceID
            )

            #expect(throws: MeetingAccessError.customerIntelligenceResourceInUse(
                "Organization cannot be deleted while it is in use: child_organizations=1."
            )) {
                try store.deleteOrganization(id: root.resourceID, expectedRevision: root.revision)
            }
            let deletedChild = try store.deleteOrganization(
                id: child.resourceID,
                expectedRevision: child.revision
            )
            #expect(deletedChild.resourceType == .organization)
            #expect(deletedChild.changed)

            let contact = try store.createContact(email: "owner@example.com", displayName: "Owner")
            let membership = try store.setContactOrganizationMembership(
                contactID: contact.resourceID,
                organizationID: root.resourceID,
                expectedOrganizationRevision: root.revision,
                roleLabel: "Owner"
            )
            let membershipRevision = try #require(membership.revision)
            #expect(throws: MeetingAccessError.customerIntelligenceResourceInUse(
                "Organization cannot be deleted while it is in use: contact_memberships=1."
            )) {
                try store.deleteOrganization(id: root.resourceID, expectedRevision: membershipRevision)
            }
            let removedMembership = try store.removeContactOrganizationMembership(
                contactID: contact.resourceID,
                organizationID: root.resourceID,
                expectedOrganizationRevision: membershipRevision
            )

            let project = try #require(store.queryProjects(
                ProjectQuery(projectID: fixture.primaryProjectID)
            ).projects.first)
            let projectReference = try store.setProjectResourceReference(
                projectID: project.projectID,
                expectedProjectRevision: project.revision,
                resourceType: .organization,
                resourceID: root.resourceID,
                relationLabel: "Customer"
            )
            let insight = try store.createInsight(content: "Account", isAccepted: true, metadataJSON: nil)
            let insightReference = try store.setInsightResourceReference(
                insightID: insight.resourceID,
                expectedInsightRevision: insight.revision,
                resourceType: .organization,
                resourceID: root.resourceID,
                referenceRole: .context
            )
            let topic = try store.createConversationTopic(title: "Rollout", currentState: "Planning")
            let topicReference = try store.setConversationTopicResourceReference(
                topicID: topic.resourceID,
                expectedTopicRevision: topic.revision,
                resourceType: .organization,
                resourceID: root.resourceID,
                note: nil
            )
            let deletedRoot = try store.deleteOrganization(
                id: root.resourceID,
                expectedRevision: try #require(removedMembership.revision)
            )
            #expect(deletedRoot.changed)
            #expect(throws: MeetingAccessError.organizationNotFound) {
                try store.organization(id: root.resourceID)
            }
            let updatedProject = try #require(store.queryProjects(
                ProjectQuery(projectID: project.projectID)
            ).projects.first)
            let projectReferenceRevision = try #require(projectReference.revision)
            #expect(updatedProject.revision == projectReferenceRevision + 1)
            #expect(try store.queryProjectResources(
                ProjectResourceAccessQuery(projectID: project.projectID)
            ).resources.isEmpty)
            let missingProjectReference = try store.removeProjectResourceReference(
                projectID: project.projectID,
                expectedProjectRevision: updatedProject.revision,
                resourceType: .organization,
                resourceID: root.resourceID
            )
            #expect(!missingProjectReference.changed)
            let updatedInsight = try store.insight(id: insight.resourceID).insight
            let insightReferenceRevision = try #require(insightReference.revision)
            #expect(updatedInsight.revision == insightReferenceRevision + 1)
            #expect(updatedInsight.references.isEmpty)
            let missingInsightReference = try store.removeInsightResourceReference(
                insightID: insight.resourceID,
                expectedInsightRevision: updatedInsight.revision,
                resourceType: .organization,
                resourceID: root.resourceID
            )
            #expect(!missingInsightReference.changed)
            let updatedTopic = try store.conversationTopic(id: topic.resourceID)
            let topicReferenceRevision = try #require(topicReference.revision)
            #expect(updatedTopic.topic.revision == topicReferenceRevision + 1)
            #expect(updatedTopic.references.isEmpty)
            let missingTopicReference = try store.removeConversationTopicResourceReference(
                topicID: topic.resourceID,
                expectedTopicRevision: updatedTopic.topic.revision,
                resourceType: .organization,
                resourceID: root.resourceID
            )
            #expect(!missingTopicReference.changed)
            #expect(try store.contact(id: contact.resourceID).contact.id == contact.resourceID)
        }

        @Test
        // swiftlint:disable:next function_body_length
        func contactDeletionRequiresEverySupportedReferenceToBeRemoved() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            let organization = try store.createOrganization(
                name: "Acme",
                nodeKind: .organization,
                parentOrganizationID: nil
            )
            let membershipContact = try store.createContact(email: "membership@example.com", displayName: nil)
            _ = try store.setContactOrganizationMembership(
                contactID: membershipContact.resourceID,
                organizationID: organization.resourceID,
                expectedOrganizationRevision: organization.revision,
                roleLabel: nil
            )

            let participantContact = try store.createContact(email: "participant@example.com", displayName: nil)
            try fixture.manager.dbQueue.write { db in
                try MeetingParticipantRecord(
                    meetingId: fixture.firstMeetingID,
                    contactId: participantContact.resourceID,
                    role: .required,
                    responseStatus: .accepted,
                    source: "calendar",
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
            }

            let projectContact = try store.createContact(email: "project@example.com", displayName: nil)
            let project = try #require(store.queryProjects(
                ProjectQuery(projectID: fixture.primaryProjectID)
            ).projects.first)
            _ = try store.setProjectResourceReference(
                projectID: project.projectID,
                expectedProjectRevision: project.revision,
                resourceType: .contact,
                resourceID: projectContact.resourceID,
                relationLabel: nil
            )

            let topicContact = try store.createContact(email: "topic@example.com", displayName: nil)
            let topic = try store.createConversationTopic(title: "Topic", currentState: "Open")
            _ = try store.setConversationTopicResourceReference(
                topicID: topic.resourceID,
                expectedTopicRevision: topic.revision,
                resourceType: .contact,
                resourceID: topicContact.resourceID,
                note: nil
            )

            let insightContact = try store.createContact(email: "insight@example.com", displayName: nil)
            let insight = try store.createInsight(content: "Insight", isAccepted: false, metadataJSON: nil)
            _ = try store.setInsightResourceReference(
                insightID: insight.resourceID,
                expectedInsightRevision: insight.revision,
                resourceType: .contact,
                resourceID: insightContact.resourceID,
                referenceRole: .mentioned
            )

            for (contactID, blocker) in [
                (membershipContact.resourceID, "organization_memberships"),
                (participantContact.resourceID, "meeting_participants"),
                (projectContact.resourceID, "project_references"),
                (topicContact.resourceID, "topic_references"),
                (insightContact.resourceID, "insight_references"),
            ] {
                let revision = try store.contact(id: contactID).contact.revision
                do {
                    _ = try store.deleteContact(id: contactID, expectedRevision: revision)
                    Issue.record("Expected \(blocker) to prevent Contact deletion")
                } catch let MeetingAccessError.customerIntelligenceResourceInUse(message) {
                    #expect(message.contains("\(blocker)=1"))
                }
                #expect(try store.contact(id: contactID).contact.id == contactID)
            }

            for contact in [
                try store.createContact(email: "unused@example.com", displayName: nil),
                try store.createContact(email: nil, displayName: "Provisional"),
            ] {
                let result = try store.deleteContact(
                    id: contact.resourceID,
                    expectedRevision: contact.revision
                )
                #expect(result.resourceType == .contact)
                #expect(throws: MeetingAccessError.contactNotFound) {
                    try store.deleteContact(id: contact.resourceID, expectedRevision: contact.revision)
                }
            }
        }

        @Test
        func topicAndInsightDeletionKeepsReferencedRecords() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            let contact = try store.createContact(email: "owner@example.com", displayName: "Owner")
            let topic = try store.createConversationTopic(title: "Security", currentState: "Review")
            let topicReference = try store.setConversationTopicResourceReference(
                topicID: topic.resourceID,
                expectedTopicRevision: topic.revision,
                resourceType: .meeting,
                resourceID: fixture.firstMeetingID,
                note: "Reviewed"
            )
            let insight = try store.createInsight(content: "Owner", isAccepted: true, metadataJSON: nil)
            let insightReference = try store.setInsightResourceReference(
                insightID: insight.resourceID,
                expectedInsightRevision: insight.revision,
                resourceType: .contact,
                resourceID: contact.resourceID,
                referenceRole: .evidence
            )
            #expect(throws: MeetingAccessError.customerIntelligenceRevisionConflict) {
                try store.deleteConversationTopic(id: topic.resourceID, expectedRevision: topic.revision)
            }
            let deletedTopic = try store.deleteConversationTopic(
                id: topic.resourceID,
                expectedRevision: try #require(topicReference.revision)
            )
            let deletedInsight = try store.deleteInsight(
                id: insight.resourceID,
                expectedRevision: try #require(insightReference.revision)
            )
            #expect(deletedTopic.resourceType == .conversationTopic)
            #expect(deletedInsight.resourceType == .insight)
            #expect(throws: MeetingAccessError.conversationTopicNotFound) {
                try store.conversationTopic(id: topic.resourceID)
            }
            #expect(throws: MeetingAccessError.insightNotFound) {
                try store.insight(id: insight.resourceID)
            }
            #expect(try store.meeting(id: fixture.firstMeetingID).meeting.id == fixture.firstMeetingID)
            #expect(try store.contact(id: contact.resourceID).contact.id == contact.resourceID)
        }

        @Test
        // swiftlint:disable:next function_body_length
        func customerIntelligenceCrudChangesOneRecordOrRelationshipPerCall() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)

            let root = try store.createOrganization(
                name: "Acme Customer",
                nodeKind: .organization,
                parentOrganizationID: nil,
                description: "Enterprise account"
            )
            #expect(try store.organization(id: root.resourceID).organization.description == "Enterprise account")
            let updatedRoot = try store.updateOrganization(
                id: root.resourceID,
                expectedRevision: root.revision,
                name: nil,
                description: "Strategic enterprise account",
                parent: .unchanged
            )
            #expect(updatedRoot.changed)
            #expect(
                try store.organization(id: root.resourceID).organization.description
                    == "Strategic enterprise account"
            )
            let unit = try store.createOrganization(
                name: "Data",
                nodeKind: .unit,
                parentOrganizationID: root.resourceID
            )
            let contact = try store.createContact(email: "alice@example.com", displayName: nil)
            let fetchedContact = try store.contact(id: contact.resourceID)
            #expect(fetchedContact.contact.displayName == "alice")

            let membership = try store.setContactOrganizationMembership(
                contactID: contact.resourceID,
                organizationID: unit.resourceID,
                expectedOrganizationRevision: unit.revision,
                roleLabel: "Lead"
            )
            #expect(membership.changed)
            let sameMembership = try store.setContactOrganizationMembership(
                contactID: contact.resourceID,
                organizationID: unit.resourceID,
                expectedOrganizationRevision: try #require(membership.revision),
                roleLabel: "Lead"
            )
            #expect(!sameMembership.changed)
            let removedMembership = try store.removeContactOrganizationMembership(
                contactID: contact.resourceID,
                organizationID: unit.resourceID,
                expectedOrganizationRevision: try #require(sameMembership.revision)
            )
            #expect(removedMembership.changed)
            let missingMembership = try store.removeContactOrganizationMembership(
                contactID: contact.resourceID,
                organizationID: unit.resourceID,
                expectedOrganizationRevision: try #require(removedMembership.revision)
            )
            #expect(!missingMembership.changed)

            let topic = try store.createConversationTopic(title: "Security", currentState: "Review")
            let topicReference = try store.setConversationTopicResourceReference(
                topicID: topic.resourceID,
                expectedTopicRevision: topic.revision,
                resourceType: .organization,
                resourceID: root.resourceID,
                note: nil
            )
            #expect(topicReference.changed)
            let sameTopicReference = try store.setConversationTopicResourceReference(
                topicID: topic.resourceID,
                expectedTopicRevision: try #require(topicReference.revision),
                resourceType: .organization,
                resourceID: root.resourceID,
                note: nil
            )
            #expect(!sameTopicReference.changed)
            let removedTopicReference = try store.removeConversationTopicResourceReference(
                topicID: topic.resourceID,
                expectedTopicRevision: try #require(sameTopicReference.revision),
                resourceType: .organization,
                resourceID: root.resourceID
            )
            #expect(removedTopicReference.changed)
            let missingTopicReference = try store.removeConversationTopicResourceReference(
                topicID: topic.resourceID,
                expectedTopicRevision: try #require(removedTopicReference.revision),
                resourceType: .organization,
                resourceID: root.resourceID
            )
            #expect(!missingTopicReference.changed)

            let insight = try store.createInsight(
                content: "Alice owns the review",
                isAccepted: false,
                metadataJSON: nil
            )
            let insightReference = try store.setInsightResourceReference(
                insightID: insight.resourceID,
                expectedInsightRevision: insight.revision,
                resourceType: .contact,
                resourceID: contact.resourceID,
                referenceRole: .evidence
            )
            #expect(insightReference.changed)
            let sameInsightReference = try store.setInsightResourceReference(
                insightID: insight.resourceID,
                expectedInsightRevision: try #require(insightReference.revision),
                resourceType: .contact,
                resourceID: contact.resourceID,
                referenceRole: .evidence
            )
            #expect(!sameInsightReference.changed)
            let removedInsightReference = try store.removeInsightResourceReference(
                insightID: insight.resourceID,
                expectedInsightRevision: try #require(sameInsightReference.revision),
                resourceType: .contact,
                resourceID: contact.resourceID
            )
            #expect(removedInsightReference.changed)
            let missingInsightReference = try store.removeInsightResourceReference(
                insightID: insight.resourceID,
                expectedInsightRevision: try #require(removedInsightReference.revision),
                resourceType: .contact,
                resourceID: contact.resourceID
            )
            #expect(!missingInsightReference.changed)

            let project = try #require(store.queryProjects(
                ProjectQuery(projectID: fixture.primaryProjectID)
            ).projects.first)
            let projectReference = try store.setProjectResourceReference(
                projectID: project.projectID,
                expectedProjectRevision: project.revision,
                resourceType: .contact,
                resourceID: contact.resourceID,
                relationLabel: "Owner"
            )
            #expect(projectReference.changed)
            let sameProjectReference = try store.setProjectResourceReference(
                projectID: project.projectID,
                expectedProjectRevision: try #require(projectReference.revision),
                resourceType: .contact,
                resourceID: contact.resourceID,
                relationLabel: "Owner"
            )
            #expect(!sameProjectReference.changed)
            let removedProjectReference = try store.removeProjectResourceReference(
                projectID: project.projectID,
                expectedProjectRevision: try #require(sameProjectReference.revision),
                resourceType: .contact,
                resourceID: contact.resourceID
            )
            #expect(removedProjectReference.changed)
            let missingProjectReference = try store.removeProjectResourceReference(
                projectID: project.projectID,
                expectedProjectRevision: try #require(removedProjectReference.revision),
                resourceType: .contact,
                resourceID: contact.resourceID
            )
            #expect(!missingProjectReference.changed)

            let sameAssignment = try store.setMeetingProjectAssignment(
                meetingID: fixture.firstMeetingID,
                expectedProjectID: fixture.primaryProjectID,
                projectID: fixture.primaryProjectID
            )
            #expect(!sameAssignment.changed)
            let removedAssignment = try store.removeMeetingProjectAssignment(
                meetingID: fixture.firstMeetingID,
                expectedProjectID: fixture.primaryProjectID
            )
            #expect(removedAssignment.changed)
            let missingAssignment = try store.removeMeetingProjectAssignment(
                meetingID: fixture.firstMeetingID,
                expectedProjectID: nil
            )
            #expect(!missingAssignment.changed)

            #expect(throws: MeetingAccessError.customerIntelligenceRevisionConflict) {
                try store.updateOrganization(
                    id: root.resourceID,
                    expectedRevision: 999,
                    name: "Stale",
                    parent: .unchanged
                )
            }
            let laterContact = try store.createContact(email: nil, displayName: "Later")
            #expect(try store.contact(id: laterContact.resourceID).contact.displayName == "Later")
            #expect(throws: MeetingAccessError.duplicateContactEmail) {
                try store.createContact(email: "ALICE@example.com", displayName: "Duplicate")
            }
        }

        @Test
        func customerIntelligenceWriteStoreEnforcesTextLimits() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            let oversizedShortText = String(
                repeating: "x",
                count: CustomerIntelligenceWriteLimits.shortText + 1
            )

            #expect(throws: MeetingAccessError.invalidCustomerIntelligenceMutation) {
                try store.createOrganization(
                    name: oversizedShortText,
                    nodeKind: .organization,
                    parentOrganizationID: nil
                )
            }
            #expect(throws: MeetingAccessError.invalidCustomerIntelligenceMutation) {
                try store.createContact(
                    email: "owner@example.com",
                    displayName: oversizedShortText
                )
            }
            let organization = try store.createOrganization(
                name: "Acme",
                nodeKind: .organization,
                parentOrganizationID: nil
            )
            let contact = try store.createContact(email: nil, displayName: "Owner")
            #expect(throws: MeetingAccessError.invalidCustomerIntelligenceMutation) {
                try store.setContactOrganizationMembership(
                    contactID: contact.resourceID,
                    organizationID: organization.resourceID,
                    expectedOrganizationRevision: organization.revision,
                    roleLabel: oversizedShortText
                )
            }
            #expect(try store.queryOrganizations().organizations.map(\.name) == ["Acme"])
            #expect(try store.queryContacts().contacts.map(\.displayName) == ["Owner"])
        }

        @Test
        // swiftlint:disable:next function_body_length
        func resolveContactMovesReferencesAndIncrementsTheirOwners() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            let organization = try store.createOrganization(
                name: "Acme Customer",
                nodeKind: .organization,
                parentOrganizationID: nil
            )
            let provisional = try store.createContact(email: nil, displayName: "Alice")
            let identified = try store.createContact(email: "alice@example.com", displayName: "Alice Smith")
            let membership = try store.setContactOrganizationMembership(
                contactID: provisional.resourceID,
                organizationID: organization.resourceID,
                expectedOrganizationRevision: organization.revision,
                roleLabel: "Lead"
            )
            let project = try #require(store.queryProjects(
                ProjectQuery(projectID: fixture.primaryProjectID)
            ).projects.first)
            let identifiedProjectReference = try store.setProjectResourceReference(
                projectID: project.projectID,
                expectedProjectRevision: project.revision,
                resourceType: .contact,
                resourceID: identified.resourceID,
                relationLabel: "Confirmed owner"
            )
            let projectReference = try store.setProjectResourceReference(
                projectID: project.projectID,
                expectedProjectRevision: try #require(identifiedProjectReference.revision),
                resourceType: .contact,
                resourceID: provisional.resourceID,
                relationLabel: "Owner"
            )
            let insight = try store.createInsight(content: "Owner", isAccepted: true, metadataJSON: nil)
            let identifiedInsightReference = try store.setInsightResourceReference(
                insightID: insight.resourceID,
                expectedInsightRevision: insight.revision,
                resourceType: .contact,
                resourceID: identified.resourceID,
                referenceRole: .context
            )
            let insightReference = try store.setInsightResourceReference(
                insightID: insight.resourceID,
                expectedInsightRevision: try #require(identifiedInsightReference.revision),
                resourceType: .contact,
                resourceID: provisional.resourceID,
                referenceRole: .evidence
            )
            let topic = try store.createConversationTopic(title: "Ownership", currentState: "Assigned")
            _ = try store.setConversationTopicResourceReference(
                topicID: topic.resourceID,
                expectedTopicRevision: topic.revision,
                resourceType: .contact,
                resourceID: provisional.resourceID,
                note: nil
            )
            let resolved = try store.resolveContact(
                provisionalContactID: provisional.resourceID,
                provisionalRevision: provisional.revision,
                identifiedContactID: identified.resourceID,
                identifiedRevision: identified.revision
            )
            #expect(resolved.resourceID == identified.resourceID)
            #expect(throws: MeetingAccessError.contactNotFound) {
                try store.contact(id: provisional.resourceID)
            }
            let target = try store.contact(id: identified.resourceID)
            #expect(target.memberships.contains { $0.organizationID == organization.resourceID })
            let resolvedProjectReferences = try store.queryProjectResources(
                ProjectResourceAccessQuery(projectID: project.projectID)
            ).resources.filter { $0.resourceID == identified.resourceID }
            #expect(resolvedProjectReferences.count == 2)
            #expect(Set(resolvedProjectReferences.map(\.relationLabel)) == ["Confirmed owner", "Owner"])
            #expect(try store.conversationTopic(id: topic.resourceID).references.contains {
                $0.resourceID == identified.resourceID
            })
            let resolvedInsightReferences = try store.insight(id: insight.resourceID).insight.references
                .filter { $0.resourceID == identified.resourceID }
            #expect(resolvedInsightReferences.count == 2)
            #expect(Set(resolvedInsightReferences.map(\.referenceRole)) == [.context, .evidence])
            let resolvedProject = try #require(store.queryProjects(
                ProjectQuery(projectID: project.projectID)
            ).projects.first)
            let projectReferenceRevision = try #require(projectReference.revision)
            let resolvedInsight = try store.insight(id: insight.resourceID).insight
            let insightReferenceRevision = try #require(insightReference.revision)
            let resolvedOrganization = try store.organization(id: organization.resourceID).organization
            let membershipRevision = try #require(membership.revision)
            #expect(resolvedProject.revision == projectReferenceRevision + 1)
            #expect(resolvedInsight.revision == insightReferenceRevision + 1)
            #expect(resolvedOrganization.revision >= membershipRevision)
        }

        @Test
        func resolveContactAccountsForParticipantRevisionTriggers() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            let provisional = try store.createContact(email: nil, displayName: "Alice")
            let identified = try store.createContact(email: "alice@example.com", displayName: "Alice Smith")
            try fixture.manager.dbQueue.write { db in
                try MeetingParticipantRecord(
                    meetingId: fixture.firstMeetingID,
                    contactId: provisional.resourceID,
                    role: .required,
                    responseStatus: .accepted,
                    source: "calendar",
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
            }
            let provisionalRevision = try store.contact(id: provisional.resourceID).contact.revision

            let resolved = try store.resolveContact(
                provisionalContactID: provisional.resourceID,
                provisionalRevision: provisionalRevision,
                identifiedContactID: identified.resourceID,
                identifiedRevision: identified.revision
            )

            let contact = try store.contact(id: identified.resourceID).contact
            #expect(resolved.revision == contact.revision)
            let participantContactID = try fixture.manager.dbQueue.read { db in
                try UUID.fetchOne(
                    db,
                    sql: "SELECT contactId FROM meeting_participants WHERE meetingId = ?",
                    arguments: [fixture.firstMeetingID]
                )
            }
            #expect(participantContactID == identified.resourceID)
            #expect(throws: MeetingAccessError.contactNotFound) {
                try store.contact(id: provisional.resourceID)
            }
        }

        @Test
        func conversationTopicReturnsABoundedReferenceListWithTruncationMetadata() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            let topic = try store.createConversationTopic(title: "Large topic", currentState: "Active")
            try fixture.manager.dbQueue.write { db in
                for index in 0...100 {
                    let organizationID = UUID.v7()
                    let now = Date.now.addingTimeInterval(TimeInterval(index))
                    try OrganizationRecord(
                        id: organizationID,
                        vaultId: fixture.primaryVaultID,
                        parentOrganizationId: nil,
                        nodeKind: .organization,
                        name: "Organization \(index)",
                        revision: 1,
                        createdAt: now,
                        updatedAt: now
                    ).insert(db)
                    try ConversationTopicReferenceRecord(
                        topicId: topic.resourceID,
                        resourceType: .organization,
                        resourceId: organizationID,
                        note: nil,
                        createdAt: now,
                        updatedAt: now
                    ).insert(db)
                }
            }

            let detail = try store.conversationTopic(id: topic.resourceID)
            #expect(detail.references.count == 100)
            #expect(detail.referencesTruncated)
        }

        @Test
        func meetingCursorScopeDistinguishesDelimitersAndSubsecondDates() throws {
            let fixture = try Fixture()
            try fixture.manager.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE meetings SET name = ? WHERE id IN (?, ?)",
                    arguments: ["Plan\u{1f}Acme", fixture.firstMeetingID, fixture.secondMeetingID]
                )
            }
            let store = try fixture.store(vaultID: fixture.primaryVaultID)
            let delimiterCursor = try #require(store.queryMeetings(.init(
                query: "Plan\u{1f}Acme",
                limit: 1
            )).nextCursor)
            #expect(throws: MeetingAccessError.invalidCursor) {
                try store.queryMeetings(.init(
                    query: "Plan",
                    project: "Acme",
                    limit: 1,
                    cursor: delimiterCursor
                ))
            }

            let dateCursor = try #require(store.queryMeetings(.init(
                createdFrom: Date(timeIntervalSince1970: 0.1),
                limit: 1
            )).nextCursor)
            #expect(throws: MeetingAccessError.invalidCursor) {
                try store.queryMeetings(.init(
                    createdFrom: Date(timeIntervalSince1970: 0.2),
                    limit: 1,
                    cursor: dateCursor
                ))
            }
        }

        @Test
        func screenshotIDSelectorRejectsPaginationArguments() throws {
            let fixture = try Fixture()
            let server = try DahliaMCPServer(store: fixture.store(vaultID: fixture.primaryVaultID))
            _ = server.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
            _ = server.handleLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
            let response = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_meeting_screenshots","arguments":{"meeting_id":"\#(fixture
                .firstMeetingID.uuidString)","screenshot_ids":["\#(fixture.firstScreenshotID.uuidString)"],"limit":1}}}
            """#))
            #expect((response["error"] as? [String: Any])?["code"] as? Int == -32602)

            func call(ids: [String]) throws -> [String: Any] {
                let request: [String: Any] = [
                    "jsonrpc": "2.0",
                    "id": 3,
                    "method": "tools/call",
                    "params": [
                        "name": "get_meeting_screenshots",
                        "arguments": ["meeting_id": fixture.firstMeetingID.uuidString, "screenshot_ids": ids],
                    ],
                ]
                let data = try JSONSerialization.data(withJSONObject: request)
                return try Self.json(server.handleLine(String(decoding: data, as: UTF8.self)))
            }

            let invalidSelections = try [
                call(ids: []),
                call(ids: [fixture.firstScreenshotID.uuidString, fixture.firstScreenshotID.uuidString]),
                call(ids: (0 ..< 11).map { _ in UUID.v7().uuidString }),
                call(ids: ["not-a-uuid"]),
            ]
            #expect(invalidSelections.allSatisfy { ($0["error"] as? [String: Any])?["code"] as? Int == -32602 })
        }

        @Test
        func elapsedTimeInputsRejectInvalidRanges() throws {
            let fixture = try Fixture()
            let server = try DahliaMCPServer(store: fixture.store(vaultID: fixture.primaryVaultID))
            _ = server.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
            _ = server.handleLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
            let response = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_meeting_transcript","arguments":{"meeting_id":"\#(fixture
                .firstMeetingID.uuidString)","from_elapsed_seconds":2,"to_elapsed_seconds":1}}}
            """#))
            #expect((response["error"] as? [String: Any])?["code"] as? Int == -32602)
        }

        @Test
        func oldDatabaseRequiresOpeningDahliaForMigration() throws {
            let databaseURL = URL.temporaryDirectory
                .appending(path: "dahlia-meeting-access-v18-\(UUID.v7().uuidString)")
                .appendingPathExtension("sqlite")
            defer { try? FileManager.default.removeItem(at: databaseURL) }
            let vaultID = UUID.v7()
            let queue = try DatabaseQueue(path: databaseURL.path)
            try queue.write { db in
                try db.execute(sql: "CREATE TABLE vaults (id BLOB PRIMARY KEY, name TEXT NOT NULL)")
                try db.execute(sql: "CREATE TABLE meetings (id BLOB PRIMARY KEY, vaultId BLOB NOT NULL, name TEXT NOT NULL)")
                try db.execute(sql: "INSERT INTO vaults (id, name) VALUES (?, ?)", arguments: [vaultID, "Old"])
            }
            let store = try MeetingAccessStore(databaseURL: databaseURL, vaultID: vaultID)

            #expect(throws: MeetingAccessError.databaseUpgradeRequired) {
                try store.scopedVault()
            }
        }

        @Test
        func v24DatabaseKeepsMeetingAccessButRejectsCustomerIntelligenceAccess() throws {
            let databaseURL = URL.temporaryDirectory
                .appending(path: "dahlia-meeting-access-v24-\(UUID.v7().uuidString)")
                .appendingPathExtension("sqlite")
            defer { try? FileManager.default.removeItem(at: databaseURL) }
            let vault = customerIntelligenceVault(name: "Before v25")
            let queue = try DatabaseQueue(path: databaseURL.path)
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v24_projectWorkspaceHierarchy")
            try queue.write { db in
                try vault.insert(db)
            }
            let store = try MeetingAccessStore(databaseURL: databaseURL, vaultID: vault.id)

            #expect(try store.scopedVault().id == vault.id)
            #expect(throws: MeetingAccessError.databaseUpgradeRequired) {
                try store.queryOrganizations()
            }
        }

        @Test
        func v25DatabaseRejectsWorkspaceAccessWithUpgradeError() throws {
            let databaseURL = URL.temporaryDirectory
                .appending(path: "dahlia-meeting-access-v25-\(UUID.v7().uuidString)")
                .appendingPathExtension("sqlite")
            defer { try? FileManager.default.removeItem(at: databaseURL) }
            let vault = customerIntelligenceVault(name: "Before v26")
            let queue = try DatabaseQueue(path: databaseURL.path)
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v25_customerIntelligence")
            try queue.write { try vault.insert($0) }
            let store = try MeetingAccessStore(databaseURL: databaseURL, vaultID: vault.id)

            #expect(throws: MeetingAccessError.databaseUpgradeRequired) {
                try store.queryOrganizations()
            }
            #expect(throws: MeetingAccessError.databaseUpgradeRequired) {
                try store.queryConversationTopics()
            }
        }

        @Test
        func v29DatabaseRejectsOrganizationWritesWithUpgradeError() throws {
            let databaseURL = URL.temporaryDirectory
                .appending(path: "dahlia-meeting-access-v29-\(UUID.v7().uuidString)")
                .appendingPathExtension("sqlite")
            defer { try? FileManager.default.removeItem(at: databaseURL) }
            let vault = customerIntelligenceVault(name: "Before v30")
            let organizationID = UUID.v7()
            let queue = try DatabaseQueue(path: databaseURL.path)
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v29_customerIntelligenceDirectCRUD")
            try queue.write { db in
                try vault.insert(db)
                try db.execute(
                    sql: """
                    INSERT INTO organizations (
                        id, vaultId, parentOrganizationId, nodeKind, name, revision, createdAt, updatedAt
                    )
                    VALUES (?, ?, NULL, 'organization', 'Acme', 1, ?, ?)
                    """,
                    arguments: [organizationID, vault.id, Date.now, Date.now]
                )
            }
            let store = try MeetingAccessStore(
                databaseURL: databaseURL,
                vaultID: vault.id,
                allowsWrites: true
            )

            #expect(throws: MeetingAccessError.databaseUpgradeRequired) {
                try store.createOrganization(
                    name: "New",
                    nodeKind: .organization,
                    parentOrganizationID: nil
                )
            }
            #expect(throws: MeetingAccessError.databaseUpgradeRequired) {
                try store.updateOrganization(
                    id: organizationID,
                    expectedRevision: 1,
                    name: "Updated",
                    parent: .unchanged
                )
            }
            #expect(throws: MeetingAccessError.databaseUpgradeRequired) {
                try store.deleteOrganization(id: organizationID, expectedRevision: 1)
            }
        }

        @Test
        func projectSchemaWithoutNameKeyRequiresOpeningDahliaForMigration() throws {
            let databaseURL = URL.temporaryDirectory
                .appending(path: "dahlia-meeting-access-project-schema-\(UUID.v7().uuidString)")
                .appendingPathExtension("sqlite")
            defer { try? FileManager.default.removeItem(at: databaseURL) }
            let vaultID = UUID.v7()
            let queue = try DatabaseQueue(path: databaseURL.path)
            try queue.write { db in
                try db.execute(sql: "CREATE TABLE vaults (id BLOB PRIMARY KEY, name TEXT NOT NULL)")
                try db.execute(sql: "CREATE TABLE meetings (id BLOB PRIMARY KEY, description TEXT NOT NULL)")
                try db.execute(sql: """
                CREATE TABLE summaries (
                    meetingId BLOB PRIMARY KEY,
                    title TEXT NOT NULL,
                    document TEXT NOT NULL,
                    createdAt DATETIME NOT NULL
                )
                """)
                try db.execute(sql: """
                CREATE TABLE projects (
                    id BLOB PRIMARY KEY,
                    parentProjectId BLOB,
                    name TEXT NOT NULL,
                    projectType TEXT,
                    revision INTEGER NOT NULL
                )
                """)
                try db.execute(sql: "INSERT INTO vaults (id, name) VALUES (?, ?)", arguments: [vaultID, "Old"])
            }
            let store = try MeetingAccessStore(databaseURL: databaseURL, vaultID: vaultID)

            #expect(throws: MeetingAccessError.databaseUpgradeRequired) {
                try store.scopedVault()
            }
        }

        @Test
        func v20SummaryColumnsRequireOpeningDahliaForMigration() throws {
            let databaseURL = URL.temporaryDirectory
                .appending(path: "dahlia-meeting-access-v20-\(UUID.v7().uuidString)")
                .appendingPathExtension("sqlite")
            defer { try? FileManager.default.removeItem(at: databaseURL) }
            let vaultID = UUID.v7()
            let queue = try DatabaseQueue(path: databaseURL.path)
            try queue.write { db in
                try db.execute(sql: "CREATE TABLE vaults (id BLOB PRIMARY KEY, name TEXT NOT NULL)")
                try db.execute(sql: "CREATE TABLE meetings (id BLOB PRIMARY KEY, description TEXT NOT NULL)")
                try db.execute(
                    sql: """
                    CREATE TABLE summaries (
                        meetingId BLOB PRIMARY KEY,
                        title TEXT NOT NULL,
                        summary TEXT NOT NULL,
                        document TEXT,
                        googleFileId TEXT,
                        vaultRelativePath TEXT,
                        createdAt DATETIME NOT NULL
                    )
                    """
                )
                try db.execute(sql: "INSERT INTO vaults (id, name) VALUES (?, ?)", arguments: [vaultID, "Old"])
            }
            let store = try MeetingAccessStore(databaseURL: databaseURL, vaultID: vaultID)

            #expect(throws: MeetingAccessError.databaseUpgradeRequired) {
                try store.scopedVault()
            }
        }

        private static func json(_ line: String?) throws -> [String: Any] {
            let line = try #require(line)
            let value = try JSONSerialization.jsonObject(with: Data(line.utf8))
            return try #require(value as? [String: Any])
        }

        private static func makeImage(width: Int, height: Int) -> CGImage? {
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }

    }

    @MainActor
    struct MCPDiscoveryContractTests {
        @Test
        func exposesRelationshipKeys() throws {
            let fixture = try Fixture()
            let server = try DahliaMCPServer(store: fixture.store(vaultID: fixture.primaryVaultID))

            let initialized = try Self.json(server.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#))
            let instructions = try #require((initialized["result"] as? [String: Any])?["instructions"] as? String)
            #expect(instructions.contains("ical_uid"))
            #expect(instructions.contains("project_id"))
            #expect(instructions.contains("transcripts or screenshots only when supporting evidence is needed"))
            #expect(server.handleLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)

            let tools = try Self.json(server.handleLine(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
            let definitions = ((tools["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
            let queryDefinition = try #require(definitions.first { $0["name"] as? String == "query_meetings" })
            let inputSchema = try #require(queryDefinition["inputSchema"] as? [String: Any])
            let inputProperties = try #require(inputSchema["properties"] as? [String: Any])
            #expect(inputProperties["ical_uid"] != nil)
            #expect(inputProperties["project_id"] != nil)
            #expect(inputProperties["organization_id"] != nil)
            #expect(inputProperties["include_descendants"] != nil)
            #expect(inputProperties["topic_id"] != nil)
            #expect(definitions.contains { $0["name"] as? String == "query_organization_chart" })
            #expect(definitions.contains { $0["name"] as? String == "query_conversation_topics" })
            #expect(definitions.contains { $0["name"] as? String == "get_conversation_topic" })
            #expect(!definitions.contains { $0["name"] as? String == "query_customer_intelligence_proposals" })
            let outputSchema = try #require(queryDefinition["outputSchema"] as? [String: Any])
            let outputProperties = try #require(outputSchema["properties"] as? [String: Any])
            let meetingsSchema = try #require(outputProperties["meetings"] as? [String: Any])
            let meetingSchema = try #require(meetingsSchema["items"] as? [String: Any])
            let meetingProperties = try #require(meetingSchema["properties"] as? [String: Any])
            #expect(meetingProperties["project_id"] != nil)
            #expect(meetingProperties["ical_uid"] != nil)
            #expect(meetingProperties["recurrence_id"] != nil)

            let metadataQuery = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"query_meetings","arguments":{"query":"planning"}}}
            """#))
            let metadataContent = (metadataQuery["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
            let meeting = try #require((metadataContent?["meetings"] as? [[String: Any]])?.first)
            #expect(meeting["project_id"] as? String == fixture.primaryProjectID.uuidString)
            #expect(meeting["ical_uid"] as? String == "roadmap@example.com")
            #expect((meeting["recurrence_id"] as? String)?.isEmpty == true)

            let projectQuery = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"query_meetings","arguments":{"project_id":"\#(fixture
                .primaryProjectID.uuidString)"}}}
            """#))
            let projectContent = (projectQuery["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
            #expect((projectContent?["meetings"] as? [[String: Any]])?.count == 2)

            let icalQuery = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"query_meetings","arguments":{"ical_uid":"roadmap@example.com"}}}
            """#))
            let icalContent = (icalQuery["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
            let icalMeetings = icalContent?["meetings"] as? [[String: Any]]
            #expect(icalMeetings?.compactMap { $0["id"] as? String } == [
                fixture.firstMeetingID.uuidString,
                fixture.recurringMeetingID.uuidString,
            ])

            let invalidProjectID = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"query_meetings","arguments":{"project_id":"not-a-uuid"}}}
            """#))
            #expect((invalidProjectID["error"] as? [String: Any])?["code"] as? Int == -32602)

            let blankIcalUID = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"query_meetings","arguments":{"ical_uid":"   "}}}
            """#))
            #expect((blankIcalUID["error"] as? [String: Any])?["code"] as? Int == -32602)
        }

        private static func json(_ line: String?) throws -> [String: Any] {
            let line = try #require(line)
            let value = try JSONSerialization.jsonObject(with: Data(line.utf8))
            return try #require(value as? [String: Any])
        }
    }

    @MainActor
    struct RestrictedMCPServerTests {
        @Test
        func exposesOnlyAllowedMeetingSummaries() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID)
            let server = DahliaMCPServer(
                store: store,
                allowedMeetingIDs: [fixture.firstMeetingID]
            )

            _ = try Self.json(server.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#))
            #expect(server.handleLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)

            let tools = try Self.json(server.handleLine(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
            let definitions = ((tools["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
            #expect(definitions.map { $0["name"] as? String } == ["get_meeting"])

            let allowed = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_meeting","arguments":{"meeting_id":"\#(fixture
                .firstMeetingID.uuidString)"}}}
            """#))
            #expect(((allowed["result"] as? [String: Any])?["structuredContent"] as? [String: Any])?["summary"] != nil)

            let deniedMeeting = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_meeting","arguments":{"meeting_id":"\#(fixture
                .secondMeetingID.uuidString)"}}}
            """#))
            #expect((deniedMeeting["error"] as? [String: Any])?["code"] as? Int == -32602)

            for (id, name) in [
                (5, "query_meetings"),
                (6, "get_meeting_transcript"),
                (7, "query_contacts"),
            ] {
                let deniedTool = try Self.json(server.handleLine("""
                {"jsonrpc":"2.0","id":\(id),"method":"tools/call","params":{"name":"\(name)","arguments":{}}}
                """))
                #expect((deniedTool["error"] as? [String: Any])?["code"] as? Int == -32602)
            }
        }

        private static func json(_ line: String?) throws -> [String: Any] {
            let line = try #require(line)
            let value = try JSONSerialization.jsonObject(with: Data(line.utf8))
            return try #require(value as? [String: Any])
        }
    }

    @MainActor
    final class Fixture {
        let databaseURL: URL
        let rootURL: URL
        let primaryVaultURL: URL
        let otherVaultURL: URL
        let manager: AppDatabaseManager
        let primaryVaultID = UUID.v7()
        let otherVaultID = UUID.v7()
        let primaryProjectID = UUID.v7()
        let firstMeetingID = UUID.v7()
        let secondMeetingID = UUID.v7()
        let recurringMeetingID = UUID.v7()
        let otherVaultMeetingID = UUID.v7()
        let firstSegmentID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondSegmentID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let firstScreenshotID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let secondScreenshotID = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
        let otherVaultScreenshotID = UUID(uuidString: "00000000-0000-0000-0000-000000000013")!
        let otherVaultProjectID = UUID.v7()
        let otherVaultSessionID = UUID.v7()
        var primaryMeetingIDs: Set<UUID> { [firstMeetingID, secondMeetingID, recurringMeetingID] }
        var projectMeetingIDs: Set<UUID> { [firstMeetingID, secondMeetingID] }
        var primaryScreenshotIDs: Set<UUID> { [firstScreenshotID, secondScreenshotID] }
        let imageData = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL9WQAAAABJRU5ErkJggg=="
        )!

        init() throws {
            rootURL = URL.temporaryDirectory.appending(path: "dahlia-meeting-access-\(UUID.v7().uuidString)")
            primaryVaultURL = rootURL.appending(path: "primary", directoryHint: .isDirectory)
            otherVaultURL = rootURL.appending(path: "other", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: primaryVaultURL.appending(path: "Acme", directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(at: otherVaultURL, withIntermediateDirectories: true)
            databaseURL = URL.temporaryDirectory
                .appending(path: "dahlia-meeting-access-\(UUID.v7().uuidString)")
                .appendingPathExtension("sqlite")
            manager = try AppDatabaseManager(path: databaseURL.path)
            let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
            let sessionID = UUID.v7()

            try manager.dbQueue.write { db in
                try insertMetadata(in: db, createdAt: createdAt, projectID: primaryProjectID)
                try insertContent(in: db, createdAt: createdAt, sessionID: sessionID)
            }
        }

        private func insertMetadata(in db: Database, createdAt: Date, projectID: UUID) throws {
            for vault in [
                VaultRecord(
                    id: primaryVaultID,
                    path: primaryVaultURL.path,
                    name: "Primary",
                    createdAt: createdAt,
                    lastOpenedAt: createdAt
                ),
                VaultRecord(
                    id: otherVaultID,
                    path: otherVaultURL.path,
                    name: "Other",
                    createdAt: createdAt,
                    lastOpenedAt: createdAt
                ),
            ] {
                try vault.insert(db)
            }
            try ProjectRecord(id: projectID, vaultId: primaryVaultID, path: "Acme", createdAt: createdAt).insert(db)
            try ProjectRecord(
                id: otherVaultProjectID,
                vaultId: otherVaultID,
                path: "Other vault project",
                createdAt: createdAt
            ).insert(db)
            try insertCalendarEvents(in: db, createdAt: createdAt)
            try insertMeetings(in: db, createdAt: createdAt, projectID: projectID)
        }

        private func insertCalendarEvents(in db: Database, createdAt: Date) throws {
            try insertCalendarEvent(
                in: db,
                createdAt: createdAt,
                icalUID: "roadmap@example.com",
                recurrenceID: "",
                title: "Roadmap review",
                startOffset: 0
            )
            try insertCalendarEvent(
                in: db,
                createdAt: createdAt,
                icalUID: "roadmap@example.com",
                recurrenceID: "20300115T000000Z",
                title: "Series follow-up",
                startOffset: 7200
            )
            try insertCalendarEvent(
                in: db,
                createdAt: createdAt,
                icalUID: "budget@example.com",
                recurrenceID: "",
                title: "Budget review",
                startOffset: 3600
            )
        }

        private func insertCalendarEvent(
            in db: Database,
            createdAt: Date,
            icalUID: String,
            recurrenceID: String,
            title: String,
            startOffset: TimeInterval
        ) throws {
            let startDate = createdAt.addingTimeInterval(startOffset)
            try CalendarEventRecord(
                now: createdAt,
                event: CalendarEvent(
                    id: "\(icalUID)-\(recurrenceID)",
                    calendarID: "work",
                    calendarName: "Work",
                    calendarColorHex: "#000000",
                    platformId: "\(icalUID)-\(recurrenceID)",
                    title: title,
                    description: "Calendar description",
                    icalUid: icalUID,
                    recurrenceId: recurrenceID,
                    startDate: startDate,
                    endDate: startDate.addingTimeInterval(3600),
                    isAllDay: false,
                    conferenceURI: nil
                ),
                key: CalendarEventKey(icalUid: icalUID, recurrenceId: recurrenceID)
            ).insert(db)
        }

        private func insertMeetings(in db: Database, createdAt: Date, projectID: UUID) throws {
            try MeetingRecord(
                id: firstMeetingID,
                vaultId: primaryVaultID,
                projectId: projectID,
                name: "AI planning title",
                description: "Product planning decisions",
                status: .ready,
                createdAt: createdAt.addingTimeInterval(20),
                updatedAt: createdAt,
                calendarEventIcalUid: "roadmap@example.com",
                calendarEventRecurrenceId: ""
            ).insert(db)
            try MeetingRecord(
                id: secondMeetingID,
                vaultId: primaryVaultID,
                projectId: projectID,
                name: "Budget 100% review",
                status: .ready,
                createdAt: createdAt.addingTimeInterval(10),
                updatedAt: createdAt,
                calendarEventIcalUid: "budget@example.com",
                calendarEventRecurrenceId: ""
            ).insert(db)
            try MeetingRecord(
                id: recurringMeetingID,
                vaultId: primaryVaultID,
                projectId: nil,
                name: "Recurring series follow-up",
                status: .ready,
                createdAt: createdAt.addingTimeInterval(5),
                updatedAt: createdAt,
                calendarEventIcalUid: "roadmap@example.com",
                calendarEventRecurrenceId: "20300115T000000Z"
            ).insert(db)
            let tag = TagRecord(name: "launch-tag", colorHex: "#808080", createdAt: createdAt)
            try tag.insert(db)
            try MeetingTagRecord(meetingId: firstMeetingID, tagId: db.lastInsertedRowID).insert(db)
            try MeetingRecord(
                id: otherVaultMeetingID,
                vaultId: otherVaultID,
                projectId: nil,
                name: "Other vault",
                status: .ready,
                createdAt: createdAt.addingTimeInterval(30),
                updatedAt: createdAt,
                calendarEventIcalUid: "roadmap@example.com",
                calendarEventRecurrenceId: ""
            ).insert(db)
        }

        private func insertContent(in db: Database, createdAt: Date, sessionID: UUID) throws {
            try SummaryRecord(
                meetingId: firstMeetingID,
                title: "AI planning title",
                document: SummaryDocument(
                    title: "AI planning title",
                    sections: [
                        SummarySection(
                            id: .v7(),
                            heading: "Summary",
                            blocks: [
                                .paragraph("Markdown secret body", transcriptRef: TranscriptReference(time: "00:00:15")),
                                .image(
                                    screenshotId: firstScreenshotID,
                                    caption: "Referenced screen",
                                    transcriptRef: TranscriptReference(time: "00:00:16")
                                ),
                            ]
                        ),
                    ]
                ).databaseJSONString(),
                createdAt: createdAt
            ).insert(db)
            try RecordingSessionRecord(
                id: sessionID,
                meetingId: firstMeetingID,
                startedAt: createdAt,
                endedAt: createdAt.addingTimeInterval(20),
                duration: 20,
                offsetSeconds: 10,
                createdAt: createdAt,
                updatedAt: createdAt
            ).insert(db)
            try RecordingSessionRecord(
                id: otherVaultSessionID,
                meetingId: otherVaultMeetingID,
                startedAt: createdAt,
                endedAt: createdAt.addingTimeInterval(20),
                duration: 20,
                offsetSeconds: 1000,
                createdAt: createdAt,
                updatedAt: createdAt
            ).insert(db)
            try TranscriptSegmentRecord(
                id: firstSegmentID,
                meetingId: firstMeetingID,
                sessionId: sessionID,
                startTime: createdAt.addingTimeInterval(5),
                endTime: createdAt.addingTimeInterval(7),
                text: "Original secret body",
                translatedText: "Translated text",
                isConfirmed: true,
                speakerLabel: "mic"
            ).insert(db)
            try TranscriptSegmentRecord(
                id: secondSegmentID,
                meetingId: firstMeetingID,
                sessionId: sessionID,
                startTime: createdAt.addingTimeInterval(5),
                endTime: createdAt.addingTimeInterval(8),
                text: "Second original body",
                translatedText: nil,
                isConfirmed: true,
                speakerLabel: "system"
            ).insert(db)
            try TranscriptSegmentRecord(
                id: .v7(),
                meetingId: firstMeetingID,
                sessionId: sessionID,
                startTime: createdAt.addingTimeInterval(8),
                text: "Unconfirmed text",
                translatedText: nil,
                isConfirmed: false,
                speakerLabel: nil
            ).insert(db)
            try MeetingScreenshotRecord(
                id: firstScreenshotID,
                meetingId: firstMeetingID,
                sessionId: sessionID,
                capturedAt: createdAt.addingTimeInterval(6),
                imageData: imageData,
                mimeType: "image/png"
            ).insert(db)
            try MeetingScreenshotRecord(
                id: secondScreenshotID,
                meetingId: firstMeetingID,
                capturedAt: createdAt.addingTimeInterval(25),
                imageData: imageData,
                mimeType: "image/png"
            ).insert(db)
            try MeetingScreenshotRecord(
                id: otherVaultScreenshotID,
                meetingId: otherVaultMeetingID,
                sessionId: otherVaultSessionID,
                capturedAt: createdAt.addingTimeInterval(6),
                imageData: imageData,
                mimeType: "image/png"
            ).insert(db)
        }

        deinit {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: rootURL)
        }

        func store(vaultID: UUID, allowsWrites: Bool = false) throws -> MeetingAccessStore {
            try MeetingAccessStore(
                databaseURL: databaseURL,
                vaultID: vaultID,
                allowsWrites: allowsWrites
            )
        }

        func updateFirstScreenshot(data: Data) throws {
            try manager.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE screenshots SET imageData = ? WHERE id = ?",
                    arguments: [data, firstScreenshotID]
                )
            }
        }

        func insertPausedSessionContent() throws -> (segmentID: UUID, screenshotID: UUID) {
            let sessionID = UUID.v7()
            let segmentID = UUID.v7()
            let screenshotID = UUID.v7()
            let base = Date(timeIntervalSince1970: 1_800_000_000)
            let startedAt = base.addingTimeInterval(100)
            try manager.dbQueue.write { db in
                try RecordingSessionRecord(
                    id: sessionID,
                    meetingId: firstMeetingID,
                    startedAt: startedAt,
                    endedAt: startedAt.addingTimeInterval(10),
                    duration: 10,
                    offsetSeconds: 30,
                    createdAt: startedAt,
                    updatedAt: startedAt
                ).insert(db)
                try TranscriptSegmentRecord(
                    id: segmentID,
                    meetingId: firstMeetingID,
                    sessionId: sessionID,
                    startTime: startedAt.addingTimeInterval(5),
                    endTime: startedAt.addingTimeInterval(6),
                    text: "After pause",
                    translatedText: nil,
                    isConfirmed: true,
                    speakerLabel: "mic"
                ).insert(db)
                try MeetingScreenshotRecord(
                    id: screenshotID,
                    meetingId: firstMeetingID,
                    sessionId: sessionID,
                    capturedAt: startedAt.addingTimeInterval(6),
                    imageData: imageData,
                    mimeType: "image/png"
                ).insert(db)
            }
            return (segmentID, screenshotID)
        }

        func corruptPrimaryProjectAssociation() throws {
            try manager.dbQueue.write { db in
                try db.execute(sql: "DROP TRIGGER IF EXISTS meetings_validate_project_vault_update")
                try db.execute(
                    sql: "UPDATE meetings SET projectId = ? WHERE id = ?",
                    arguments: [otherVaultProjectID, firstMeetingID]
                )
            }
        }

        func corruptPrimarySessionAssociation() throws {
            try manager.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE transcript_segments SET sessionId = ? WHERE id = ?",
                    arguments: [otherVaultSessionID, firstSegmentID]
                )
            }
        }

        func corruptPrimaryScreenshotSessionAssociation() throws {
            try manager.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE screenshots SET sessionId = ? WHERE id = ?",
                    arguments: [otherVaultSessionID, firstScreenshotID]
                )
            }
        }
    }
#endif
