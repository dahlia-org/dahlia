import DahliaRuntimeSupport
import Foundation
@testable import DahliaMeetingAccess

#if canImport(Testing)
    import Testing

    struct PublicMCPIDsTests {
        @Test(arguments: ["query_meetings", "query_screenshots"])
        func nestedServerSearchIDsAndCursorsCanBeReused(tool: String) throws {
            let workspaceID = UUID(), projectID = UUID(), meetingID = UUID(), attachmentID = UUID()
            let scope = try JSONSerialization.data(withJSONObject: ["query": "needle", "projectID": projectID.uuidString], options: [.sortedKeys])
                .base64EncodedString()
            let position = try String(
                decoding: JSONSerialization.data(withJSONObject: [workspaceID.uuidString.lowercased(), "needle", 1, 2, 3]),
                as: UTF8.self
            )
            let cursor = try JSONSerialization.data(withJSONObject: ["scope": scope, "position": position]).base64EncodedString()
            let screenshot = tool == "query_screenshots"
            let item: [String: Any] = [
                "id": (screenshot ? attachmentID : meetingID).uuidString,
                "meeting_id": meetingID.uuidString,
                "snippet": "User wrote " + meetingID.uuidString,
            ]
            let source: [String: Any] = ["structuredContent": ["workspaces": [[
                "workspace_id": workspaceID.uuidString,
                "result": ["server": ["items": [item], "next_cursor": cursor]],
            ]]]]
            let result = try PublicMCPIDs.result(source, tool: tool, arguments: [:])
            let body = try #require(result["structuredContent"] as? [String: Any])
            let group = try #require((body["workspaces"] as? [[String: Any]])?.first)
            #expect(group["workspace_id"] as? String == TypeID.encode(workspaceID, as: .workspace))
            let nested = try #require(group["result"] as? [String: Any])
            let server = try #require(nested["server"] as? [String: Any])
            let hit = try #require((server["items"] as? [[String: Any]])?.first)
            #expect(hit["id"] as? String == TypeID.encode(screenshot ? attachmentID : meetingID, as: screenshot ? .attachment : .meeting))
            #expect(hit["meeting_id"] as? String == TypeID.encode(meetingID, as: .meeting))
            #expect(hit["snippet"] as? String == item["snippet"] as? String)
            let input = try PublicMCPIDs.arguments([
                "workspace_id": #require(group["workspace_id"]),
                "project_id": TypeID.encode(projectID, as: .project),
                "server_cursor": #require(server["next_cursor"]),
            ], tool: tool)
            #expect(input["workspace_id"] as? String == workspaceID.uuidString.lowercased())
            #expect(input["project_id"] as? String == projectID.uuidString.lowercased())
            let decoded = try #require(input["server_cursor"] as? String)
            let decodedCursor = try JSONSerialization.jsonObject(with: #require(Data(base64Encoded: decoded))) as? [String: String]
            #expect(decodedCursor?["scope"] == scope)
            #expect(decodedCursor?["position"] == position)
        }

        @Test
        func screenshotSelectionKeepsMalformedIDsAndEchoesThemInErrors() throws {
            let valid = UUID()
            let requested = [TypeID.encode(valid, as: .attachment), "att_malformed"]
            let input = try PublicMCPIDs.arguments(["screenshot_ids": requested], tool: "get_screenshots")
            let ids = try #require(input["screenshot_ids"] as? [Any])
            #expect(ids.first as? String == valid.uuidString.lowercased())
            #expect(ids.last is NSNull)

            let source: [String: Any] = ["structuredContent": [
                "screenshots": [["id": valid.uuidString, "meeting_id": UUID().uuidString]],
                "errors": [["index": 1, "error": "invalid_id"]],
            ]]
            let result = try PublicMCPIDs.result(source, tool: "get_screenshots", arguments: ["screenshot_ids": requested])
            let body = try #require(result["structuredContent"] as? [String: Any])
            #expect((body["screenshots"] as? [[String: Any]])?.first?["id"] as? String == requested[0])
            #expect((body["errors"] as? [[String: Any]])?.first?["screenshot_id"] as? String == "att_malformed")
        }

        @Test
        func screenshotListingCursorScopeCarriesTheMeetingID() throws {
            let workspaceID = UUID(), meetingID = UUID()
            let scope = try JSONSerialization.data(withJSONObject: ["meetingID": meetingID.uuidString], options: [.sortedKeys])
                .base64EncodedString()
            let cursor = try JSONSerialization.data(withJSONObject: [
                "workspaceID": workspaceID.uuidString, "revision": 0, "scope": scope, "offset": 1,
            ]).base64EncodedString()
            let source: [String: Any] = ["structuredContent": ["screenshots": [], "next_cursor": cursor]]
            let result = try PublicMCPIDs.result(source, tool: "query_screenshots", arguments: [:])
            let body = try #require(result["structuredContent"] as? [String: Any])
            let encoded = try #require(body["next_cursor"] as? String)
            // The public cursor carries a TypeID, and decoding restores the internal UUID.
            let input = try PublicMCPIDs.arguments(["cursor": encoded], tool: "query_screenshots")
            let decoded = try #require(input["cursor"] as? String)
            let cursorData = try #require(Data(base64Encoded: decoded))
            let object = try #require(JSONSerialization.jsonObject(with: cursorData) as? [String: Any])
            let scopeString = try #require(object["scope"] as? String)
            let decodedScope = try #require(Data(base64Encoded: scopeString))
            let scopeObject = try JSONSerialization.jsonObject(with: decodedScope) as? [String: String]
            #expect(scopeObject?["meetingID"] == meetingID.uuidString)
        }

        @Test
        func summaryScreenshotMarkersUseTypeIDsWithoutRewritingUserText() {
            let id = UUID()
            let userText = "User wrote " + id.uuidString
            let document = SummaryDocument(title: "Summary", sections: [
                SummarySection(id: UUID(), heading: "Notes", blocks: [
                    SummaryBlock(content: .paragraph(SummaryText(userText))),
                    SummaryBlock(content: .image(screenshotId: id, caption: SummaryText(userText))),
                ]),
            ])
            let rendered = StoredSummaryDocumentMarkdownRenderer.render(document)
            #expect(rendered.contains("[Screenshot \(TypeID.encode(id, as: .attachment))]"))
            #expect(rendered.components(separatedBy: userText).count == 3)
        }
    }
#endif
