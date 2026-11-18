import DahliaRuntimeSupport
import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct CodexChatToolActivityTests {
        @Test
        func liveEventsCarryTheCommandAndTheTextOutputToOneRow() throws {
            let start = try #require(PiChatService.toolActivity([
                "type": .string("tool_execution_start"), "toolName": .string("bash"), "toolCallId": .string("call"),
                "args": .object(["command": .string("ls -la"), "timeout": .number(5)]),
            ]))
            let end = try #require(PiChatService.toolActivity([
                "type": .string("tool_execution_end"), "toolName": .string("bash"), "toolCallId": .string("call"),
                "result": .object(["content": .array([
                    .object(["type": .string("text"), "text": .string("a")]),
                    .object(["type": .string("text"), "text": .string("b")]),
                ])]),
            ]))
            #expect(start.input == "ls -la")
            #expect(start.output == nil)

            var message = CodexChatMessage(role: .assistant, text: "")
            message.recordToolActivity(start)
            message.recordToolActivity(end)
            #expect(message.toolActivities == [CodexChatToolActivity(
                name: "bash", status: .succeeded, callID: "call", detail: "ls -la", input: "ls -la", output: "a\nb"
            )])
        }

        @Test
        func savedPayloadsShowJSONArgumentsTruncatedPreviewsAndBoundedText() {
            #expect(CodexChatToolActivity.displayInput(.object(["path": .string("/a/b")])) == "{\n  \"path\" : \"/a/b\"\n}")
            #expect(CodexChatToolActivity.displayInput(.null) == nil)
            #expect(CodexChatToolActivity.displayOutput(.object([
                "truncated": .bool(true), "preview": .string("partial"),
            ])) == "partial")
            #expect(CodexChatToolActivity.displayOutput(.string("  ")) == nil)
            let long = CodexChatToolActivity.displayOutput(.string(String(repeating: "x", count: 20000)))
            #expect(long?.count == 16384 + 2)
            #expect(long?.hasSuffix("\n…") == true)
        }
    }
#endif
