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
