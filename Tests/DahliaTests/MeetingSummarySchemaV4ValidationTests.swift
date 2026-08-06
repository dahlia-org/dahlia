import Foundation
@testable import Dahlia
@testable import DahliaMeetingAccess
@testable import DahliaRuntimeSupport

#if canImport(Testing)
    import Testing

    @MainActor
    struct MeetingSummarySchemaV4ValidationTests {
        @Test
        func acceptsSchemaVersionsThreeAndFourAndPreservesTheSubmittedVersion() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)

            for schemaVersion in SummaryDocumentSchemaVersion.acceptedMCPWriteVersions.sorted() {
                let version = try #require(store.meeting(id: fixture.firstMeetingID).summaryDocumentVersion)
                var document = Self.document(title: "Version \(schemaVersion)", body: "Body")
                document.schemaVersion = schemaVersion

                _ = try store.updateMeetingSummary(
                    meetingID: fixture.firstMeetingID,
                    expectedDocumentVersion: version,
                    document: document
                )

                let stored = try SummaryDocument.decode(
                    databaseJSON: fixture.storedDocument(meetingID: fixture.firstMeetingID)
                )
                #expect(stored.schemaVersion == schemaVersion)
            }
        }

        @Test
        func rejectsVersionFourBlankOrStructurallyInvalidListItemsWithoutNormalizing() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            let version = try #require(store.meeting(id: fixture.firstMeetingID).summaryDocumentVersion)
            let original = try fixture.storedDocument(meetingID: fixture.firstMeetingID)
            let invalidItems: [[SummaryListItem]] = [
                [SummaryListItem(text: " ")],
                [SummaryListItem(text: "Leading", indent: 1)],
                [SummaryListItem(text: "Parent"), SummaryListItem(text: "Jump", indent: 2)],
                [SummaryListItem(text: "Parent"), SummaryListItem(text: "Out of range", indent: 3)],
            ]

            for items in invalidItems {
                var document = Self.document(title: "Invalid", body: "Body")
                document.schemaVersion = SummaryDocumentSchemaVersion.current
                document.sections[0].blocks[0].content = .bulletedList(items: items)

                #expect(throws: MeetingAccessError.self) {
                    try store.updateMeetingSummary(
                        meetingID: fixture.firstMeetingID,
                        expectedDocumentVersion: version,
                        document: document
                    )
                }
                #expect(try fixture.storedDocument(meetingID: fixture.firstMeetingID) == original)
            }
        }

        @Test
        func acceptsVersionThreeBlankItemsButRejectsVersionThreeNestedIndent() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            var blank = Self.document(title: "Legacy blank", body: "Body")
            blank.sections[0].blocks[0].content = .bulletedList(items: [SummaryListItem(text: " ")])
            let initialVersion = try #require(store.meeting(id: fixture.firstMeetingID).summaryDocumentVersion)

            _ = try store.updateMeetingSummary(
                meetingID: fixture.firstMeetingID,
                expectedDocumentVersion: initialVersion,
                document: blank
            )
            let accepted = try fixture.storedDocument(meetingID: fixture.firstMeetingID)
            #expect(try SummaryDocument.decode(databaseJSON: accepted).schemaVersion == 3)

            var nested = Self.document(title: "Legacy nested", body: "Body")
            nested.sections[0].blocks[0].content = .bulletedList(items: [
                SummaryListItem(text: "Parent"),
                SummaryListItem(text: "Nested", indent: 1),
            ])
            let currentVersion = try #require(store.meeting(id: fixture.firstMeetingID).summaryDocumentVersion)
            #expect(throws: MeetingAccessError.self) {
                try store.updateMeetingSummary(
                    meetingID: fixture.firstMeetingID,
                    expectedDocumentVersion: currentVersion,
                    document: nested
                )
            }
            #expect(try fixture.storedDocument(meetingID: fixture.firstMeetingID) == accepted)
        }

        private static func document(title: String, body: String) -> SummaryDocument {
            SummaryDocument(
                schemaVersion: 3,
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
    }
#endif
