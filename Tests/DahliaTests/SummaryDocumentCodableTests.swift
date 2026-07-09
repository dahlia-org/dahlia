import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct SummaryDocumentCodableTests {
        @Test
        func summaryDocumentRoundTrips() throws {
            let imageId = UUID.v7()
            let sectionId = UUID.v7()
            let document = SummaryDocument(
                title: "Weekly sync",
                sections: [
                    SummarySection(
                        id: sectionId,
                        heading: "Decisions",
                        blocks: [
                            .paragraph("Ship [00:10:00](transcript://00:10:00)"),
                            .bulletedList(items: ["One", "Two"]),
                            .numberedList(items: ["First"]),
                            .checklist(items: [.init(text: "Send notes", checked: false)]),
                            .quote("Important"),
                            .code(language: "swift", code: "let value = 1"),
                            .image(screenshotId: imageId, caption: "Screen"),
                            .heading(level: 3, text: "Details"),
                            .table(headers: ["A", "B"], rows: [["1", "2"]]),
                        ]
                    ),
                ],
                tags: ["team"],
                actionItems: [SummaryActionItem(title: "Send notes", assignee: "me")]
            )

            let data = try JSONEncoder().encode(document)
            let decoded = try JSONDecoder().decode(SummaryDocument.self, from: data)

            #expect(decoded == document)
        }

        @Test
        func unknownBlockTypeFallsBackToParagraph() throws {
            let json = """
            {
              "schemaVersion": 1,
              "title": "Title",
              "sections": [
                {
                  "id": "\(UUID.v7().uuidString)",
                  "heading": "",
                  "blocks": [
                    {
                      "type": "callout",
                      "text": "Future block"
                    }
                  ]
                }
              ],
              "tags": [],
              "actionItems": []
            }
            """

            let document = try JSONDecoder().decode(SummaryDocument.self, from: Data(json.utf8))

            #expect(document.sections.first?.blocks == [.paragraph("Future block")])
        }
    }
#endif
