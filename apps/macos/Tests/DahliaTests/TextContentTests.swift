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
            let page = try store.screenshots(meetingID: meetingId)
            #expect(page.screenshots.first(where: { $0.id == screenshotId })?.isReferencedInSummary == true)
            let image = try store.screenshot(meetingID: meetingId, screenshotID: screenshotId)
            #expect(image.metadata.isReferencedInSummary)
            #expect(calls.withLock { $0 } == 2)
            #expect(throws: MeetingAccessError.meetingNotFound) { try store.screenshots(meetingID: fixture.otherWorkspaceMeetingID) }
            #expect(calls.withLock { $0 } == 2)
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
