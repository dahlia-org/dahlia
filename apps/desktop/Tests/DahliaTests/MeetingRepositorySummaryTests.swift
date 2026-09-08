import DahliaMeetingAccess
import Foundation
import GRDB
@testable import Dahlia
@testable import DahliaRuntimeSupport

#if canImport(Testing)
    import Testing

    @MainActor
    struct MeetingRepositorySummaryTests {
        @Test
        func canonicalSummaryMergesTagsWithoutEchoAcrossReplay() throws {
            let context = try makeRepositoryContext()
            try context.repo.addTag(name: "manual", toMeetingId: context.meeting.id, colorHex: "#123456")
            let document = try SummaryDocument(title: "Remote", sections: [], tags: ["team", "team", "manual"]).databaseJSONString()
            let data = try JSONSerialization.data(withJSONObject: [
                "title": "Remote", "document": document, "createdAt": "2026-01-01T00:00:00Z",
            ])
            let payload = try SyncJSON.decoder.decode(SyncCanonicalPayload.self, from: data)
            try context.manager.dbQueue.write { db in
                let transactions = try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_transactions")
                for _ in 0 ..< 2 {
                    try SyncTransactionQueue.applyCanonical(
                        .summary,
                        id: context.meeting.id,
                        vaultId: context.meeting.vaultId,
                        value: payload,
                        in: db
                    )
                }
                #expect(try String.fetchAll(db, sql: "SELECT name FROM tags ORDER BY name") == ["manual", "team"])
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM meeting_tags") == 2)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_transactions") == transactions)
                try db.execute(sql: "DELETE FROM meeting_tags WHERE tagId IN (SELECT id FROM tags WHERE name = 'team')")
                try SyncTransactionQueue.applyCanonical(.summary, id: context.meeting.id, vaultId: context.meeting.vaultId, value: payload, in: db)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM meeting_tags") == 1)
            }
        }

        @Test
        func generatedSummaryDoesNotManageLegacyActionItems() throws {
            let context = try makeRepositoryContext()
            let legacyActionItemId = UUID.v7()

            try context.manager.dbQueue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO action_items (id, meetingId, title, assignee, isCompleted)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: [legacyActionItemId, context.meeting.id, "Legacy task", "me", true]
                )
            }

            let document = SummaryDocument(
                title: "Weekly sync",
                description: "Planning and launch decisions",
                sections: [
                    SummarySection(id: UUID.v7(), heading: "Summary", blocks: [.paragraph("Summary body")]),
                ],
                tags: ["team"]
            )

            try context.repo.applyGeneratedSummary(
                toMeetingId: context.meeting.id,
                document: document,
                tags: ["team"]
            )

            let result = try context.manager.dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: "SELECT title, assignee, isCompleted FROM action_items WHERE meetingId = ?",
                    arguments: [context.meeting.id]
                )
            }
            let fetchedSummary = try context.repo.fetchSummary(forMeetingId: context.meeting.id)
            let summary = try #require(fetchedSummary)

            #expect(try summary.loadDocument() == document)
            let meeting = try #require(try context.repo.fetchMeeting(id: context.meeting.id))
            #expect(meeting.name == "Weekly sync")
            #expect(meeting.description == "Planning and launch decisions")
            #expect(result.count == 1)
            #expect(result.first?["title"] == "Legacy task")
            #expect(result.first?["assignee"] == "me")
            #expect(result.first?["isCompleted"] == true)
        }

        @Test
        func invalidSummaryDocumentThrows() {
            let record = SummaryContent(
                meetingId: UUID.v7(),
                title: "Invalid",
                document: "not-json",
                createdAt: .now
            )

            #expect(throws: DecodingError.self) {
                try record.loadDocument()
            }
        }

        @Test(arguments: [false, true], [Int?.none, 1, 2])
        func canonicalRevisionInvalidatesOnlyOlderExports(omitsBody: Bool, revision: Int?) throws {
            let context = try makeRepositoryContext()
            let old = try SummaryDocument(title: "Old", sections: []).databaseJSONString()
            let document = try SummaryDocument(title: revision == 2 ? "New" : "Old", sections: []).databaseJSONString()
            try context.manager.dbQueue.write { db in
                try SummaryContent(meetingId: context.meeting.id, title: "Old", document: old, createdAt: .now).save(db)
                try SummaryExportRecord.setURL(
                    "https://docs.google.com/document/d/old/edit",
                    meetingId: context.meeting.id,
                    type: .googleDocs,
                    in: db
                )
                try db.execute(
                    sql: "INSERT INTO sync_entity_state(vaultId, entity, entityId, confirmedRevision) VALUES (?, 'summary', ?, 1)",
                    arguments: [context.vault.id, context.meeting.id]
                )
                var payload: [String: Any] = ["title": "Remote", "createdAt": "2026-01-01T00:00:00Z"]
                if omitsBody {
                    payload["contentOmitted"] = true
                    payload["contentPresent"] = true
                } else {
                    payload["document"] = document
                }
                let value = try SyncJSON.decoder.decode(SyncCanonicalPayload.self, from: JSONSerialization.data(withJSONObject: payload))
                try SyncTransactionQueue.applyCanonical(
                    .summary,
                    id: context.meeting.id,
                    vaultId: context.vault.id,
                    value: value,
                    remoteRevision: revision,
                    in: db
                )
                let export = try SummaryExportRecord.fetchOne(meetingId: context.meeting.id, type: .googleDocs, in: db)
                #expect((export == nil) == (revision == 2))
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_transactions") == 0)
            }
        }

        @Test
        func regeneratingSummaryClearsStaleExportLocations() throws {
            let context = try makeRepositoryContext()
            let oldDocument = try SummaryDocument(title: "Old", sections: []).databaseJSONString()
            try context.repo.upsertSummary(
                SummaryContent(
                    meetingId: context.meeting.id,
                    title: "Old",
                    document: oldDocument,
                    createdAt: .now
                )
            )
            try context.repo.updateSummaryVaultRelativePath(
                forMeetingId: context.meeting.id,
                relativePath: "Acme/Existing.md"
            )
            #expect(try context.repo.updateSummaryGoogleFileId(
                forMeetingId: context.meeting.id,
                googleFileId: "old-google-file",
                expectedDocument: oldDocument
            ))
            let document = SummaryDocument(
                title: "Updated",
                sections: [SummarySection(id: .v7(), heading: "Summary", blocks: [.paragraph("New body")])],
                tags: []
            )

            try context.repo.applyGeneratedSummary(
                toMeetingId: context.meeting.id,
                document: document,
                tags: []
            )

            #expect(try context.repo.fetchSummaryExport(
                forMeetingId: context.meeting.id,
                type: .vault
            ) == nil)
            #expect(try context.repo.fetchSummaryExport(
                forMeetingId: context.meeting.id,
                type: .googleDocs
            ) == nil)
        }

        @Test
        func storesVaultAndGoogleDocsExportsIndependently() throws {
            let context = try makeRepositoryContext()
            let document = try SummaryDocument(title: "Summary", sections: []).databaseJSONString()
            try context.repo.upsertSummary(
                SummaryContent(
                    meetingId: context.meeting.id,
                    title: "Summary",
                    document: document,
                    createdAt: .now
                )
            )

            try context.repo.updateSummaryVaultRelativePath(
                forMeetingId: context.meeting.id,
                relativePath: "Acme/Summary.md"
            )
            #expect(try context.repo.updateSummaryGoogleFileId(
                forMeetingId: context.meeting.id,
                googleFileId: "google-123",
                expectedDocument: document
            ))

            let vault = try context.repo.fetchSummaryExport(
                forMeetingId: context.meeting.id,
                type: .vault
            )
            let googleDocs = try context.repo.fetchSummaryExport(
                forMeetingId: context.meeting.id,
                type: .googleDocs
            )

            #expect(vault?.url == "vault:///Acme/Summary.md")
            #expect(vault?.vaultRelativePath == "Acme/Summary.md")
            #expect(googleDocs?.url == "https://docs.google.com/document/d/google-123/edit")

            try context.repo.updateSummaryVaultRelativePath(
                forMeetingId: context.meeting.id,
                relativePath: nil
            )

            #expect(try context.repo.fetchSummaryExport(
                forMeetingId: context.meeting.id,
                type: .vault
            ) == nil)
            #expect(try context.repo.fetchSummaryExport(
                forMeetingId: context.meeting.id,
                type: .googleDocs
            )?.googleDocumentID == "google-123")
        }

        @Test
        func rejectsGoogleDocsAssociationWhenSummaryChangedDuringExport() throws {
            let context = try makeRepositoryContext()
            let exportedDocument = SummaryDocument(title: "Exported", sections: [])
            try context.repo.applyGeneratedSummary(
                toMeetingId: context.meeting.id,
                document: exportedDocument,
                tags: []
            )
            let expectedDocument = try exportedDocument.databaseJSONString()

            try context.repo.applyGeneratedSummary(
                toMeetingId: context.meeting.id,
                document: SummaryDocument(title: "Corrected while exporting", sections: []),
                tags: []
            )

            #expect(try !context.repo.updateSummaryGoogleFileId(
                forMeetingId: context.meeting.id,
                googleFileId: "stale-google-document",
                expectedDocument: expectedDocument
            ))
            #expect(try context.repo.fetchSummaryExport(
                forMeetingId: context.meeting.id,
                type: .googleDocs
            ) == nil)
        }

        @Test
        func regeneratingSummaryUpdatesMeetingMetadataAndKeepsNameForBlankTitle() throws {
            let context = try makeRepositoryContext()
            try context.repo.applyGeneratedSummary(
                toMeetingId: context.meeting.id,
                document: SummaryDocument(
                    title: "Renamed\nby AI",
                    description: "First description",
                    sections: []
                ),
                tags: []
            )
            try context.repo.applyGeneratedSummary(
                toMeetingId: context.meeting.id,
                document: SummaryDocument(
                    title: "  ",
                    description: "  ",
                    sections: []
                ),
                tags: []
            )

            let meeting = try #require(try context.repo.fetchMeeting(id: context.meeting.id))
            #expect(meeting.name == "Renamed by AI")
            #expect(meeting.description == "First description")
        }

        @Test
        func deletingScreenshotsPreservesImagesReferencedBySummary() async throws {
            let context = try makeRepositoryContext()
            let referencedScreenshot = MeetingScreenshotRecord(
                id: .v7(),
                meetingId: context.meeting.id,
                capturedAt: .now,
                imageData: Data([0x89, 0x50, 0x4E, 0x47]),
                mimeType: "image/png"
            )
            let unreferencedScreenshot = MeetingScreenshotRecord(
                id: .v7(),
                meetingId: context.meeting.id,
                capturedAt: .now.addingTimeInterval(1),
                imageData: Data([0x89, 0x50, 0x4E, 0x47]),
                mimeType: "image/png"
            )
            try await context.manager.dbQueue.write { db in
                try referencedScreenshot.insertLegacyForTesting(db)
                try unreferencedScreenshot.insertLegacyForTesting(db)
            }
            let caption = SummaryText("Launch screen", transcriptRef: TranscriptReference(time: "00:00:42"))
            let document = SummaryDocument(
                title: "Summary",
                sections: [
                    SummarySection(
                        id: .v7(),
                        heading: "Launch",
                        blocks: [.image(screenshotId: referencedScreenshot.id, caption: caption)]
                    ),
                ]
            )
            try context.repo.applyGeneratedSummary(
                toMeetingId: context.meeting.id,
                document: document,
                tags: []
            )

            let deletedScreenshots = try await context.repo.deleteScreenshots(
                ids: [referencedScreenshot.id, unreferencedScreenshot.id],
                meetingId: context.meeting.id
            )

            #expect(deletedScreenshots.map(\.id) == [unreferencedScreenshot.id])
            #expect(try context.repo.fetchScreenshots(forMeetingId: context.meeting.id).map(\.id) == [referencedScreenshot.id])
            #expect(try context.repo.fetchSummary(forMeetingId: context.meeting.id)?.loadDocument() == document)
        }

        @Test
        func deletingUnreferencedScreenshotDoesNotChangeSummaryDocument() async throws {
            let context = try makeRepositoryContext()
            let screenshot = MeetingScreenshotRecord(
                id: .v7(),
                meetingId: context.meeting.id,
                capturedAt: .now,
                imageData: Data([0x89, 0x50, 0x4E, 0x47]),
                mimeType: "image/png"
            )
            try await context.manager.dbQueue.write { db in
                try screenshot.insertLegacyForTesting(db)
            }
            let document = SummaryDocument(
                title: "Summary",
                sections: [SummarySection(id: .v7(), heading: "Notes", blocks: [.paragraph("No screenshot reference")])]
            )
            try context.repo.upsertSummary(SummaryContent(
                meetingId: context.meeting.id,
                title: document.title,
                document: document.databaseJSONString(),
                createdAt: .now
            ))

            let deletedScreenshots = try await context.repo.deleteScreenshots(
                ids: [screenshot.id],
                meetingId: context.meeting.id
            )

            #expect(deletedScreenshots.map(\.id) == [screenshot.id])
            #expect(try context.repo.fetchSummary(forMeetingId: context.meeting.id)?.loadDocument() == document)
        }

        private func makeRepositoryContext() throws -> RepositoryContext {
            let manager = try AppDatabaseManager(path: ":memory:")
            let repo = MeetingRepository(dbQueue: manager.dbQueue)

            let vault = VaultRecord(
                id: .v7(),
                path: "/tmp/test-vault",
                name: "Test Vault",
                createdAt: Date(),
                lastOpenedAt: Date()
            )
            try repo.insertVault(vault)

            let project = try repo.fetchOrCreateProject(name: "Acme", vaultId: vault.id)

            let meeting = MeetingRecord(
                id: .v7(),
                vaultId: vault.id,
                projectId: project.id,
                name: "Weekly sync",
                createdAt: Date(),
                updatedAt: Date()
            )
            try manager.dbQueue.write { db in
                try meeting.insert(db)
            }

            return RepositoryContext(manager: manager, repo: repo, vault: vault, project: project, meeting: meeting)
        }

        private struct RepositoryContext {
            let manager: AppDatabaseManager
            let repo: MeetingRepository
            let vault: VaultRecord
            let project: ProjectRecord
            let meeting: MeetingRecord
        }
    }
#endif
