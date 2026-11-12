import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct CodexChatSlashCommandTests {
        @Test
        func skillPresentationKeepsTheCommandAndFileIdentity() {
            let skill = CodexChatSlashCommand(
                name: "skill:meeting-reviewer", description: "Review a meeting", source: "skill",
                sourceInfo: .init(path: "/skills/meeting-reviewer/SKILL.md")
            )
            #expect(skill.displayName == "meeting-reviewer")
            #expect(skill.name == "skill:meeting-reviewer")
            #expect(skill.skillFileURL?.deletingLastPathComponent().path == "/skills/meeting-reviewer")
            #expect(CodexChatSlashCommand(name: "mcp", description: nil, source: "extension").displayName == "mcp")
            #expect(CodexChatSlashCommand(name: "skill:missing", description: nil, source: "skill").skillFileURL == nil)
            #expect(CodexChatSlashCommand(
                name: "skill:relative", description: nil, source: "skill", sourceInfo: .init(path: "relative/SKILL.md")
            ).skillFileURL == nil)
        }

        @Test(arguments: [CGRect(x: 0, y: -400, width: 1000, height: 500), CGRect(x: 0, y: -80, width: 280, height: 400)])
        func panelFitsTheViewportAndUsesACompactWidth(bounds: CGRect) {
            let height = CodexChatSlashCommandLayout.maximumHeight(in: bounds, composerHeight: 80)
            let size = CGSize(width: CodexChatSlashCommandLayout.width(in: bounds), height: height)
            let offset = CodexChatSlashCommandLayout.offset(panelSize: size, in: bounds, composerHeight: 80)
            let frame = CGRect(origin: CGPoint(x: offset.width, y: offset.height), size: size)
            #expect(bounds.contains(frame))
            #expect(frame.width <= 320)
            if bounds.minY == -400 { #expect(frame.maxY < 0) }
        }

        @Test
        func onlyCompletesTheLeadingCommandBeforeArguments() {
            #expect(CodexChatSlashCommand.query(in: "/")?.isEmpty == true)
            #expect(CodexChatSlashCommand.query(in: "/skill:meeting") == "skill:meeting")
            for draft in ["hello /", "/skill:meeting ", "/skill:meeting\n", "", " /"] {
                #expect(CodexChatSlashCommand.query(in: draft) == nil)
            }
        }

        @Test
        func filtersByNameAndDescriptionAndBoundsResults() {
            let commands = [
                CodexChatSlashCommand(name: "skill:summary", description: "会議を要約", source: "skill"),
                CodexChatSlashCommand(name: "mcp", description: nil, source: "extension"),
            ]
            #expect(CodexChatSlashCommand.suggestions(from: commands, query: "SUMMARY") == [commands[0]])
            #expect(CodexChatSlashCommand.suggestions(from: commands, query: "会議") == [commands[0]])
            #expect(CodexChatSlashCommand.suggestions(from: commands, query: "unknown").isEmpty)
            let many = (0 ..< 100).map { CodexChatSlashCommand(name: "skill:\($0)", description: nil, source: "skill") }
            #expect(CodexChatSlashCommand.suggestions(from: many, query: "").count == 50)
        }

        @Test
        func decodesPiCommandsWithoutOptionalDescriptions() throws {
            let json = Data(
                #"[{"name":"mcp","source":"extension","sourceInfo":{"scope":"user"}},{"name":"skill:summary","description":"Summarize","source":"skill"}]"#
                    .utf8
            )
            let commands = try JSONDecoder().decode([CodexChatSlashCommand].self, from: json)
            #expect(commands.map(\.name) == ["mcp", "skill:summary"])
            #expect(commands[0].description == nil)
        }
    }
#endif
