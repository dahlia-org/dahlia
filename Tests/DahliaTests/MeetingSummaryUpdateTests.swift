import Foundation
import GRDB
@testable import Dahlia
@testable import DahliaMeetingAccess
@testable import DahliaRuntimeSupport

#if canImport(Testing)
    import Testing

    @MainActor
    // swiftlint:disable:next type_body_length
    struct MeetingSummaryUpdateTests {
        @Test
        func replacesDocumentAndPropagatesMeetingMetadata() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            let before = try store.meeting(id: fixture.firstMeetingID)
            let version = try #require(before.summaryDocumentVersion)
            let corrected = Self.document(title: "Corrected planning title", body: "Tanaka approved the plan")

            let result = try store.updateMeetingSummary(
                meetingID: fixture.firstMeetingID,
                expectedDocumentVersion: version,
                document: corrected
            )

            #expect(result.changed)
            #expect(result.title == "Corrected planning title")
            #expect(result.description == "One line description")
            #expect(result.vaultExport == .notExported)
            #expect(result.staleExports.isEmpty)

            let stored = try fixture.manager.dbQueue.read { db in
                try Row.fetchOne(
                    db,
                    sql: """
                    SELECT summaries.title AS summaryTitle, summaries.document AS document,
                           summaries.createdAt AS summaryCreatedAt,
                           meetings.name AS meetingName, meetings.description AS meetingDescription
                    FROM summaries JOIN meetings ON meetings.id = summaries.meetingId
                    WHERE summaries.meetingId = ?
                    """,
                    arguments: [fixture.firstMeetingID]
                )
            }
            let row = try #require(stored)
            let document: String = row["document"]
            let summaryTitle: String = row["summaryTitle"]
            let meetingName: String = row["meetingName"]
            let meetingDescription: String? = row["meetingDescription"]
            let summaryCreatedAt: Date = row["summaryCreatedAt"]
            #expect(try document == (corrected.databaseJSONString()))
            #expect(summaryTitle == "Corrected planning title")
            #expect(meetingName == "Corrected planning title")
            #expect(meetingDescription == "One line description")
            // 生成日時は再生成でも維持される値なので、更新でも動かさない。
            #expect(summaryCreatedAt == Date(timeIntervalSince1970: 1_800_000_000))

            let reloadedVersion = try #require(store.meeting(id: fixture.firstMeetingID).summaryDocumentVersion)
            #expect(result.documentVersion == reloadedVersion)
        }

        @Test
        func blankDocumentMetadataClearsMeetingMetadata() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            let version = try #require(store.meeting(id: fixture.firstMeetingID).summaryDocumentVersion)
            var corrected = Self.document(title: "   ", body: "Corrected body")
            corrected.description = "\n"

            let result = try store.updateMeetingSummary(
                meetingID: fixture.firstMeetingID,
                expectedDocumentVersion: version,
                document: corrected
            )

            #expect(result.title.isEmpty)
            #expect(result.description.isEmpty)
            let metadata = try fixture.manager.dbQueue.read { db in
                try Row.fetchOne(
                    db,
                    sql: "SELECT name, description FROM meetings WHERE id = ?",
                    arguments: [fixture.firstMeetingID]
                )
            }
            let row = try #require(metadata)
            let name: String = row["name"]
            let description: String? = row["description"]
            #expect(name.isEmpty)
            #expect(description == "")
        }

        @Test
        func addsDocumentTagsWithoutRemovingExistingTags() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            try fixture.manager.dbQueue.write { db in
                try db.execute(sql: "INSERT INTO tags (name, colorHex, createdAt) VALUES ('manual', '#123456', ?)", arguments: [Date()])
                try db.execute(
                    sql: "INSERT INTO meeting_tags (meetingId, tagId) VALUES (?, ?)",
                    arguments: [fixture.firstMeetingID, db.lastInsertedRowID]
                )
            }
            let version = try #require(store.meeting(id: fixture.firstMeetingID).summaryDocumentVersion)
            var document = Self.document(title: "Tagged", body: "Body")
            document.tags = ["release"]

            _ = try store.updateMeetingSummary(
                meetingID: fixture.firstMeetingID,
                expectedDocumentVersion: version,
                document: document
            )

            let names = try fixture.manager.dbQueue.read { db in
                try String.fetchAll(
                    db,
                    sql: """
                    SELECT tags.name FROM tags
                    JOIN meeting_tags ON meeting_tags.tagId = tags.id
                    WHERE meeting_tags.meetingId = ? ORDER BY tags.name
                    """,
                    arguments: [fixture.firstMeetingID]
                )
            }
            #expect(names == ["launch-tag", "manual", "release"])
        }

        @Test
        func rewritesExportedVaultMarkdownInPlace() throws {
            let fixture = try Fixture()
            let relativePath = "Acme/2027-01-01-AI-planning-title.md"
            let fileURL = fixture.primaryVaultURL.appending(path: relativePath)
            try Data("stale contents".utf8).write(to: fileURL)
            try fixture.insertVaultExport(meetingID: fixture.firstMeetingID, relativePath: relativePath)

            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            let version = try #require(store.meeting(id: fixture.firstMeetingID).summaryDocumentVersion)
            let corrected = Self.document(title: "Corrected planning title", body: "Tanaka approved the plan")

            let result = try store.updateMeetingSummary(
                meetingID: fixture.firstMeetingID,
                expectedDocumentVersion: version,
                document: corrected
            )

            #expect(result.vaultExport == .updated)
            let written = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(written.contains("Tanaka approved the plan"))
            #expect(written.contains("title: \"Corrected planning title\""))
            // タイトルが変わってもファイル名は変えない。Obsidian のリンクを壊さないため。
            #expect(FileManager.default.fileExists(atPath: fileURL.path))
            let storedURL = try fixture.manager.dbQueue.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT url FROM summary_exports WHERE meetingId = ? AND type = 'vault'",
                    arguments: [fixture.firstMeetingID]
                )
            }
            #expect(storedURL == "vault:///\(relativePath)")
        }

        @Test
        func rendersTheSameMarkdownAsTheApplicationExportPath() throws {
            let fixture = try Fixture()
            let relativePath = "Acme/2027-01-01-AI-planning-title.md"
            let fileURL = fixture.primaryVaultURL.appending(path: relativePath)
            try Data("stale".utf8).write(to: fileURL)
            try fixture.insertVaultExport(meetingID: fixture.firstMeetingID, relativePath: relativePath)

            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            let version = try #require(store.meeting(id: fixture.firstMeetingID).summaryDocumentVersion)
            var document = Self.document(title: "Screenshot summary", body: "Body")
            document.sections[0].blocks.append(.image(screenshotId: fixture.firstScreenshotID, caption: "Shot"))

            _ = try store.updateMeetingSummary(
                meetingID: fixture.firstMeetingID,
                expectedDocumentVersion: version,
                document: document
            )

            let screenshots = try fixture.manager.dbQueue.read { db in
                try MeetingScreenshotRecord
                    .filter(Column("meetingId") == fixture.firstMeetingID)
                    .fetchAll(db)
            }
            let expected = ObsidianMarkdownSummaryRenderer.render(
                document: document,
                context: SummaryRenderContext(
                    meetingId: fixture.firstMeetingID,
                    createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                    screenshots: screenshots
                )
            ).markdown

            let written = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(written == expected)
        }

        @Test
        func reportsFileMissingWhenTheExportedMarkdownIsGone() throws {
            let fixture = try Fixture()
            try fixture.insertVaultExport(meetingID: fixture.firstMeetingID, relativePath: "Acme/absent.md")
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            let version = try #require(store.meeting(id: fixture.firstMeetingID).summaryDocumentVersion)

            let result = try store.updateMeetingSummary(
                meetingID: fixture.firstMeetingID,
                expectedDocumentVersion: version,
                document: Self.document(title: "Still stored", body: "Body")
            )

            #expect(result.vaultExport == .fileMissing)
            #expect(result.changed)
        }

        @Test
        func reportsGoogleDocsExportAsStale() throws {
            let fixture = try Fixture()
            try fixture.manager.dbQueue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO summary_exports (meetingId, type, url, createdAt, updatedAt)
                    VALUES (?, 'google_docs', 'https://docs.google.com/document/d/abc/edit', ?, ?)
                    """,
                    arguments: [fixture.firstMeetingID, Date(), Date()]
                )
            }
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            let version = try #require(store.meeting(id: fixture.firstMeetingID).summaryDocumentVersion)

            let result = try store.updateMeetingSummary(
                meetingID: fixture.firstMeetingID,
                expectedDocumentVersion: version,
                document: Self.document(title: "Corrected", body: "Body")
            )

            #expect(result.staleExports == ["google_docs"])
        }

        @Test
        func includesExportCreatedBetweenPlanningAndCommitInStaleExports() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            let version = try #require(store.meeting(id: fixture.firstMeetingID).summaryDocumentVersion)
            let plan = try store.database.read { db in
                try store.makeSummaryUpdatePlan(
                    meetingID: fixture.firstMeetingID,
                    expectedDocumentVersion: version,
                    document: Self.document(title: "Corrected", body: "Corrected body"),
                    vaultURL: fixture.primaryVaultURL,
                    in: db
                )
            }
            guard case let .apply(update) = plan else {
                Issue.record("Expected the changed document to produce an update plan")
                return
            }
            try fixture.manager.dbQueue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO summary_exports (meetingId, type, url, createdAt, updatedAt)
                    VALUES (?, 'google_docs', 'https://docs.google.com/document/d/late/edit', ?, ?)
                    """,
                    arguments: [fixture.firstMeetingID, Date(), Date()]
                )
            }

            let result = try store.applySummaryUpdate(update)

            #expect(result.staleExports == ["google_docs"])
        }

        @Test
        func rejectsStaleDocumentVersionWithoutChangingAnything() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            let original = try fixture.storedDocument(meetingID: fixture.firstMeetingID)

            #expect(throws: MeetingAccessError.summaryVersionConflict) {
                try store.updateMeetingSummary(
                    meetingID: fixture.firstMeetingID,
                    expectedDocumentVersion: "0000",
                    document: Self.document(title: "Never applied", body: "Body")
                )
            }
            let after = try fixture.storedDocument(meetingID: fixture.firstMeetingID)
            #expect(after == original)
        }

        @Test
        func rejectsDocumentChangedBetweenPlanningAndCommitAndRestoresVaultFile() throws {
            let fixture = try Fixture()
            let relativePath = "Acme/2027-01-01-AI-planning-title.md"
            let fileURL = fixture.primaryVaultURL.appending(path: relativePath)
            let originalFileContents = Data("original vault contents".utf8)
            try originalFileContents.write(to: fileURL)
            try fixture.insertVaultExport(meetingID: fixture.firstMeetingID, relativePath: relativePath)

            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            let version = try #require(store.meeting(id: fixture.firstMeetingID).summaryDocumentVersion)
            let corrected = Self.document(title: "Corrected", body: "Planned correction")
            let plan = try store.database.read { db in
                try store.makeSummaryUpdatePlan(
                    meetingID: fixture.firstMeetingID,
                    expectedDocumentVersion: version,
                    document: corrected,
                    vaultURL: fixture.primaryVaultURL,
                    in: db
                )
            }
            guard case let .apply(update) = plan else {
                Issue.record("Expected the changed document to produce an update plan")
                return
            }

            let regenerated = Self.document(title: "Regenerated", body: "Newly generated summary")
            try fixture.replaceSummaryDocument(meetingID: fixture.firstMeetingID, document: regenerated)
            let regeneratedJSON = try regenerated.databaseJSONString()

            #expect(throws: MeetingAccessError.summaryVersionConflict) {
                try store.applySummaryUpdate(update)
            }
            #expect(try fixture.storedDocument(meetingID: fixture.firstMeetingID) == regeneratedJSON)
            #expect(try Data(contentsOf: fileURL) == originalFileContents)
        }

        @Test
        func returnsUnchangedWhenTheDocumentIsIdentical() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            let detail = try store.meeting(id: fixture.firstMeetingID)
            let version = try #require(detail.summaryDocumentVersion)
            let stored = try fixture.storedDocument(meetingID: fixture.firstMeetingID)

            let result = try store.updateMeetingSummary(
                meetingID: fixture.firstMeetingID,
                expectedDocumentVersion: version,
                document: SummaryDocument.decode(databaseJSON: stored)
            )

            #expect(!result.changed)
            #expect(result.vaultExport == .unchanged)
            #expect(result.documentVersion == version)
            let after = try fixture.storedDocument(meetingID: fixture.firstMeetingID)
            #expect(after == stored)
        }

        @Test
        func rejectsScreenshotReferencesFromAnotherMeeting() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            let version = try #require(store.meeting(id: fixture.firstMeetingID).summaryDocumentVersion)
            var document = Self.document(title: "Bad reference", body: "Body")
            document.sections[0].blocks.append(.image(screenshotId: fixture.otherVaultScreenshotID, caption: "Shot"))

            #expect(throws: MeetingAccessError.summaryScreenshotNotFound) {
                try store.updateMeetingSummary(
                    meetingID: fixture.firstMeetingID,
                    expectedDocumentVersion: version,
                    document: document
                )
            }
        }

        @Test
        func rejectsInvalidTranscriptReferencesFromDirectStoreCallers() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            let version = try #require(store.meeting(id: fixture.firstMeetingID).summaryDocumentVersion)
            var document = Self.document(title: "Bad reference", body: "Body")
            document.sections[0].blocks[0] = .paragraph(
                "Body",
                transcriptRef: TranscriptReference(time: "not-a-time")
            )

            #expect(throws: MeetingAccessError.self) {
                try store.updateMeetingSummary(
                    meetingID: fixture.firstMeetingID,
                    expectedDocumentVersion: version,
                    document: document
                )
            }
        }

        @Test
        func rejectsDuplicateBlockIDsAndUnsupportedSchemaVersions() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            let version = try #require(store.meeting(id: fixture.firstMeetingID).summaryDocumentVersion)

            var duplicated = Self.document(title: "Duplicated", body: "Body")
            let block = duplicated.sections[0].blocks[0]
            duplicated.sections[0].blocks.append(SummaryBlock(id: block.id, content: .paragraph(SummaryText("Copy"))))
            #expect(throws: MeetingAccessError.self) {
                try store.updateMeetingSummary(
                    meetingID: fixture.firstMeetingID,
                    expectedDocumentVersion: version,
                    document: duplicated
                )
            }

            var legacySchema = Self.document(title: "Legacy", body: "Body")
            legacySchema.schemaVersion = 2
            #expect(throws: MeetingAccessError.self) {
                try store.updateMeetingSummary(
                    meetingID: fixture.firstMeetingID,
                    expectedDocumentVersion: version,
                    document: legacySchema
                )
            }
        }

        @Test
        func rejectsMeetingsWithoutSummariesAndFromOtherVaults() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            let document = Self.document(title: "Anything", body: "Body")

            #expect(throws: MeetingAccessError.summaryNotFound) {
                try store.updateMeetingSummary(
                    meetingID: fixture.secondMeetingID,
                    expectedDocumentVersion: "irrelevant",
                    document: document
                )
            }
            #expect(throws: MeetingAccessError.meetingNotFound) {
                try store.updateMeetingSummary(
                    meetingID: fixture.otherVaultMeetingID,
                    expectedDocumentVersion: "irrelevant",
                    document: document
                )
            }
        }

        @Test
        func requiresWriteAccess() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID)
            let original = try fixture.storedDocument(meetingID: fixture.firstMeetingID)

            #expect(throws: MeetingAccessError.writeAccessRequired) {
                try store.updateMeetingSummary(
                    meetingID: fixture.firstMeetingID,
                    expectedDocumentVersion: "irrelevant",
                    document: Self.document(title: "Denied", body: "Body")
                )
            }
            let after = try fixture.storedDocument(meetingID: fixture.firstMeetingID)
            #expect(after == original)
        }

        // MARK: - Protocol surface

        @Test
        func toolIsPublishedOnlyWithWriteAccess() throws {
            let fixture = try Fixture()
            let writable = try Self.toolNames(fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true))
            let readOnly = try Self.toolNames(fixture.store(vaultID: fixture.primaryVaultID))

            #expect(writable.contains("update_meeting_summary"))
            #expect(!readOnly.contains("update_meeting_summary"))
        }

        @Test
        func readOnlyServerRejectsTheTool() throws {
            let fixture = try Fixture()
            let original = try fixture.storedDocument(meetingID: fixture.firstMeetingID)

            let readOnly = try Self.initializedServer(store: fixture.store(vaultID: fixture.primaryVaultID))
            let denied = try Self.json(readOnly.handleLine(Self.updateRequest(id: 9, meetingID: fixture.firstMeetingID)))
            let deniedResult = try #require(denied["result"] as? [String: Any])
            #expect(deniedResult["isError"] as? Bool == true)

            let after = try fixture.storedDocument(meetingID: fixture.firstMeetingID)
            #expect(after == original)
        }

        @Test
        func rejectsMalformedToolDocumentsWithoutChangingTheSummary() throws {
            let fixture = try Fixture()
            let original = try fixture.storedDocument(meetingID: fixture.firstMeetingID)
            let server = try Self.initializedServer(
                store: fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            )
            let current = try Self.summaryDocumentFromMeeting(
                server: server,
                meetingID: fixture.firstMeetingID
            )

            var unknownRootKey = current.document
            unknownRootKey["unexpected"] = true
            var collidingAlias = current.document
            collidingAlias["schemaVersion"] = collidingAlias["schema_version"]
            let unknownBlockType = try Self.updatingFirstBlock(in: current.document) { block in
                block["type"] = "paragraf"
            }
            let missingBlockContent = try Self.updatingFirstBlock(in: current.document) { block in
                block.removeValue(forKey: "content")
            }
            let invalidTranscriptReference = try Self.updatingFirstBlock(in: current.document) { block in
                guard var content = block["content"] as? [String: Any] else { return }
                content["transcript_ref"] = "not-a-time"
                block["content"] = content
            }

            let malformedDocuments = [
                unknownRootKey,
                collidingAlias,
                unknownBlockType,
                missingBlockContent,
                invalidTranscriptReference,
            ]
            for (index, document) in malformedDocuments.enumerated() {
                let line = try Self.summaryUpdateRequest(
                    id: 20 + index,
                    meetingID: fixture.firstMeetingID,
                    version: current.version,
                    document: document
                )
                let response = try Self.json(server.handleLine(line))
                let error = try #require(response["error"] as? [String: Any])
                #expect(error["code"] as? Int == -32602)
            }

            #expect(try fixture.storedDocument(meetingID: fixture.firstMeetingID) == original)
        }

        /// `get_meeting` が返した `summary_document` をそのまま返送すると、保存内容がバイト単位で一致する。
        @Test
        func summaryDocumentRoundTripsThroughTheToolSurface() throws {
            let fixture = try Fixture()
            let rich = Self.richDocument(screenshotID: fixture.firstScreenshotID)
            try fixture.replaceSummaryDocument(meetingID: fixture.firstMeetingID, document: rich)

            let server = try Self.initializedServer(
                store: fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            )
            let result = try Self.roundTripSummaryDocument(
                server: server,
                meetingID: fixture.firstMeetingID
            )

            #expect(result["changed"] as? Bool == false)
            let stored = try fixture.storedDocument(meetingID: fixture.firstMeetingID)
            #expect(try stored == (rich.databaseJSONString()))
        }

        @Test
        func legacyDocumentRoundTripIsUnchangedAndDoesNotRewriteVaultFile() throws {
            let fixture = try Fixture()
            let document = Self.richDocument(screenshotID: fixture.firstScreenshotID)
            var legacyObject = try #require(
                JSONSerialization.jsonObject(with: Data(document.databaseJSONString().utf8)) as? [String: Any]
            )
            legacyObject.removeValue(forKey: "description")
            legacyObject.removeValue(forKey: "tags")
            legacyObject.removeValue(forKey: "actionItems")
            let legacyJSON = try String(
                decoding: JSONSerialization.data(withJSONObject: legacyObject, options: [.sortedKeys]),
                as: UTF8.self
            )
            try fixture.replaceSummaryDocument(meetingID: fixture.firstMeetingID, databaseJSON: legacyJSON)

            let relativePath = "Acme/legacy-summary.md"
            let fileURL = fixture.primaryVaultURL.appending(path: relativePath)
            let originalContents = Data("legacy vault contents".utf8)
            try originalContents.write(to: fileURL)
            let originalModificationDate = Date(timeIntervalSince1970: 1_700_000_000)
            try FileManager.default.setAttributes(
                [.modificationDate: originalModificationDate],
                ofItemAtPath: fileURL.path
            )
            try fixture.insertVaultExport(meetingID: fixture.firstMeetingID, relativePath: relativePath)

            let server = try Self.initializedServer(
                store: fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            )
            let result = try Self.roundTripSummaryDocument(
                server: server,
                meetingID: fixture.firstMeetingID
            )

            #expect(result["changed"] as? Bool == false)
            #expect(try fixture.storedDocument(meetingID: fixture.firstMeetingID) == legacyJSON)
            #expect(try Data(contentsOf: fileURL) == originalContents)
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            #expect(attributes[.modificationDate] as? Date == originalModificationDate)
        }

        @Test
        func unreadableVaultFileIsNotRewritten() throws {
            let fixture = try Fixture()
            let relativePath = "Acme/unreadable-summary.md"
            let fileURL = fixture.primaryVaultURL.appending(path: relativePath)
            let originalContents = Data("must remain unchanged".utf8)
            try originalContents.write(to: fileURL)
            try fixture.insertVaultExport(meetingID: fixture.firstMeetingID, relativePath: relativePath)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            }

            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            let version = try #require(store.meeting(id: fixture.firstMeetingID).summaryDocumentVersion)
            let corrected = Self.document(title: "Corrected", body: "Database-only update")
            let result = try store.updateMeetingSummary(
                meetingID: fixture.firstMeetingID,
                expectedDocumentVersion: version,
                document: corrected
            )

            #expect(result.changed)
            #expect(result.vaultExport == .fileMissing)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            #expect(try Data(contentsOf: fileURL) == originalContents)
            #expect(try fixture.storedDocument(meetingID: fixture.firstMeetingID) == corrected.databaseJSONString())
        }

        // MARK: - Helpers

        private static func document(title: String, body: String) -> SummaryDocument {
            SummaryDocument(
                title: title,
                description: "One line description",
                sections: [
                    SummarySection(
                        id: UUID(uuidString: "00000000-0000-4000-8000-000000000101")!,
                        heading: "Decision",
                        blocks: [
                            SummaryBlock(
                                id: UUID(uuidString: "00000000-0000-4000-8000-000000000201")!,
                                content: .paragraph(SummaryText(body))
                            ),
                        ]
                    ),
                ]
            )
        }

        private static func richDocument(screenshotID: UUID) -> SummaryDocument {
            SummaryDocument(
                title: "Rich",
                description: "Every block type",
                sections: [
                    SummarySection(
                        id: UUID(uuidString: "00000000-0000-4000-8000-000000000301")!,
                        heading: "All blocks",
                        blocks: [
                            .paragraph("Body", transcriptRef: TranscriptReference(time: "00:00:01")),
                            .bulletedList(items: ["Alpha", "Beta"]),
                            .numberedList(items: ["First"]),
                            .checklist(items: [.init(text: "Done", checked: true)]),
                            .quote("Quoted"),
                            .code(language: "swift", code: "let value = 1"),
                            .image(screenshotId: screenshotID, caption: "Shot"),
                            .heading(level: 4, text: "Details"),
                            .table(headers: ["Name"], rows: [["A"]]),
                        ]
                    ),
                ],
                tags: ["release"],
                actionItems: [SummaryActionItem(title: "Follow up", assignee: "Mina")]
            )
        }

        private static func toolNames(_ store: MeetingAccessStore) throws -> [String] {
            let server = try initializedServer(store: store)
            let tools = try json(server.handleLine(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
            let definitions = ((tools["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
            return definitions.compactMap { $0["name"] as? String }
        }

        private static func roundTripSummaryDocument(
            server: DahliaMCPServer,
            meetingID: UUID
        ) throws -> [String: Any] {
            let current = try summaryDocumentFromMeeting(server: server, meetingID: meetingID)
            let line = try summaryUpdateRequest(
                id: 2,
                meetingID: meetingID,
                version: current.version,
                document: current.document
            )
            let response = try json(server.handleLine(line))
            return try #require((response["result"] as? [String: Any])?["structuredContent"] as? [String: Any])
        }

        private static func summaryDocumentFromMeeting(
            server: DahliaMCPServer,
            meetingID: UUID
        ) throws -> (document: [String: Any], version: String) {
            let detail = try json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_meeting","arguments":{"meeting_id":"\#(meetingID
                .uuidString)"}}}
            """#))
            let structured = try #require((detail["result"] as? [String: Any])?["structuredContent"] as? [String: Any])
            let document = try #require(structured["summary_document"] as? [String: Any])
            let version = try #require(structured["summary_document_version"] as? String)
            return (document, version)
        }

        private static func summaryUpdateRequest(
            id: Int,
            meetingID: UUID,
            version: String,
            document: [String: Any]
        ) throws -> String {
            let arguments: [String: Any] = [
                "meeting_id": meetingID.uuidString,
                "expected_document_version": version,
                "summary_document": document,
            ]
            let request: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id,
                "method": "tools/call",
                "params": ["name": "update_meeting_summary", "arguments": arguments],
            ]
            return try String(decoding: JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        }

        private static func updatingFirstBlock(
            in document: [String: Any],
            update: (inout [String: Any]) -> Void
        ) throws -> [String: Any] {
            var document = document
            var sections = try #require(document["sections"] as? [[String: Any]])
            var section = try #require(sections.first)
            var blocks = try #require(section["blocks"] as? [[String: Any]])
            var block = try #require(blocks.first)
            update(&block)
            blocks[0] = block
            section["blocks"] = blocks
            sections[0] = section
            document["sections"] = sections
            return document
        }

        private static func initializedServer(store: MeetingAccessStore) throws -> DahliaMCPServer {
            let server = DahliaMCPServer(store: store)
            _ = try json(server.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#))
            #expect(server.handleLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
            return server
        }

        private static func updateRequest(id: Int, meetingID: UUID) -> String {
            """
            {"jsonrpc":"2.0","id":\(id),"method":"tools/call","params":{"name":"update_meeting_summary","arguments":\
            {"meeting_id":"\(meetingID.uuidString)","expected_document_version":"x","summary_document":\
            {"schema_version":3,"title":"Denied","sections":[]}}}}
            """
        }

        private static func json(_ line: String?) throws -> [String: Any] {
            let line = try #require(line)
            let value = try JSONSerialization.jsonObject(with: Data(line.utf8))
            return try #require(value as? [String: Any])
        }
    }
#endif
