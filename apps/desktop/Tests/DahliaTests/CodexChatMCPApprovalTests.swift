import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct CodexChatMCPApprovalTests {
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
            let summary = String(repeating: "summary line\n", count: 400)
            let request = try normalizedRequest(
                tool: "update_meeting_summary",
                arguments: .object(["summary": .string(summary)])
            )

            let encodedArguments = try #require(request.mcpArguments)
            #expect(request.reviewability == .ready)
            #expect(request.canApprove)
            #expect(encodedArguments.utf8.count > 4096)
            let decodedArguments = try JSONDecoder().decode(JSONValue.self, from: Data(encodedArguments.utf8))
            #expect(decodedArguments.objectValue?["summary"]?.stringValue == summary)
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
                    String(repeating: "a", count: CodexChatApprovalNormalizer.byteLimit * 2)
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
        func mismatchedQuestionIsRejected() {
            var params = approvalParams(itemID: "item-1")
            params["questions"] = .array([
                .object([
                    "header": .string("Approve app tool call?"),
                    "id": .string("mcp_tool_call_approval_other-item"),
                    "options": .array(approvalOptions),
                    "question": .string("Allow the dahlia MCP server to run tool?"),
                ]),
            ])

            #expect(CodexChatMCPApprovalPrompt(params: params) == nil)
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
            tool: String = "update_project",
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
                    server: "dahlia",
                    tool: tool,
                    arguments: arguments
                )
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
