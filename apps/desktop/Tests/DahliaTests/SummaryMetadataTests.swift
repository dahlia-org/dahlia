import Foundation
@testable import DahliaRuntimeSupport

#if canImport(Testing)
    import Testing

    struct SummaryMetadataTests {
        @Test
        func preservesOpenAIFieldsAndMissingUsageThroughDocumentRoundTrip() throws {
            let json = """
            {"schemaVersion":3,"title":"Saved","sections":[],"metadata":{
              "generatedBy":"server","inputTypes":["transcript","image"],"detailLevel":"concise","outputLanguage":"ja",
              "request":{"model":"requested","reasoning":{"effort":"high"}},
              "response":{"id":"resp-example","model":"returned","created_at":123,"reasoning":{"effort":"high"},
                "usage":{"input_tokens":100,"input_tokens_details":{"cached_tokens":10},"output_tokens_details":{"reasoning_tokens":2}}}
            }}
            """
            let document = try SummaryDocument.decode(databaseJSON: json)
            #expect(document.metadata?.generatedBy == "server")
            #expect(document.metadata?.detailLevel == "concise")
            #expect(document.metadata?.response?.model == "returned")
            #expect(document.metadata?.response?.usage?.totalTokens == nil)
            #expect(document.metadata?.response?.usage?.inputTokensDetails?.cachedTokens == 10)
            let stored = try document.databaseJSONString()
            let object = try #require(JSONSerialization.jsonObject(with: Data(stored.utf8)) as? [String: Any])
            let metadata = try #require(object["metadata"] as? [String: Any])
            #expect(object["generation"] == nil)
            #expect(metadata["source"] == nil)
            #expect(metadata["method"] == nil)
            #expect(metadata["detail"] == nil)
            #expect(stored.contains("input_tokens_details"))
            #expect(!stored.contains("total_tokens"))
            #expect(try SummaryDocument.decode(databaseJSON: stored) == document)
        }

        @Test
        func acceptsOldDocumentsAndLocalMetadataWithoutResponse() throws {
            var document = try SummaryDocument.decode(databaseJSON: #"{"schemaVersion":3,"title":"Old","sections":[]}"#)
            #expect(document.metadata == nil)
            document.metadata = .init(
                generatedBy: "local_codex",
                inputTypes: ["transcript"],
                detailLevel: "detailed",
                outputLanguage: "ja",
                request: .init(model: nil, reasoning: .init(effort: "medium"))
            )
            let decoded = try SummaryDocument.decode(databaseJSON: document.databaseJSONString())
            #expect(decoded == document)
            #expect(decoded.metadata?.response == nil)
            #expect(decoded.metadata?.request.model == nil)
        }
    }
#endif
