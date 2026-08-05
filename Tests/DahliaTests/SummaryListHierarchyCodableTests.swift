import Foundation
@testable import Dahlia
@testable import DahliaRuntimeSupport

#if canImport(Testing)
    import Testing

    struct SummaryListHierarchyCodableTests {
        @Test
        func omitsZeroIndentAndRoundTripsNonzeroIndent() throws {
            let document = SummaryDocument(
                title: "Nested lists",
                sections: [
                    SummarySection(
                        id: .v7(),
                        heading: "Items",
                        blocks: [
                            .bulletedList(items: [
                                SummaryListItem(text: "Root"),
                                SummaryListItem(text: "Child", indent: 1),
                                SummaryListItem(text: "Grandchild", indent: 2),
                            ]),
                            .checklist(items: [
                                .init(text: "Root task", checked: false),
                                .init(text: "Child task", checked: true, indent: 1),
                            ]),
                        ]
                    ),
                ]
            )

            let data = try JSONEncoder().encode(document)
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let sections = try #require(json["sections"] as? [[String: Any]])
            let blocks = try #require(sections[0]["blocks"] as? [[String: Any]])
            let listItems = try #require(blocks[0]["items"] as? [[String: Any]])
            let checklistItems = try #require(blocks[1]["items"] as? [[String: Any]])

            #expect(listItems[0]["indent"] == nil)
            #expect(listItems[1]["indent"] as? Int == 1)
            #expect(listItems[2]["indent"] as? Int == 2)
            #expect(checklistItems[0]["indent"] == nil)
            #expect(checklistItems[1]["indent"] as? Int == 1)
            #expect(try JSONDecoder().decode(SummaryDocument.self, from: data) == document)
        }

        @Test
        func decodesVersionThreeListItemsWithoutIndentAsZero() throws {
            let json = """
            {
              "schemaVersion": 3,
              "title": "Legacy",
              "sections": [
                {
                  "id": "\(UUID.v7().uuidString)",
                  "heading": "Items",
                  "blocks": [
                    {"type": "bulleted_list", "items": [{"text": "List", "transcript_ref": null}]},
                    {"type": "checklist", "items": [{"text": "Task", "checked": false}]}
                  ]
                }
              ],
              "tags": [],
              "actionItems": []
            }
            """

            let document = try JSONDecoder().decode(SummaryDocument.self, from: Data(json.utf8))

            #expect(document.schemaVersion == 3)
            #expect(document.sections[0].blocks == [
                .bulletedList(items: [SummaryListItem(text: "List")]),
                .checklist(items: [.init(text: "Task", checked: false)]),
            ])
            let reencoded = try document.databaseJSONString()
            #expect(!reencoded.contains(#""indent""#))
        }

        @Test
        func rejectsNonIntegerIndent() {
            let listItem = #"{"text":"Item","indent":"1"}"#
            let checklistItem = #"{"text":"Task","checked":false,"indent":true}"#

            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(SummaryListItem.self, from: Data(listItem.utf8))
            }
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(SummaryBlock.ChecklistItem.self, from: Data(checklistItem.utf8))
            }
        }

        @Test
        func numbersEachListIndentIndependently() {
            let items = [0, 1, 1, 0, 1].map { SummaryListItem(text: "Item", indent: $0) }

            #expect(SummaryListNumbering.numbers(for: items) == [1, 1, 2, 2, 1])
        }
    }
#endif
