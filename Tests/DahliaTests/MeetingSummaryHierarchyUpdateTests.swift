import Foundation
@testable import Dahlia
@testable import DahliaMeetingAccess
@testable import DahliaRuntimeSupport

#if canImport(Testing)
    import Testing

    @MainActor
    struct MeetingSummaryHierarchyStoreTests {
        @Test
        func acceptsVersionThreeFlatListsAndVersionFourHierarchy() throws {
            let versionThreeFixture = try Fixture()
            let versionThreeStore = try versionThreeFixture.store(
                vaultID: versionThreeFixture.primaryVaultID,
                allowsWrites: true
            )
            let versionThreeToken = try #require(
                versionThreeStore.meeting(id: versionThreeFixture.firstMeetingID).summaryDocumentVersion
            )
            let versionThree = SummaryHierarchyUpdateTestSupport.document(
                schemaVersion: 3,
                items: [SummaryListItem(text: "Alpha"), SummaryListItem(text: "Beta")]
            )

            let versionThreeResult = try versionThreeStore.updateMeetingSummary(
                meetingID: versionThreeFixture.firstMeetingID,
                expectedDocumentVersion: versionThreeToken,
                document: versionThree
            )

            #expect(versionThreeResult.changed)
            #expect(try versionThreeFixture.storedDocument(meetingID: versionThreeFixture.firstMeetingID) == versionThree.databaseJSONString())

            let versionFourFixture = try Fixture()
            let versionFourStore = try versionFourFixture.store(
                vaultID: versionFourFixture.primaryVaultID,
                allowsWrites: true
            )
            let versionFourToken = try #require(
                versionFourStore.meeting(id: versionFourFixture.firstMeetingID).summaryDocumentVersion
            )
            let versionFour = SummaryHierarchyUpdateTestSupport.document(
                items: [
                    SummaryListItem(text: "Root"),
                    SummaryListItem(text: "Child", indent: 1),
                    SummaryListItem(text: "Grandchild", indent: 2),
                ]
            )

            let versionFourResult = try versionFourStore.updateMeetingSummary(
                meetingID: versionFourFixture.firstMeetingID,
                expectedDocumentVersion: versionFourToken,
                document: versionFour
            )

            #expect(versionFourResult.changed)
            #expect(try versionFourFixture.storedDocument(meetingID: versionFourFixture.firstMeetingID) == versionFour.databaseJSONString())
        }

        @Test
        func rejectsInvalidListHierarchyFromDirectStoreCallers() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            let version = try #require(store.meeting(id: fixture.firstMeetingID).summaryDocumentVersion)
            let invalidDocuments = [
                SummaryHierarchyUpdateTestSupport.document(
                    schemaVersion: 3,
                    items: [SummaryListItem(text: "Root"), SummaryListItem(text: "Child", indent: 1)]
                ),
                SummaryHierarchyUpdateTestSupport.document(checklistText: "  "),
                SummaryHierarchyUpdateTestSupport.document(items: [SummaryListItem(text: "Child", indent: 1)]),
                SummaryHierarchyUpdateTestSupport.document(items: [
                    SummaryListItem(text: "Root"),
                    SummaryListItem(text: "Grandchild", indent: 2),
                ]),
                SummaryHierarchyUpdateTestSupport.document(items: [SummaryListItem(text: "Root", indent: 3)]),
            ]

            for document in invalidDocuments {
                #expect(throws: MeetingAccessError.self) {
                    try store.updateMeetingSummary(
                        meetingID: fixture.firstMeetingID,
                        expectedDocumentVersion: version,
                        document: document
                    )
                }
            }
        }
    }

    @MainActor
    struct MeetingSummaryHierarchyMCPTests {
        @Test
        func toolSchemaPublishesOptionalListIndent() throws {
            let fixture = try Fixture()
            let server = try SummaryHierarchyUpdateTestSupport.server(fixture: fixture)
            let tools = try SummaryHierarchyUpdateTestSupport.json(
                server.handleLine(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
            )
            let definitions = try #require((tools["result"] as? [String: Any])?["tools"] as? [[String: Any]])
            let updateTool = try #require(definitions.first { $0["name"] as? String == "update_meeting_summary" })
            let inputSchema = try #require(updateTool["inputSchema"] as? [String: Any])
            let inputProperties = try #require(inputSchema["properties"] as? [String: Any])
            let document = try #require(inputProperties["summary_document"] as? [String: Any])
            let documentProperties = try #require(document["properties"] as? [String: Any])
            let sections = try #require(documentProperties["sections"] as? [String: Any])
            let section = try #require(sections["items"] as? [String: Any])
            let sectionProperties = try #require(section["properties"] as? [String: Any])
            let blocks = try #require(sectionProperties["blocks"] as? [String: Any])
            let block = try #require(blocks["items"] as? [String: Any])
            let variants = try #require(block["oneOf"] as? [[String: Any]])

            for typeName in ["bulleted_list", "numbered_list", "checklist"] {
                let variant = try #require(variants.first { variant in
                    guard let properties = variant["properties"] as? [String: Any],
                          let type = properties["type"] as? [String: Any] else { return false }
                    return type["enum"] as? [String] == [typeName]
                })
                let properties = try #require(variant["properties"] as? [String: Any])
                let items = try #require(properties["items"] as? [String: Any])
                let item = try #require(items["items"] as? [String: Any])
                let itemProperties = try #require(item["properties"] as? [String: Any])
                let indent = try #require(itemProperties["indent"] as? [String: Any])
                let required = try #require(item["required"] as? [String])

                #expect(indent["type"] as? String == "integer")
                #expect(indent["enum"] as? [Int] == [0, 1, 2])
                #expect(indent["default"] as? Int == 0)
                #expect(!required.contains("indent"))
            }
        }

        @Test
        func versionThreeFlatDocumentRoundTrips() throws {
            let fixture = try Fixture()
            let document = SummaryHierarchyUpdateTestSupport.document(
                schemaVersion: 3,
                items: [
                    SummaryListItem(text: "Alpha"),
                    SummaryListItem(text: "  "),
                    SummaryListItem(text: "Beta"),
                ]
            )
            try fixture.replaceSummaryDocument(meetingID: fixture.firstMeetingID, document: document)
            let server = try SummaryHierarchyUpdateTestSupport.server(fixture: fixture)

            let result = try SummaryHierarchyUpdateTestSupport.roundTrip(server: server, fixture: fixture)

            #expect(result["changed"] as? Bool == false)
            #expect(try fixture.storedDocument(meetingID: fixture.firstMeetingID) == document.databaseJSONString())
        }

        @Test
        func explicitZeroIndentIsCanonicalizedBeforeComparison() throws {
            let fixture = try Fixture()
            let document = SummaryHierarchyUpdateTestSupport.hierarchicalDocument()
            try fixture.replaceSummaryDocument(meetingID: fixture.firstMeetingID, document: document)
            let server = try SummaryHierarchyUpdateTestSupport.server(fixture: fixture)
            let current = try SummaryHierarchyUpdateTestSupport.current(server: server, fixture: fixture)
            let explicitZero = try SummaryHierarchyUpdateTestSupport.updatingListItem(in: current.document) { item in
                item["indent"] = 0
            }

            let response = try SummaryHierarchyUpdateTestSupport.update(
                server: server,
                fixture: fixture,
                version: current.version,
                document: explicitZero
            )
            let result = try #require((response["result"] as? [String: Any])?["structuredContent"] as? [String: Any])

            #expect(result["changed"] as? Bool == false)
            #expect(try fixture.storedDocument(meetingID: fixture.firstMeetingID) == document.databaseJSONString())
        }

        @Test
        func versionTwoDocumentIsReadableButRejectedByUpdate() throws {
            let fixture = try Fixture()
            let document = SummaryHierarchyUpdateTestSupport.document(schemaVersion: 2, items: [])
            try fixture.replaceSummaryDocument(meetingID: fixture.firstMeetingID, document: document)
            let server = try SummaryHierarchyUpdateTestSupport.server(fixture: fixture)
            let current = try SummaryHierarchyUpdateTestSupport.current(server: server, fixture: fixture)

            #expect(current.document["schema_version"] as? Int == 2)
            let response = try SummaryHierarchyUpdateTestSupport.update(
                server: server,
                fixture: fixture,
                version: current.version,
                document: current.document
            )
            #expect((response["error"] as? [String: Any])?["code"] as? Int == -32602)
        }

        @Test
        func rejectsInvalidListItemsWithoutChangingTheSummary() throws {
            let fixture = try Fixture()
            let document = SummaryHierarchyUpdateTestSupport.hierarchicalDocument()
            try fixture.replaceSummaryDocument(meetingID: fixture.firstMeetingID, document: document)
            let server = try SummaryHierarchyUpdateTestSupport.server(fixture: fixture)
            let current = try SummaryHierarchyUpdateTestSupport.current(server: server, fixture: fixture)
            var versionThreeNested = current.document
            versionThreeNested["schema_version"] = 3
            let blank = try SummaryHierarchyUpdateTestSupport.updatingListItem(in: current.document) { $0["text"] = "  " }
            let orphan = try SummaryHierarchyUpdateTestSupport.updatingListItem(in: current.document) { $0["indent"] = 1 }
            let skipped = try SummaryHierarchyUpdateTestSupport.updatingListItem(in: current.document, at: 1) { $0["indent"] = 2 }
            let outOfRange = try SummaryHierarchyUpdateTestSupport.updatingListItem(in: current.document, at: 1) { $0["indent"] = 3 }

            for invalid in [versionThreeNested, blank, orphan, skipped, outOfRange] {
                let response = try SummaryHierarchyUpdateTestSupport.update(
                    server: server,
                    fixture: fixture,
                    version: current.version,
                    document: invalid
                )
                #expect((response["error"] as? [String: Any])?["code"] as? Int == -32602)
            }
            #expect(try fixture.storedDocument(meetingID: fixture.firstMeetingID) == document.databaseJSONString())
        }
    }

    @MainActor
    private enum SummaryHierarchyUpdateTestSupport {
        static func hierarchicalDocument() -> SummaryDocument {
            document(items: [SummaryListItem(text: "Root"), SummaryListItem(text: "Child", indent: 1)])
        }

        static func document(
            schemaVersion: Int = SummaryDocumentSchemaVersion.current,
            items: [SummaryListItem]
        ) -> SummaryDocument {
            SummaryDocument(
                schemaVersion: schemaVersion,
                title: "Hierarchy",
                sections: [SummarySection(id: .v7(), heading: "Items", blocks: [.bulletedList(items: items)])]
            )
        }

        static func document(checklistText: String) -> SummaryDocument {
            SummaryDocument(
                title: "Hierarchy",
                sections: [
                    SummarySection(
                        id: .v7(),
                        heading: "Items",
                        blocks: [.checklist(items: [.init(text: checklistText, checked: false)])],
                    ),
                ],
            )
        }

        static func server(fixture: Fixture) throws -> DahliaMCPServer {
            let server = DahliaMCPServer(
                store: try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            )
            _ = try json(server.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#))
            #expect(server.handleLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
            return server
        }

        static func current(
            server: DahliaMCPServer,
            fixture: Fixture
        ) throws -> (document: [String: Any], version: String) {
            let detail = try json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_meeting","arguments":{
              "meeting_id":"\#(fixture.firstMeetingID.uuidString)"}}}
            """#))
            let content = try #require((detail["result"] as? [String: Any])?["structuredContent"] as? [String: Any])
            return (
                try #require(content["summary_document"] as? [String: Any]),
                try #require(content["summary_document_version"] as? String)
            )
        }

        static func roundTrip(server: DahliaMCPServer, fixture: Fixture) throws -> [String: Any] {
            let value = try current(server: server, fixture: fixture)
            let response = try update(server: server, fixture: fixture, version: value.version, document: value.document)
            return try #require((response["result"] as? [String: Any])?["structuredContent"] as? [String: Any])
        }

        static func update(
            server: DahliaMCPServer,
            fixture: Fixture,
            version: String,
            document: [String: Any]
        ) throws -> [String: Any] {
            let request: [String: Any] = [
                "jsonrpc": "2.0",
                "id": 3,
                "method": "tools/call",
                "params": [
                    "name": "update_meeting_summary",
                    "arguments": [
                        "meeting_id": fixture.firstMeetingID.uuidString,
                        "expected_document_version": version,
                        "summary_document": document,
                    ],
                ],
            ]
            let data = try JSONSerialization.data(withJSONObject: request)
            let line = try #require(String(bytes: data, encoding: .utf8))
            return try json(server.handleLine(line))
        }

        static func updatingListItem(
            in document: [String: Any],
            at index: Int = 0,
            update: (inout [String: Any]) -> Void
        ) throws -> [String: Any] {
            var document = document
            var sections = try #require(document["sections"] as? [[String: Any]])
            var section = try #require(sections.first)
            var blocks = try #require(section["blocks"] as? [[String: Any]])
            var block = try #require(blocks.first)
            var items = try #require(block["items"] as? [[String: Any]])
            let selected = items.indices.contains(index) ? items[index] : nil
            var item = try #require(selected)
            update(&item)
            items[index] = item
            block["items"] = items
            blocks[0] = block
            section["blocks"] = blocks
            sections[0] = section
            document["sections"] = sections
            return document
        }

        static func json(_ line: String?) throws -> [String: Any] {
            let line = try #require(line)
            return try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
    }
#endif
