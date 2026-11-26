import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct CodexChatMCPApprovalTests {
        @Test
        func extensionConfirmationsShowTheirWholeTextAndContinueOrCancel() throws {
            let request = try #require(PiChatService.approvalRequest(id: "c", payload: .object([
                "kind": .string("confirmation"), "title": .string("MCP server \"gateway\" asks you to open example.com"),
                "message": .string("Approve\n\nhttps://example.com/approve?x=1"),
            ])))
            #expect(request.kind == .confirmation)
            #expect(request.reason == "MCP server \"gateway\" asks you to open example.com\n\nApprove\n\nhttps://example.com/approve?x=1")
            #expect(request.actions == [.allowOnce, .deny])
            #expect(request.canApprove)
            let empty = PiChatService.approvalRequest(id: "d", payload: .object(["kind": .string("confirmation")]))
            #expect(empty?.canApprove == false)
            let oversized = try #require(PiChatService.approvalRequest(id: "long", payload: .object([
                "kind": .string("confirmation"), "title": .string("Open page?"),
                "message": .string(String(repeating: "x", count: 4096) + "\nhttps://example.com/approve"),
            ])))
            #expect(oversized.reviewability == .tooLarge)
            #expect(!oversized.canApprove)
            #expect(oversized.actions == [.deny])
        }

        @Test
        func correlatedToolInputIsReviewableWithBoundedDetails() throws {
            let request = try normalizedRequest()

            #expect(request.reviewability == .ready)
            #expect(request.canApprove)
            #expect(request.mcpServer == "dahlia")
            #expect(request.mcpTool == "update_project")
            #expect(request.mcpArguments?.contains("Updated description") == true)
            #expect(request.actions == [.allowOnce, .deny])
        }

        @Test
        func largeSummaryUpdateArgumentsRemainCompleteAndReviewable() throws {
            let summary = String(repeating: "会議の要約と次のアクション\n", count: 1000)
            let request = try normalizedRequest(
                tool: "update_meeting_summary",
                arguments: .object(["summary": .string(summary)])
            )

            let encodedArguments = try #require(request.mcpArguments)
            #expect(request.reviewability == .ready)
            #expect(request.canApprove)
            #expect(encodedArguments.utf8.count > 20_000)
            let decodedArguments = try JSONDecoder().decode(JSONValue.self, from: Data(encodedArguments.utf8))
            #expect(decodedArguments.objectValue?["summary"]?.stringValue == summary)
        }

        @Test
        func registeredMCPToolsAreApprovableAndUnknownServersFailClosed() throws {
            let gmail = try normalizedRequest(server: "work_gmail", tool: "send_message", approvableMCPServers: ["dahlia", "work_gmail"])
            #expect(gmail.reviewability == .ready)
            #expect(gmail.actions == [.allowOnce, .deny])

            let unknown = try normalizedRequest(server: "filesystem", tool: "write_file", approvableMCPServers: ["dahlia", "work_gmail"])
            #expect(unknown.reviewability == .unsupported)
            #expect(unknown.actions == [.deny])
        }

        @Test
        func additionalAccessIsFailClosed() throws {
            let request = try normalizedRequest(params: [
                "itemId": .string("item-1"),
                "additionalPermissions": .object(["network": .object([:])]),
            ])

            #expect(request.reviewability == .unsupported)
            #expect(!request.canApprove)
            #expect(request.actions == [.deny])
        }

        @Test
        func missingCorrelatedToolCallIsFailClosed() throws {
            let request = try CodexChatApprovalNormalizer.request(
                id: "s:approval",
                params: ["itemId": .string("unknown-item")],
                kind: .mcpToolCall,
                fileChanges: []
            )

            #expect(request.reviewability == .unsupported)
            #expect(!request.canApprove)
            #expect(request.actions == [.deny])
        }

        @Test
        func oversizedArgumentsAreBoundedAndFailClosed() throws {
            let request = try normalizedRequest(arguments: .object([
                "description": .string(
                    String(repeating: "あ", count: CodexChatApprovalNormalizer.byteLimit / 3 + 1)
                ),
            ]))
            let displayedBytes = [request.mcpServer, request.mcpTool, request.mcpArguments]
                .compactMap(\.self)
                .reduce(0) { $0 + $1.utf8.count }

            #expect(displayedBytes <= CodexChatApprovalNormalizer.byteLimit)
            #expect(request.reviewability == .tooLarge)
            #expect(!request.canApprove)
            #expect(request.actions == [.deny])
        }

        @Test
        func mcpApprovalBudgetIncludesReasonAndMetadata() throws {
            let server = "dahlia"
            let tool = "update_meeting_summary"
            let reason = "Review the complete summary"
            let arguments = CodexChatApprovalNormalizer.boundedMCPToolCall(
                server: server, tool: tool, arguments: .object(["summary": .string("")])
            )
            let overhead = try #require(arguments.arguments).utf8.count + server.utf8.count + tool.utf8.count + reason.utf8.count
            let summary = String(repeating: "a", count: CodexChatApprovalNormalizer.byteLimit - overhead)
            for extraBytes in [0, 1] {
                let request = try normalizedRequest(
                    params: ["reason": .string(reason)],
                    server: server, tool: tool,
                    arguments: .object(["summary": .string(summary + String(repeating: "b", count: extraBytes))])
                )
                #expect(request.reviewability == (extraBytes == 0 ? .ready : .tooLarge))
                #expect(request.canApprove == (extraBytes == 0))
            }
        }

        @Test
        func bidirectionalControlsAreEscapedInArguments() throws {
            let request = try normalizedRequest(
                arguments: .object(["description": .string("safe\u{202E}txt")])
            )

            #expect(request.reviewability == .ready)
            #expect(request.mcpArguments?.contains("\\u202E") == true)
            #expect(request.mcpArguments?.contains("\u{202E}") == false)
        }

        private func normalizedRequest(
            params: [String: JSONValue] = [
                "itemId": .string("item-1"),
                "reason": .string("Update one Project"),
            ],
            server: String = "dahlia",
            tool: String = "update_project",
            approvableMCPServers: Set<String> = ["dahlia"],
            arguments: JSONValue = .object([
                "description": .string("Updated description"),
                "project_id": .string("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"),
                "revision": .number(3),
            ])
        ) throws -> CodexChatApprovalRequest {
            try CodexChatApprovalNormalizer.request(
                id: "s:approval",
                params: params,
                kind: .mcpToolCall,
                fileChanges: [],
                mcpToolCall: CodexChatApprovalNormalizer.boundedMCPToolCall(
                    server: server,
                    tool: tool,
                    arguments: arguments
                ),
                approvableMCPServers: approvableMCPServers
            )
        }

        private var approvalOptions: [JSONValue] {
            [
                .object([
                    "description": .string("Run the tool and continue."),
                    "label": .string("Allow"),
                ]),
                .object([
                    "description": .string("Cancel this tool call."),
                    "label": .string("Cancel"),
                ]),
            ]
        }

        private func approvalParams(itemID: String) -> [String: JSONValue] {
            [
                "itemId": .string(itemID),
                "questions": .array([
                    .object([
                        "header": .string("Approve app tool call?"),
                        "id": .string("mcp_tool_call_approval_\(itemID)"),
                        "options": .array(approvalOptions),
                        "question": .string("Allow the dahlia MCP server to run tool?"),
                    ]),
                ]),
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
            ]
        }
    }
#endif
