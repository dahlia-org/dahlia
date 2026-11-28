#if canImport(Testing)
    import DahliaMeetingAccess
    import DahliaRuntimeSupport
    import Foundation
    import GRDB
    import Synchronization
    import Testing
    @testable import Dahlia

    @MainActor
    struct TextContentTests {

        @Test
        func screenshotReadsResolveNonresidentSummaryReferencesOutsideSQLite() throws {
            let fixture = try Fixture()
            let workspaceId = fixture.primaryWorkspaceID
            let meetingId = fixture.firstMeetingID
            let screenshotId = fixture.firstScreenshotID
            let response = try JSONEncoder().encode(fixture.store(workspaceID: workspaceId).meeting(id: meetingId))
            try fixture.manager.dbQueue.write { db in
                let connection = DahliaAccountConnectionRecord(id: .v7(), origin: "https://references.invalid", clientID: "test", createdAt: .now)
                try connection.insert(db)
                try db.execute(
                    sql: """
                    UPDATE workspaces SET accountConnectionId = ?, organizationId = COALESCE(organizationId, id),
                    syncRole = COALESCE(syncRole, 'admin'), syncConfirmedConnectionId = ? WHERE id = ?
                    """,
                    arguments: [connection.id, connection.id, workspaceId]
                )
                try db.execute(
                    sql: "INSERT INTO sync_content_state(workspace_id, entity, entityId) VALUES (?, 'summary', ?)",
                    arguments: [workspaceId, meetingId]
                )
                try db.execute(sql: "DELETE FROM summary_bodies WHERE meetingId = ?", arguments: [meetingId])
            }
            let calls = Mutex(0)
            let store = try MeetingAccessStore(
                databaseURL: fixture.databaseURL,
                workspaceID: workspaceId,
                textResolver: { requestedWorkspace, request in
                    #expect(requestedWorkspace == workspaceId)
                    #expect(request.operation == .meeting)
                    #expect(request.meetingId == meetingId)
                    calls.withLock { $0 += 1 }
                    // Return the leased broker result without installing a local body, as if it were evicted immediately after IPC.
                    return response
                }
            )
            let image = try #require(store.screenshots(ids: [screenshotId]).images.first)
            #expect(image.metadata.isReferencedInSummary)
            #expect(calls.withLock { $0 } == 1)
            #expect(throws: MeetingAccessError.meetingNotFound) {
                try store.queryScreenshots(ScreenshotTextQuery(meetingID: fixture.otherWorkspaceMeetingID))
            }
            // Listing does not need the summary references, so it never asks the broker.
            _ = try store.queryScreenshots(ScreenshotTextQuery(meetingID: meetingId))
            #expect(calls.withLock { $0 } == 1)
        }

        @Test
        func screenshotSummaryFailureDoesNotDiscardOtherMeetingsImages() throws {
            let fixture = try Fixture()
            let workspaceID = fixture.primaryWorkspaceID
            let meetingID = fixture.firstMeetingID
            let document = try fixture.manager.dbQueue.write { db in
                let document = try #require(try String.fetchOne(
                    db, sql: "SELECT document FROM summary_bodies WHERE meetingId = ?", arguments: [meetingID]
                ))
                try db.execute(
                    sql: "UPDATE meeting_attachments SET meetingId = ?, sessionId = NULL WHERE id = ?",
                    arguments: [fixture.secondMeetingID, fixture.secondScreenshotID]
                )
                try db.execute(
                    sql: "INSERT INTO sync_content_state(workspace_id, entity, entityId) VALUES (?, 'summary', ?)",
                    arguments: [workspaceID, meetingID]
                )
                try db.execute(sql: "DELETE FROM summary_bodies WHERE meetingId = ?", arguments: [meetingID])
                return document
            }
            let store = try MeetingAccessStore(
                databaseURL: fixture.databaseURL, workspaceID: workspaceID,
                textResolver: { _, _ in throw TextContentError.unavailable }
            )
            for includeImages in [true, false] {
                let result = try store.screenshots(
                    ids: [fixture.firstScreenshotID, fixture.secondScreenshotID], includeImages: includeImages
                )
                #expect(result.list.screenshots.map(\.id) == [fixture.secondScreenshotID])
                #expect(result.list.errors.count == 1)
                #expect(result.list.errors.first?.index == 0)
                #expect(result.list.errors.first?.screenshotID == fixture.firstScreenshotID)
                #expect(result.list.errors.first?.error == .unavailable)
            }
            try fixture.manager.dbQueue.write { db in
                try db.execute(sql: "INSERT INTO summary_bodies(meetingId, document) VALUES (?, ?)", arguments: [meetingID, document])
                try db.execute(sql: "DELETE FROM sync_content_state WHERE entity = 'summary' AND entityId = ?", arguments: [meetingID])
            }
            let retried = try store.screenshots(ids: [fixture.firstScreenshotID, fixture.secondScreenshotID])
            #expect(retried.list.screenshots.map(\.id) == [fixture.firstScreenshotID, fixture.secondScreenshotID])
            #expect(retried.list.errors.isEmpty)
        }

        @Test
        func swiftAndServerUseIdenticalHashFraming() throws {
            struct Fixture: Decodable {
                struct Field: Decodable { let value: String?
                    let body: Bool
                }

                let fields: [Field]
                let sha256: String
                let byteCount: Int
            }
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let fixtures = try JSONDecoder().decode(
                [Fixture].self,
                from: Data(contentsOf: root.appendingPathComponent("test-fixtures/text-content-v1.json"))
            )
            #expect(fixtures.count == 4)
            for fixture in fixtures {
                var digest = TextContentDigest()
                for field in fixture.fields {
                    digest.add(field.value, body: field.body)
                }
                #expect(digest.digestHex() == fixture.sha256)
                #expect(digest.byteCount == fixture.byteCount)
            }
        }
    }
#endif
