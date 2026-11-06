import Foundation
@testable import Dahlia
@testable import DahliaRuntimeSupport

#if canImport(Testing)
    import Testing

    struct SummaryDocumentResponseSchemaTests {
        @Test
        func requiresTextContainersWithoutExtraFields() throws {
            let schemaObject = try JSONSerialization.jsonObject(with: SummaryDocumentResponse.outputSchema)
            let schema = try #require(schemaObject as? [String: Any])
            let required = try #require(schema["required"] as? [String])
            let properties = try #require(schema["properties"] as? [String: Any])
            let title = try #require(properties["title"] as? [String: Any])
            let description = try #require(properties["description"] as? [String: Any])
            let sections = try #require(properties["sections"] as? [String: Any])
            let tags = try #require(properties["tags"] as? [String: Any])
            let tagItems = try #require(tags["items"] as? [String: Any])
            let sectionItems = try #require(sections["items"] as? [String: Any])
            let sectionProperties = try #require(sectionItems["properties"] as? [String: Any])
            let blocks = try #require(sectionProperties["blocks"] as? [String: Any])
            let blockItems = try #require(blocks["items"] as? [String: Any])
            let blockProperties = try #require(blockItems["properties"] as? [String: Any])
            let blockRequired = try #require(blockItems["required"] as? [String])
            let content = try #require(blockProperties["content"] as? [String: Any])
            let contentRequired = try #require(content["required"] as? [String])
            let blockList = try #require(blockProperties["items"] as? [String: Any])
            let blockListItem = try #require(blockList["items"] as? [String: Any])
            let blockListItemRequired = try #require(blockListItem["required"] as? [String])
            let actionItems = try #require(properties["action_items"] as? [String: Any])
            let items = try #require(actionItems["items"] as? [String: Any])

            #expect(required.contains("sections"))
            #expect(title["minLength"] as? Int == 1)
            #expect(title["maxLength"] as? Int == 120)
            #expect(required.contains("description"))
            #expect(description["minLength"] as? Int == 1)
            #expect(description["maxLength"] as? Int == 240)
            #expect(tagItems["pattern"] as? String == "^[a-z0-9_]*[a-z][a-z0-9_]*$")
            #expect(required.contains("action_items"))
            #expect(blockRequired == ["type", "level", "content", "items", "language", "image_id"])
            #expect(contentRequired == ["text", "transcript_ref"])
            #expect(blockListItemRequired == ["text", "transcript_ref", "checked"])
            #expect((blockItems["additionalProperties"] as? Bool) == false)
            #expect((content["additionalProperties"] as? Bool) == false)
            #expect((blockListItem["additionalProperties"] as? Bool) == false)
            #expect((items["additionalProperties"] as? Bool) == false)
            #expect((sections["description"] as? String)?.contains("Do not include an Action Items section") == true)
            #expect((actionItems["description"] as? String)?.contains("only location") == true)
        }

        @Test
        func decodesLegacyStructuredResponseWithoutDescription() {
            let response = """
            {"title":"Legacy","sections":[],"tags":[],"action_items":[]}
            """
            let context = SummaryRenderContext(meetingId: .v7(), createdAt: .now, screenshots: [])

            let document = SummaryService.decodeSummaryDocument(from: response, context: context)

            #expect(document.title == "Legacy")
            #expect(document.description.isEmpty)
        }

        @Test
        func blocksWithoutTheirInapplicableFieldsStillDecode() throws {
            // Claude and Gemini see the schema only in the prompt and may leave out fields a block does not use.
            let response = """
            {"title":"T","description":"D","sections":[{"heading":"H","blocks":[
              {"type":"paragraph","content":{"text":"Body","transcript_ref":null}},
              {"type":"bulleted_list","items":[{"text":"One","transcript_ref":null}]}
            ]},{"heading":"Empty"}],"action_items":[{"title":"Send deck"}]}
            """

            let decoded = try JSONDecoder().decode(SummaryDocumentResponse.self, from: Data(response.utf8))

            let blocks = try #require(decoded.sections.first?.blocks)
            #expect(blocks.map(\.type) == ["paragraph", "bulleted_list"])
            #expect(blocks[0].content.text == "Body" && blocks[0].items.isEmpty && blocks[0].imageId.isEmpty)
            #expect(blocks[1].content.text.isEmpty && blocks[1].items.map(\.checked) == [false])
            #expect(decoded.sections.last?.blocks.isEmpty == true)
            #expect(decoded.tags.isEmpty && decoded.actionItems == [SummaryActionItem(title: "Send deck", assignee: "")])
            // A block without the field its type carries text in still fails, instead of saving an empty summary.
            for block in [#"{}"#, #"{"type":"paragraph","text":"Body"}"#, #"{"type":"checklist"}"#] {
                #expect(throws: DecodingError.self) {
                    try JSONDecoder().decode(
                        SummaryDocumentResponse.self,
                        from: Data(#"{"title":"T","sections":[{"heading":"H","blocks":[\#(block)]}]}"#.utf8)
                    )
                }
            }
        }
    }
#endif
