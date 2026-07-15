import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct SummaryDocumentCodableTests {
        @Test
        func summaryDocumentRoundTripsWithTextLevelTranscriptRefs() throws {
            let imageId = UUID.v7()
            let sectionId = UUID.v7()
            let document = SummaryDocument(
                title: "Weekly sync",
                description: "Weekly product decisions",
                sections: [
                    SummarySection(
                        id: sectionId,
                        heading: "Decisions",
                        blocks: [
                            .paragraph(
                                SummaryText("Ship", transcriptRef: TranscriptReference(time: "00:10:00"))
                            ),
                            .bulletedList(items: [
                                SummaryText("One", transcriptRef: TranscriptReference(time: "00:11:00")),
                                SummaryText("Two"),
                            ]),
                            .numberedList(items: [SummaryText("First")]),
                            .checklist(items: [
                                .init(
                                    text: SummaryText("Send notes", transcriptRef: TranscriptReference(time: "00:12:00")),
                                    checked: false
                                ),
                            ]),
                            .quote("Important"),
                            .code(language: "swift", content: SummaryText("let value = 1", transcriptRef: TranscriptReference(time: "00:13:00"))),
                            .image(screenshotId: imageId, caption: SummaryText("Screen", transcriptRef: TranscriptReference(time: "00:14:00"))),
                            .heading(level: 3, content: SummaryText("Details", transcriptRef: TranscriptReference(time: "00:15:00"))),
                            .table(headers: [SummaryText("A"), SummaryText("B")], rows: [[SummaryText("1"), SummaryText("2")]]),
                        ]
                    ),
                ],
                tags: ["team"],
                actionItems: [SummaryActionItem(title: "Send notes", assignee: "me")]
            )

            let data = try JSONEncoder().encode(document)
            let decoded = try JSONDecoder().decode(SummaryDocument.self, from: data)

            #expect(decoded == document)
            #expect(decoded.schemaVersion == 3)
        }

        @Test
        func summaryDocumentDoesNotEncodeTranscriptReferenceLabels() throws {
            let document = SummaryDocument(
                title: "Weekly sync",
                sections: [
                    SummarySection(
                        id: UUID.v7(),
                        heading: "Decisions",
                        blocks: [
                            .paragraph(SummaryText("Ship", transcriptRef: TranscriptReference(time: "00:10:00"))),
                        ]
                    ),
                ]
            )

            let json = try document.databaseJSONString()

            #expect(json.contains(#""transcript_ref":"00:10:00""#))
            #expect(!json.contains(#""label""#))
            #expect(!json.contains(#""transcript_refs""#))
        }

        @Test
        func unknownBlockTypeFallsBackToParagraphContent() throws {
            let json = """
            {
              "schemaVersion": 2,
              "title": "Title",
              "sections": [
                {
                  "id": "\(UUID.v7().uuidString)",
                  "heading": "",
                  "blocks": [
                    {
                      "type": "callout",
                      "content": {
                        "text": "Future block",
                        "transcript_ref": null
                      }
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
            #expect(document.description.isEmpty)
        }

        @Test
        func decodesPersistedSummaryDocumentShape() throws {
            let imageId = UUID.v7()
            let json = """
            {
              "actionItems": [
                {
                  "assignee": "勝倉さん",
                  "title": "宿題をフォローアップする"
                }
              ],
              "schemaVersion": 2,
              "sections": [
                {
                  "blocks": [
                    {
                      "content": {
                        "text": "共有資料のスクリーンショット",
                        "transcript_ref": "00:00:11"
                      },
                      "id": "\(UUID.v7().uuidString)",
                      "screenshot_id": "\(imageId.uuidString)",
                      "type": "image"
                    }
                  ],
                  "heading": "",
                  "id": "\(UUID.v7().uuidString)"
                },
                {
                  "blocks": [
                    {
                      "id": "\(UUID.v7().uuidString)",
                      "items": [
                        {
                          "text": "Lakebaseは**常時稼働ワークロードにはコスパが悪くなりやすい**。",
                          "transcript_ref": "00:02:32"
                        },
                        {
                          "text": "ピークが高いワークロードにはフィットしやすい。",
                          "transcript_ref": null
                        }
                      ],
                      "type": "bulleted_list"
                    },
                    {
                      "id": "\(UUID.v7().uuidString)",
                      "items": [
                        {
                          "checked": false,
                          "text": "次回アポを調整する。",
                          "transcript_ref": "00:08:38"
                        }
                      ],
                      "type": "checklist"
                    }
                  ],
                  "heading": "Lakebaseの適用方針",
                  "id": "\(UUID.v7().uuidString)"
                }
              ],
              "tags": ["Databricks", "Lakebase"],
              "title": "マイポックス様向けLakebase提案相談"
            }
            """

            let document = try JSONDecoder().decode(SummaryDocument.self, from: Data(json.utf8))

            #expect(document.title == "マイポックス様向けLakebase提案相談")
            #expect(document.actionItems == [SummaryActionItem(title: "宿題をフォローアップする", assignee: "勝倉さん")])
            #expect(document.sections.count == 2)
            #expect(document.sections[0].blocks == [
                .image(
                    screenshotId: imageId,
                    caption: SummaryText("共有資料のスクリーンショット", transcriptRef: TranscriptReference(time: "00:00:11"))
                ),
            ])
            #expect(document.sections[1].blocks == [
                .bulletedList(items: [
                    SummaryText(
                        "Lakebaseは**常時稼働ワークロードにはコスパが悪くなりやすい**。",
                        transcriptRef: TranscriptReference(time: "00:02:32")
                    ),
                    SummaryText("ピークが高いワークロードにはフィットしやすい。"),
                ]),
                .checklist(items: [
                    .init(
                        text: SummaryText("次回アポを調整する。", transcriptRef: TranscriptReference(time: "00:08:38")),
                        checked: false
                    ),
                ]),
            ])
        }
    }
#endif
