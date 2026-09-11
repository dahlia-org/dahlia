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
        func publicMCPUsesTypedIDsAndPreservesDatabaseUUIDs() throws {
            let fixture = try Fixture()
            let server = try DahliaMCPServer(store: fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true))
            _ = server.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)
            _ = server.handleLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
            func call(_ name: String, _ arguments: [String: Any]) throws -> [String: Any] {
                let bytes = try JSONSerialization.data(withJSONObject: [
                    "jsonrpc": "2.0",
                    "id": "opaque-jsonrpc-id",
                    "method": "tools/call",
                    "params": ["name": name, "arguments": arguments],
                ])
                let response = try Self.json(server.handleLine(String(decoding: bytes, as: UTF8.self)))
                #expect(response["id"] as? String == "opaque-jsonrpc-id")
                return response
            }
            func body(_ response: [String: Any]) throws -> [String: Any] {
                let result = try #require(response["result"] as? [String: Any])
                #expect(result["isError"] as? Bool == false)
                return try #require(result["structuredContent"] as? [String: Any])
            }
            let recordingID = UUID.v7()
            let info = TranscriptInfo(
                id: .v7(), startedAt: nil, endedAt: nil,
                metadata: .init(provider: "apple", model: "apple-speech", runs: [
                    .init(startedAt: nil, recordingSessionId: recordingID), .init(startedAt: nil),
                ])
            )
            try fixture.manager.dbQueue.write { try TranscriptRecord(meetingId: fixture.firstMeetingID, info: info).save($0) }
            let meetingID = TypeID.encode(fixture.firstMeetingID, as: .meeting)
            let projectID = TypeID.encode(fixture.primaryProjectID, as: .project)
            let tools = try Self.json(server.handleLine(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
            let definitions = ((tools["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
            let assignmentTools = definitions.filter {
                ["set_meeting_project_assignment", "remove_meeting_project_assignment"]
                    .contains($0["name"] as? String ?? "")
            }
            #expect(assignmentTools.count == 2)
            #expect(assignmentTools.allSatisfy {
                let annotations = $0["annotations"] as? [String: Any]
                return annotations?["destructiveHint"] as? Bool == true
                    && annotations?["idempotentHint"] as? Bool == true
            })
            for invalid in [fixture.firstMeetingID.uuidString, TypeID.encode(fixture.firstMeetingID, as: .project)] {
                #expect(try (call("get_meeting", ["meeting_id": invalid])["error"] as? [String: Any])?["code"] as? Int == -32602)
            }
            let detail = try body(call("get_meeting", ["meeting_id": meetingID]))
            #expect((detail["meeting"] as? [String: Any])?["id"] as? String == meetingID)
            #expect((detail["vault"] as? [String: Any])?["id"] as? String == TypeID.encode(fixture.primaryVaultID, as: .vault))
            let transcript = try body(call("get_meeting_transcript", ["meeting_id": meetingID, "limit": 1]))
            #expect(((transcript["segments"] as? [[String: Any]])?.first?["id"] as? String)?.hasPrefix("seg_") == true)
            let descriptor = try #require(transcript["transcript"] as? [String: Any])
            let metadata = try #require(descriptor["metadata"] as? [String: Any])
            let runs = try #require(metadata["runs"] as? [[String: Any]])
            #expect(runs.first?["recording_session_id"] as? String == TypeID.encode(recordingID, as: .recording))
            #expect(runs.last?["recording_session_id"] == nil)
            #expect(try fixture.manager.dbQueue.read {
                try TranscriptRecord.current(fixture.firstMeetingID, in: $0)?.metadata?.runs.first?.recordingSessionId
            } == recordingID)
            let cursor = try #require(transcript["next_cursor"] as? String)
            let next = try body(call("get_meeting_transcript", ["meeting_id": meetingID, "limit": 1, "cursor": cursor]))
            #expect((next["segments"] as? [[String: Any]])?.count == 1)

            let removed = try body(call("remove_meeting_project_assignment", [
                "meeting_id": meetingID,
                "expected_project_id": projectID,
            ]))
            #expect(removed["changed"] as? Bool == true)
            #expect(removed["changed_meeting_ids"] as? [String] == [meetingID])
            #expect(try fixture.manager.dbQueue.read {
                try MeetingRecord.fetchOne($0, key: fixture.firstMeetingID)?.projectId
            } == nil)
            let assigned = try body(call("set_meeting_project_assignment", [
                "meeting_id": meetingID,
                "expected_project_id": NSNull(),
                "project_id": projectID,
            ]))
            #expect(assigned["project_id"] as? String == projectID)
            #expect(try fixture.manager.dbQueue.read {
                try MeetingRecord.fetchOne($0, key: fixture.firstMeetingID)?.projectId
            } == fixture.primaryProjectID)
        }

        @Test
        func createsProjectWithoutALocalExportFolder() throws {
            let fixture = try Fixture()
            try fixture.manager.dbQueue.write { db in
                try db.execute(sql: "UPDATE vaults SET path = NULL WHERE id = ?", arguments: [fixture.primaryVaultID])
            }
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)

            let created = try store.createProject(
                name: "Database only",
                parentProjectID: nil,
                projectType: .undefined
            )

            #expect(created.project.name == "Database only")
        }

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
        func projectSiblingIdentityUsesUUIDDespiteEquivalentNames() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            let first = try store.createProject(
                name: "Équipe",
                parentProjectID: nil,
                projectType: .customer
            )

            let second = try store.createProject(
                name: "e\u{301}QUIPE",
                parentProjectID: nil,
                projectType: .customer
            )

            #expect(first.project.projectID != second.project.projectID)
        }

        @Test
        func projectCreateAllowsDuplicateSiblingWithoutFilesystemMutation() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            try FileManager.default.removeItem(at: fixture.primaryVaultURL.appending(path: "Acme"))

            let created = try store.createProject(
                name: "acme",
                parentProjectID: nil,
                projectType: .customer
            )

            #expect(created.project.projectID != fixture.primaryProjectID)
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
                try SummaryContent(
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
                try SummaryContent(
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
        func querySearchesMetadataPaginatesAndNeverCrossesVaults() async throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID)
            await fixture.manager.searchIndexer.drain()

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
            #expect(try store.queryMeetings(MeetingQuery(query: "Acme")).meetings.isEmpty)
            #expect(try store.queryMeetings(MeetingQuery(query: "Acme", simple: true)).meetings.isEmpty)
            #expect(try store.queryMeetings(MeetingQuery(query: "anning")).meetings.isEmpty)
            #expect(try store.queryMeetings(MeetingQuery(query: "anning", simple: true)).meetings.map(\.id) == [fixture.firstMeetingID])
            #expect(throws: MeetingAccessError.invalidSearchQuery(maximum: 1024)) {
                try store.queryMeetings(MeetingQuery(query: String(repeating: "a", count: 1025)))
            }
            let literalWildcardMatch = try store.queryMeetings(MeetingQuery(query: "%", simple: true))
            #expect(literalWildcardMatch.meetings.map(\.id) == [fixture.secondMeetingID])
            #expect(try store.queryMeetings(MeetingQuery(query: "_", simple: true)).meetings.isEmpty)
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
            #expect(try store.queryMeetings(MeetingQuery(query: "secret body")).meetings.map(\.id) == [fixture.firstMeetingID])
            #expect(try store.queryMeetings(MeetingQuery(query: "cret bo", simple: true)).meetings.isEmpty)
            #expect(!firstPage.meetings.contains { $0.id == fixture.otherVaultMeetingID })

            let otherStore = try fixture.store(vaultID: fixture.otherVaultID)
            #expect(try otherStore.queryMeetings(MeetingQuery(query: "secret body")).meetings.isEmpty)
            #expect(throws: MeetingAccessError.invalidCursor) {
                try otherStore.queryMeetings(MeetingQuery(cursor: cursor))
            }
        }

        @Test
        func fullTextSearchRejectsFailedOrChangedIndex() async throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID)
            await fixture.manager.searchIndexer.drain()

            let firstPage = try store.queryMeetings(.init(query: "review", limit: 1))
            let cursor = try #require(firstPage.nextCursor)
            try await fixture.manager.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE search_index_state SET indexRevision = indexRevision + 1 WHERE indexKind = 'fts'"
                )
            }
            #expect(throws: MeetingAccessError.invalidCursor) {
                try store.queryMeetings(.init(query: "review", limit: 1, cursor: cursor))
            }

            try await fixture.manager.dbQueue.write { db in
                try db.execute(sql: "UPDATE search_index_state SET phase = 'metadata' WHERE indexKind = 'fts'")
            }
            #expect(throws: MeetingAccessError.searchUnavailable) {
                try store.queryMeetings(.init(query: "planning"))
            }

            try await fixture.manager.dbQueue.write { db in
                try db.execute(sql: "UPDATE search_index_state SET phase = 'failed' WHERE indexKind = 'fts'")
            }
            #expect(throws: MeetingAccessError.searchUnavailable) {
                try store.queryMeetings(.init(query: "planning"))
            }
            #expect(try store.queryMeetings(.init(query: "planning", simple: true)).meetings.map(\.id) == [fixture.firstMeetingID])
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
            #expect(segment.speaker == nil)
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
        func staleTranscriptKeepsItsResidentGenerationUntilHydration() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID)
            var resident = TranscriptInfo(
                id: .v7(), startedAt: nil, endedAt: nil,
                metadata: .init(provider: "apple", model: "apple-speech-live", runs: [.init(startedAt: nil)])
            )
            resident.version = 1
            resident.syncRevision = 1
            var incoming = TranscriptInfo(
                id: .v7(), startedAt: nil, endedAt: .now,
                metadata: .init(provider: "apple", model: "apple-speech", runs: [.init(startedAt: nil)])
            )
            incoming.version = 2
            incoming.syncRevision = 2
            let observation = try SyncJSON.decoder.decode(SyncCanonicalPayload.self, from: JSONSerialization.data(withJSONObject: [
                "contentOmitted": true, "contentPresent": true, "contentCount": 2,
                "transcript": JSONSerialization.jsonObject(with: SyncJSON.encoder.encode(incoming)),
            ]))
            try fixture.manager.dbQueue.write { db in
                try TranscriptRecord(meetingId: fixture.firstMeetingID, info: resident).save(db)
                try db.execute(sql: """
                INSERT INTO sync_content_state(vaultId, entity, entityId, residentRevision, complete, present)
                VALUES (?, 'transcript', ?, 1, 1, 1);
                INSERT INTO sync_entity_state(vaultId, entity, entityId, confirmedRevision)
                VALUES (?, 'transcript', ?, 2);
                """, arguments: [fixture.primaryVaultID, fixture.firstMeetingID, fixture.primaryVaultID, fixture.firstMeetingID])
                _ = try TextContentStore.observe(
                    entity: .transcript, id: fixture.firstMeetingID, vaultId: fixture.primaryVaultID, value: observation, in: db
                )
                #expect(try TranscriptRecord.current(fixture.firstMeetingID, in: db)?.metadata?.request.model == "apple-speech-live")
            }
            let stale = try store.transcript(meetingID: fixture.firstMeetingID)
            #expect(stale.textContent?.state == .stale)
            #expect(stale.transcript?.id == resident.id)
            #expect(stale.transcript?.version == 1)
            #expect(stale.segments.contains { $0.text == "Original secret body" })

            try fixture.manager.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE transcript_segment_bodies SET text = 'new generation' WHERE segmentId = ?",
                    arguments: [fixture.firstSegmentID]
                )
                let fingerprint = try #require(try TextContentStore.fingerprint(entity: .transcript, id: fixture.firstMeetingID, in: db))
                var manifest = TextContentManifest(
                    version: 1, entity: .transcript, entityId: fixture.firstMeetingID, revision: 2,
                    present: true, count: fingerprint.count, byteCount: fingerprint.bytes, sha256: fingerprint.hash
                )
                manifest.transcript = incoming
                try TextContentStore.markVerified(manifest, source: .init(
                    vaultId: fixture.primaryVaultID, connectionId: .v7(), origin: "https://hydration.invalid",
                    generation: 0, revision: 2, checksum: nil
                ), accessed: false, in: db)
            }
            let hydrated = try store.transcript(meetingID: fixture.firstMeetingID)
            #expect(hydrated.textContent?.state == .ready)
            #expect(hydrated.transcript?.id == incoming.id)
            #expect(hydrated.transcript?.version == 2)
            #expect(hydrated.segments.contains { $0.text == "new generation" })
        }

        @Test
        func transcriptEndElapsedSecondsUsesTheSamePrecisionAsStart() throws {
            let fixture = try Fixture()
            let endedAt = Date(timeIntervalSince1970: 1_800_000_007.123_456)
            try fixture.manager.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE transcript_segments SET endedAt = ? WHERE id = ?",
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
            #expect(image.mimeType == "image/webp")
            let source = CGImageSourceCreateWithData(image.imageData as CFData, nil)
            let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
            #expect((properties?[kCGImagePropertyPixelWidth] as? Int ?? 0) <= 1280)
            #expect((properties?[kCGImagePropertyPixelHeight] as? Int ?? 0) <= 1280)
            #expect(throws: MeetingAccessError.screenshotNotFound) {
                try store.screenshot(meetingID: fixture.firstMeetingID, screenshotID: fixture.otherVaultScreenshotID)
            }
        }

        @Test
        func screenshotTextSearchReturnsImagesWithoutMergingMeetings() async throws {
            let fixture = try Fixture()
            await fixture.manager.searchIndexer.drain()
            try await fixture.manager.dbQueue.write { db in
                let text = "Screenshot-only architecture needle"
                let caption = "Architecture diagram for the meeting"
                try db.execute(
                    sql: "UPDATE file_text_bodies SET ocrText = ?, caption = ? WHERE fileId = ?",
                    arguments: [text, caption, fixture.firstScreenshotID]
                )
                let meeting = try #require(try MeetingRecord.fetchOne(db, key: fixture.firstMeetingID))
                try upsertDocument(
                    SearchDocumentProjection(
                        kind: "screenshot",
                        sourceID: fixture.firstScreenshotID,
                        vaultID: fixture.primaryVaultID,
                        meetingID: fixture.firstMeetingID,
                        projectID: meeting.projectId,
                        fields: SearchDocumentFields(
                            title: "",
                            description: "",
                            calendar: "",
                            tags: "",
                            projectPath: "",
                            ocr: text,
                            caption: caption
                        )
                    ),
                    generation: 1,
                    in: db
                )
            }
            let store = try fixture.store(vaultID: fixture.primaryVaultID)
            #expect(throws: MeetingAccessError.searchQueryTooShort(minimum: 2)) {
                try store.queryScreenshots(ScreenshotTextQuery(query: "a"))
            }
            let screenshots = try store.queryScreenshots(ScreenshotTextQuery(query: "architecture needle"))
            let meetings = try store.queryMeetings(MeetingQuery(query: "architecture needle"))

            #expect(screenshots.screenshots.map(\.id) == [fixture.firstScreenshotID])
            #expect(screenshots.screenshots.first?.meetingID == fixture.firstMeetingID)
            #expect(screenshots.screenshots.first?.detectedText == "Screenshot-only architecture needle")
            #expect(screenshots.screenshots.first?.caption == "Architecture diagram for the meeting")
            #expect(meetings.meetings.isEmpty)
        }

        @Test
        func screenshotCacheMissUsesImageResolverWithoutOmittingTheImage() throws {
            let fixture = try Fixture()
            let vaultID = fixture.primaryVaultID
            let meetingID = fixture.firstMeetingID
            let imageID = fixture.firstScreenshotID
            let bytes = try fixture.manager.dbQueue.write { db in
                let bytes = try #require(try Data.fetchOne(db, sql: "SELECT imageData FROM meeting_images WHERE id = ?", arguments: [imageID]))
                try db.execute(sql: "DELETE FROM file_migration_content WHERE fileId = ?", arguments: [imageID])
                return bytes
            }
            let store = try MeetingAccessStore(databaseURL: fixture.databaseURL, vaultID: vaultID, imageResolver: { vault, meeting, image in
                #expect(vault == vaultID && meeting == meetingID && image == imageID)
                return bytes
            })
            #expect(try store.screenshot(meetingID: meetingID, screenshotID: imageID, originalSize: true).imageData == bytes)
            let unavailable = try fixture.store(vaultID: vaultID)
            #expect(throws: MeetingAccessError.screenshotUnavailable) {
                try unavailable.screenshot(meetingID: meetingID, screenshotID: imageID, originalSize: true)
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
            #expect(properties[kCGImagePropertyPixelWidth] as? Int == 1280)
            #expect(properties[kCGImagePropertyPixelHeight] as? Int == 320)

            let original = try store.screenshot(
                meetingID: fixture.firstMeetingID,
                screenshotID: fixture.firstScreenshotID,
                originalSize: true
            )
            #expect(original.imageData == largeData)
            #expect(original.mimeType == ImageEncoder.mimeType(for: largeData))
            let originalSource = try #require(CGImageSourceCreateWithData(original.imageData as CFData, nil))
            let originalProperties = try #require(
                CGImageSourceCopyPropertiesAtIndex(originalSource, 0, nil) as? [CFString: Any]
            )
            #expect(originalProperties[kCGImagePropertyPixelWidth] as? Int == 2048)
            #expect(originalProperties[kCGImagePropertyPixelHeight] as? Int == 512)

            try fixture.updateFirstScreenshot(data: Data("not an image".utf8))
            #expect(throws: MeetingAccessError.screenshotEncodingFailed) {
                try store.screenshot(meetingID: fixture.firstMeetingID, screenshotID: fixture.firstScreenshotID)
            }

            #expect(throws: MeetingAccessError.screenshotEncodingFailed) {
                try store.screenshotImages(
                    meetingID: fixture.firstMeetingID,
                    query: ScreenshotQuery(fromElapsedSeconds: 0, toElapsedSeconds: 100)
                )
            }
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
            #expect(try store.queryMeetings(MeetingQuery(query: "Other vault project", simple: true)).meetings.isEmpty)
            #expect(try store.queryMeetings(MeetingQuery(projectID: fixture.otherVaultProjectID)).meetings.isEmpty)
            let transcript = try store.transcript(meetingID: fixture.firstMeetingID)
            let segment = try #require(transcript.segments.first(where: { $0.id == fixture.firstSegmentID }))
            #expect(segment.elapsedSeconds == 0)
            let screenshots = try store.screenshots(meetingID: fixture.firstMeetingID)
            #expect(screenshots.screenshots.first(where: { $0.id == fixture.firstScreenshotID })?.elapsedSeconds == 0)
        }

        @Test
        func internalMCPReportsOnlyCoarseToolUsageCategories() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            var events: [MCPUsageTelemetryEvent] = []
            let server = DahliaMCPServer(
                store: store,
                telemetryOrigin: .codexChat,
                usageTelemetryReporter: { events.append($0) }
            )
            _ = server.handleInternalTestLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
            _ = server.handleInternalTestLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)

            _ = server.handleInternalTestLine(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"query_meetings","arguments":{}}}"#)
            _ = server.handleInternalTestLine(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"query_projects","arguments":{}}}"#)
            _ = server
                .handleInternalTestLine(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"update_meeting_summary","arguments":{}}}"#)
            _ = server.handleInternalTestLine(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"not_a_tool","arguments":{}}}"#)

            #expect(events == [
                .init(origin: .codexChat, category: .meeting, operation: .read, outcome: .completed),
                .init(origin: .codexChat, category: .project, operation: .read, outcome: .completed),
                .init(origin: .codexChat, category: .meeting, operation: .write, outcome: .failed),
                .init(origin: .codexChat, category: .unknown, operation: .write, outcome: .failed),
            ])
            #expect(events[0].signalName == "Dahlia.MCP.ToolCall.completed")
            #expect(events[0].parameters == [
                "origin": "codexChat",
                "category": "meeting",
                "operation": "read",
            ])

            var externalEvents: [MCPUsageTelemetryEvent] = []
            let externalServer = DahliaMCPServer(
                store: store,
                usageTelemetryReporter: { externalEvents.append($0) }
            )
            _ = externalServer.handleInternalTestLine(#"{"jsonrpc":"2.0","id":8,"method":"initialize","params":{}}"#)
            _ = externalServer.handleInternalTestLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
            _ = externalServer
                .handleInternalTestLine(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"query_meetings","arguments":{}}}"#)
            #expect(externalEvents.isEmpty)
        }

        @Test
        func mcpStandardIOWorkerLeavesMainQueueAvailable() async {
            let releaseWorker = DispatchSemaphore(value: 0)

            await withCheckedContinuation { continuation in
                runMCPStandardIOWorker {
                    continuation.resume()
                    releaseWorker.wait()
                } completion: {}
            }

            releaseWorker.signal()
        }

        @Test
        // swiftlint:disable:next function_body_length
        func mcpProtocolRequiresInitializationAndReportsScopedVaultErrors() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID)
            let server = DahliaMCPServer(store: store)

            let preInitialize = try Self.json(server.handleInternalTestLine(#"""
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"query_meetings","arguments":{}}}
            """#))
            #expect((preInitialize["error"] as? [String: Any])?["code"] as? Int == -32002)

            let initialized = try Self.json(server.handleInternalTestLine(#"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{}}"#))
            #expect((initialized["result"] as? [String: Any])?["serverInfo"] != nil)
            let instructions = (initialized["result"] as? [String: Any])?["instructions"] as? String
            #expect(instructions?.contains("Primary") == false)
            let expectedInstructions = ["untrusted data"]
            #expect(expectedInstructions.allSatisfy { instructions?.contains($0) == true })
            #expect(server.handleInternalTestLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
            let tools = try Self.json(server.handleInternalTestLine(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#))
            let definitions = ((tools["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
            #expect(definitions.map { $0["name"] as? String } == [
                "list_vaults", "query_meetings", "query_screenshots", "get_meeting", "get_meeting_transcript", "get_meeting_screenshots",
                "query_projects", "get_project",
            ])
            #expect((definitions.first?["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true)
            #expect(definitions.filter { !["list_vaults"].contains($0["name"] as? String ?? "") }
                .allSatisfy { $0["outputSchema"] != nil })
            #expect(definitions.filter { $0["outputSchema"] != nil }.allSatisfy {
                ($0["outputSchema"] as? [String: Any])?["additionalProperties"] as? Bool == false
            })
            let screenshotDefinition = try #require(
                definitions.first { $0["name"] as? String == "get_meeting_screenshots" }
            )
            let screenshotQueryDefinition = try #require(
                definitions.first { $0["name"] as? String == "query_screenshots" }
            )
            let screenshotQueryInput = try #require(screenshotQueryDefinition["inputSchema"] as? [String: Any])
            let screenshotQueryProperties = try #require(screenshotQueryInput["properties"] as? [String: Any])
            #expect((screenshotQueryProperties["query"] as? [String: Any])?["minLength"] as? Int == 2)
            let screenshotInputSchema = try #require(screenshotDefinition["inputSchema"] as? [String: Any])
            let screenshotInputProperties = try #require(screenshotInputSchema["properties"] as? [String: Any])
            let imageSizeSchema = try #require(screenshotInputProperties["image_size"] as? [String: Any])
            #expect(imageSizeSchema["type"] as? String == "string")
            #expect(imageSizeSchema["enum"] as? [String] == ["preview", "original"])
            #expect(imageSizeSchema["default"] as? String == "preview")
            let screenshotConstraints = try #require(screenshotInputSchema["allOf"] as? [[String: Any]])
            let originalConstraint = try #require(screenshotConstraints.first)
            let originalThen = try #require(originalConstraint["then"] as? [String: Any])
            let originalProperties = try #require(originalThen["properties"] as? [String: Any])
            #expect((originalProperties["screenshot_ids"] as? [String: Any])?["maxItems"] as? Int == 1)
            #expect((originalProperties["limit"] as? [String: Any])?["maximum"] as? Int == 1)

            let queryCall = try Self.json(server.handleInternalTestLine(#"""
            {"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"query_meetings","arguments":{"query":"planning","simple":true}}}
            """#))
            let queryResult = try #require(queryCall["result"] as? [String: Any])
            #expect(queryResult["isError"] as? Bool == false)
            #expect((queryResult["structuredContent"] as? [String: Any])?["meetings"] != nil)

            let meetingCall = try Self.json(server.handleInternalTestLine(#"""
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

            let transcriptCall = try Self.json(server.handleInternalTestLine(#"""
            {"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"get_meeting_transcript","arguments":{"meeting_id":"\#(fixture
                .firstMeetingID.uuidString)","limit":1}}}
            """#))
            let transcriptContent = ((transcriptCall["result"] as? [String: Any])?["structuredContent"] as? [String: Any])
            #expect(transcriptContent?["segments"] != nil)
            #expect(transcriptContent?["next_cursor"] is String)

            let screenshotCall = try Self.json(server.handleInternalTestLine(#"""
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

            let rangedScreenshotCall = try Self.json(server.handleInternalTestLine(#"""
            {"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"get_meeting_screenshots","arguments":{"meeting_id":"\#(fixture
                .firstMeetingID.uuidString)","from_elapsed_seconds":15,"to_elapsed_seconds":17}}}
            """#))
            let rangedContent = ((rangedScreenshotCall["result"] as? [String: Any])?["content"] as? [[String: Any]])
            #expect(rangedContent?.map { $0["type"] as? String } == ["text", "text", "image"])

            let missingSelector = try Self.json(server.handleInternalTestLine(#"""
            {"jsonrpc":"2.0","id":15,"method":"tools/call","params":{"name":"get_meeting_screenshots","arguments":{"meeting_id":"\#(fixture
                .firstMeetingID.uuidString)"}}}
            """#))
            #expect((missingSelector["error"] as? [String: Any])?["code"] as? Int == -32602)

            let invalid = try Self.json(server.handleInternalTestLine(#"""
            {"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"query_meetings","arguments":{"unexpected":true}}}
            """#))
            #expect((invalid["error"] as? [String: Any])?["code"] as? Int == -32602)
            let unknown = try Self.json(server.handleInternalTestLine(#"""
            {"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"unknown","arguments":{}}}
            """#))
            #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32602)
            let nonObjectArguments = try Self.json(server.handleInternalTestLine(#"""
            {"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"query_meetings","arguments":"invalid"}}
            """#))
            #expect((nonObjectArguments["error"] as? [String: Any])?["code"] as? Int == -32602)
            let invalidVersion = try Self.json(server.handleInternalTestLine(#"""
            {"jsonrpc":"1.0","id":11,"method":"ping"}
            """#))
            #expect((invalidVersion["error"] as? [String: Any])?["code"] as? Int == -32600)

            let missingVaultStore = try fixture.store(vaultID: UUID.v7())
            let missingVaultServer = DahliaMCPServer(store: missingVaultStore)
            let missing = try Self.json(missingVaultServer.handleInternalTestLine(#"{"jsonrpc":"2.0","id":4,"method":"initialize","params":{}}"#))
            #expect((missing["error"] as? [String: Any])?["code"] as? Int == -32000)
        }

        @Test
        func mcpScreenshotImageSizeOptionSelectsPreviewOrOriginalBytes() throws {
            let fixture = try Fixture()
            let largeImage = try #require(Self.makeImage(width: 2048, height: 512))
            let largeData = try #require(ImageEncoder.encode(largeImage, quality: 0.9))
            try fixture.updateFirstScreenshot(data: largeData)
            let server = try DahliaMCPServer(store: fixture.store(vaultID: fixture.primaryVaultID))
            _ = server.handleInternalTestLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
            _ = server.handleInternalTestLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)

            func call(id: Int = 2, arguments: [String: Any]) throws -> [String: Any] {
                let request: [String: Any] = [
                    "jsonrpc": "2.0",
                    "id": id,
                    "method": "tools/call",
                    "params": ["name": "get_meeting_screenshots", "arguments": arguments],
                ]
                let requestData = try JSONSerialization.data(withJSONObject: request)
                let requestString = try #require(String(data: requestData, encoding: .utf8))
                return try Self.json(server.handleInternalTestLine(requestString))
            }

            func screenshotData(imageSize: String?, selectsByRange: Bool = false) throws -> Data {
                var arguments: [String: Any] = ["meeting_id": fixture.firstMeetingID.uuidString]
                if selectsByRange {
                    arguments["from_elapsed_seconds"] = 15
                    arguments["to_elapsed_seconds"] = 17
                } else {
                    arguments["screenshot_ids"] = [fixture.firstScreenshotID.uuidString]
                }
                if let imageSize {
                    arguments["image_size"] = imageSize
                }
                let response = try call(arguments: arguments)
                let result = try #require(response["result"] as? [String: Any])
                let content = try #require(result["content"] as? [[String: Any]])
                let image = try #require(content.first { $0["type"] as? String == "image" })
                let encoded = try #require(image["data"] as? String)
                return try #require(Data(base64Encoded: encoded))
            }

            #expect(try screenshotData(imageSize: nil) != largeData)
            #expect(try screenshotData(imageSize: "preview") != largeData)
            #expect(try screenshotData(imageSize: "original") == largeData)
            #expect(try screenshotData(imageSize: "original", selectsByRange: true) == largeData)

            let invalidResponse = try call(id: 3, arguments: [
                "meeting_id": fixture.firstMeetingID.uuidString,
                "screenshot_ids": [fixture.firstScreenshotID.uuidString],
                "image_size": "large",
            ])
            #expect((invalidResponse["error"] as? [String: Any])?["code"] as? Int == -32602)

            let multipleOriginals = try call(id: 4, arguments: [
                "meeting_id": fixture.firstMeetingID.uuidString,
                "screenshot_ids": [fixture.firstScreenshotID.uuidString, fixture.secondScreenshotID.uuidString],
                "image_size": "original",
            ])
            #expect((multipleOriginals["error"] as? [String: Any])?["code"] as? Int == -32602)

            let rangedOriginals = try call(id: 5, arguments: [
                "meeting_id": fixture.firstMeetingID.uuidString,
                "from_elapsed_seconds": 0,
                "to_elapsed_seconds": 100,
                "limit": 2,
                "image_size": "original",
            ])
            #expect((rangedOriginals["error"] as? [String: Any])?["code"] as? Int == -32602)
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
                simple: true,
                limit: 1
            )).nextCursor)
            #expect(throws: MeetingAccessError.invalidCursor) {
                try store.queryMeetings(.init(
                    query: "Plan",
                    simple: true,
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
            _ = server.handleInternalTestLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
            _ = server.handleInternalTestLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
            let response = try Self.json(server.handleInternalTestLine(#"""
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
                return try Self.json(server.handleInternalTestLine(String(decoding: data, as: UTF8.self)))
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
            _ = server.handleInternalTestLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
            _ = server.handleInternalTestLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
            let response = try Self.json(server.handleInternalTestLine(#"""
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
        func v24DatabaseRequiresOpeningDahliaForMeetingAccess() throws {
            let databaseURL = URL.temporaryDirectory
                .appending(path: "dahlia-meeting-access-v24-\(UUID.v7().uuidString)")
                .appendingPathExtension("sqlite")
            defer { try? FileManager.default.removeItem(at: databaseURL) }
            let vault = VaultRecord(id: .v7(), path: "/tmp/before-v25", name: "Before v25", createdAt: .now, lastOpenedAt: .now)
            let queue = try DatabaseQueue(path: databaseURL.path)
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v24_projectWorkspaceHierarchy")
            try queue.write { db in
                try insertLegacyVault(vault, in: db)
            }
            let store = try MeetingAccessStore(databaseURL: databaseURL, vaultID: vault.id)

            #expect(throws: MeetingAccessError.databaseUpgradeRequired) {
                try store.scopedVault()
            }
        }

        @Test
        func v34DatabaseRequiresOpeningDahliaForSearchSchema() throws {
            let databaseURL = URL.temporaryDirectory
                .appending(path: "dahlia-meeting-access-v34-\(UUID.v7().uuidString)")
                .appendingPathExtension("sqlite")
            defer { try? FileManager.default.removeItem(at: databaseURL) }
            let vault = VaultRecord(id: .v7(), path: "/tmp/before-v35", name: "Before v35", createdAt: .now, lastOpenedAt: .now)
            let queue = try DatabaseQueue(path: databaseURL.path)
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v34_meetingRecordingStartedAt")
            try queue.write { try insertLegacyVault(vault, in: $0) }
            let store = try MeetingAccessStore(databaseURL: databaseURL, vaultID: vault.id)

            #expect(throws: MeetingAccessError.databaseUpgradeRequired) {
                try store.scopedVault()
            }
            #expect(throws: MeetingAccessError.databaseUpgradeRequired) {
                try store.queryMeetings(.init(query: "meeting"))
            }
        }

        @Test
        func v35DatabaseRequiresOpeningDahliaForSummarySearchSchema() throws {
            let databaseURL = URL.temporaryDirectory
                .appending(path: "dahlia-meeting-access-v35-\(UUID.v7().uuidString)")
                .appendingPathExtension("sqlite")
            defer { try? FileManager.default.removeItem(at: databaseURL) }
            let vault = VaultRecord(id: .v7(), path: "/tmp/before-v36", name: "Before v36", createdAt: .now, lastOpenedAt: .now)
            let queue = try DatabaseQueue(path: databaseURL.path)
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v35_searchDocuments")
            try queue.write { try insertLegacyVault(vault, in: $0) }
            let store = try MeetingAccessStore(databaseURL: databaseURL, vaultID: vault.id)

            #expect(throws: MeetingAccessError.databaseUpgradeRequired) {
                try store.scopedVault()
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
        func exposesRelationshipKeys() async throws {
            let fixture = try Fixture()
            await fixture.manager.searchIndexer.drain()
            let server = try DahliaMCPServer(store: fixture.store(vaultID: fixture.primaryVaultID))

            let initialized = try Self.json(server.handleInternalTestLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#))
            let instructions = try #require((initialized["result"] as? [String: Any])?["instructions"] as? String)
            #expect(instructions.contains("ical_uid"))
            #expect(instructions.contains("project_id"))
            #expect(instructions.contains("transcripts or screenshots only when supporting evidence is needed"))
            #expect(server.handleInternalTestLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)

            let tools = try Self.json(server.handleInternalTestLine(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
            let definitions = ((tools["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
            let queryDefinition = try #require(definitions.first { $0["name"] as? String == "query_meetings" })
            let queryDescription = try #require(queryDefinition["description"] as? String)
            #expect(queryDescription.contains("Omit unused properties entirely; do not send empty strings"))
            #expect(queryDescription.contains("Project names and paths are not searched by query"))
            let inputSchema = try #require(queryDefinition["inputSchema"] as? [String: Any])
            let inputProperties = try #require(inputSchema["properties"] as? [String: Any])
            let queryProperty = try #require(inputProperties["query"] as? [String: Any])
            #expect((queryProperty["description"] as? String)?.contains("use project or project_id instead") == true)
            #expect(inputProperties["ical_uid"] != nil)
            #expect(inputProperties["project_id"] != nil)
            #expect(inputProperties["simple"] != nil)
            #expect(!definitions.contains { $0["name"] as? String == "query_customer_intelligence_proposals" })
            let outputSchema = try #require(queryDefinition["outputSchema"] as? [String: Any])
            let outputProperties = try #require(outputSchema["properties"] as? [String: Any])
            let meetingsSchema = try #require(outputProperties["meetings"] as? [String: Any])
            let meetingSchema = try #require(meetingsSchema["items"] as? [String: Any])
            let meetingProperties = try #require(meetingSchema["properties"] as? [String: Any])
            #expect(meetingProperties["project_id"] != nil)
            #expect(meetingProperties["ical_uid"] != nil)
            #expect(meetingProperties["recurrence_id"] != nil)

            let metadataQuery = try Self.json(server.handleInternalTestLine(#"""
            {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"query_meetings","arguments":{"query":"planning"}}}
            """#))
            let metadataContent = (metadataQuery["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
            let meeting = try #require((metadataContent?["meetings"] as? [[String: Any]])?.first)
            #expect(meeting["project_id"] as? String == fixture.primaryProjectID.uuidString)
            #expect(meeting["ical_uid"] as? String == "roadmap@example.com")
            #expect((meeting["recurrence_id"] as? String)?.isEmpty == true)

            let simpleQuery = try Self.json(server.handleInternalTestLine(#"""
            {"jsonrpc":"2.0","id":31,"method":"tools/call","params":{"name":"query_meetings","arguments":{
                "query":"anning","simple":true
            }}}
            """#))
            let simpleContent = (simpleQuery["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
            #expect((simpleContent?["meetings"] as? [[String: Any]])?.first?["id"] as? String == fixture.firstMeetingID.uuidString)

            for (id, simple) in [(32, false), (33, true)] {
                let summaryQuery = try Self.json(server.handleInternalTestLine(#"""
                {"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"query_meetings","arguments":{
                    "query":"\#(simple ? "cret bo" : "secret body")","simple":\#(simple)
                }}}
                """#))
                let summaryContent = (summaryQuery["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
                let meetings = summaryContent?["meetings"] as? [[String: Any]]
                #expect(simple ? meetings?.isEmpty == true : meetings?.first?["id"] as? String == fixture.firstMeetingID.uuidString)
            }

            let projectQuery = try Self.json(server.handleInternalTestLine(#"""
            {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"query_meetings","arguments":{"project_id":"\#(fixture
                .primaryProjectID.uuidString)"}}}
            """#))
            let projectContent = (projectQuery["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
            #expect((projectContent?["meetings"] as? [[String: Any]])?.count == 2)

            let icalQuery = try Self.json(server.handleInternalTestLine(#"""
            {"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"query_meetings","arguments":{"ical_uid":"roadmap@example.com"}}}
            """#))
            let icalContent = (icalQuery["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
            let icalMeetings = icalContent?["meetings"] as? [[String: Any]]
            #expect(icalMeetings?.compactMap { $0["id"] as? String } == [
                fixture.firstMeetingID.uuidString,
                fixture.recurringMeetingID.uuidString,
            ])

            let invalidProjectID = try Self.json(server.handleInternalTestLine(#"""
            {"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"query_meetings","arguments":{"project_id":"not-a-uuid"}}}
            """#))
            #expect((invalidProjectID["error"] as? [String: Any])?["code"] as? Int == -32602)

            let blankFilters = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"query_meetings","arguments":{
                "created_before":"","created_from":" ","cursor":"","ical_uid":"   ",
                "limit":50,"project":"","project_id":"","query":""
            }}}
            """#))
            #expect(blankFilters["error"] == nil)
            #expect((blankFilters["result"] as? [String: Any])?["structuredContent"] != nil)

            for invalidTypedArguments in [#"{"limit":""}"#] {
                let invalidTypedValue = try Self.json(server.handleInternalTestLine(#"""
                {"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"query_meetings","arguments":\#(invalidTypedArguments)}}
                """#))
                #expect((invalidTypedValue["error"] as? [String: Any])?["code"] as? Int == -32602)
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
            try SummaryContent(
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
            try TranscriptContent(
                id: firstSegmentID,
                meetingId: firstMeetingID,
                sessionId: sessionID,
                startTime: createdAt.addingTimeInterval(5),
                endTime: createdAt.addingTimeInterval(7),
                text: "Original secret body",
                translatedText: "Translated text",
                isConfirmed: true,
                audioSource: "mic"
            ).insert(db)
            try TranscriptContent(
                id: secondSegmentID,
                meetingId: firstMeetingID,
                sessionId: sessionID,
                startTime: createdAt.addingTimeInterval(5),
                endTime: createdAt.addingTimeInterval(8),
                text: "Second original body",
                translatedText: nil,
                isConfirmed: true,
                audioSource: "system"
            ).insert(db)
            try TranscriptContent(
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
            ).insertLegacyForTesting(db)
            try MeetingScreenshotRecord(
                id: secondScreenshotID,
                meetingId: firstMeetingID,
                capturedAt: createdAt.addingTimeInterval(25),
                imageData: imageData,
                mimeType: "image/png"
            ).insertLegacyForTesting(db)
            try MeetingScreenshotRecord(
                id: otherVaultScreenshotID,
                meetingId: otherVaultMeetingID,
                sessionId: otherVaultSessionID,
                capturedAt: createdAt.addingTimeInterval(6),
                imageData: imageData,
                mimeType: "image/png"
            ).insertLegacyForTesting(db)
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
                    sql: "UPDATE file_migration_content SET imageData = ? WHERE fileId = ?",
                    arguments: [data, firstScreenshotID]
                )
            }
        }

        func insertVaultExport(meetingID: UUID, relativePath: String) throws {
            let now = Date()
            try manager.dbQueue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO summary_exports (meetingId, type, url, createdAt, updatedAt)
                    VALUES (?, 'vault', ?, ?, ?)
                    """,
                    arguments: [meetingID, "vault:///\(relativePath)", now, now]
                )
            }
        }

        func storedDocument(meetingID: UUID) throws -> String {
            try manager.dbQueue.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT document FROM summary_bodies WHERE meetingId = ?",
                    arguments: [meetingID]
                )
            } ?? ""
        }

        func replaceSummaryDocument(meetingID: UUID, document: SummaryDocument) throws {
            try replaceSummaryDocument(meetingID: meetingID, databaseJSON: document.databaseJSONString())
        }

        func replaceSummaryDocument(meetingID: UUID, databaseJSON: String) throws {
            try manager.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE summary_bodies SET document = ? WHERE meetingId = ?",
                    arguments: [databaseJSON, meetingID]
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
                try TranscriptContent(
                    id: segmentID,
                    meetingId: firstMeetingID,
                    sessionId: sessionID,
                    startTime: startedAt.addingTimeInterval(5),
                    endTime: startedAt.addingTimeInterval(6),
                    text: "After pause",
                    translatedText: nil,
                    isConfirmed: true,
                    audioSource: "mic"
                ).insert(db)
                try MeetingScreenshotRecord(
                    id: screenshotID,
                    meetingId: firstMeetingID,
                    sessionId: sessionID,
                    capturedAt: startedAt.addingTimeInterval(6),
                    imageData: imageData,
                    mimeType: "image/png"
                ).insertLegacyForTesting(db)
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
                    sql: "UPDATE meeting_attachments SET sessionId = ? WHERE id = ?",
                    arguments: [otherVaultSessionID, firstScreenshotID]
                )
            }
        }
    }
#endif
