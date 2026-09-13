import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct MCPRegistrationCommandsTests {
        @Test
        func unscopedRegistrationIsReadOnlyAndHasNoWorkspaceArgument() throws {
            let commands = MCPRegistrationCommands(helperURL: URL(filePath: "/Applications/Dahlia.app/Contents/Helpers/dahlia-mcp"), workspaceID: nil)
            #expect(commands.registrationCommand(for: .codex, writeEnabled: false)?.contains("--workspace") == false)
            #expect(commands.registrationCommand(for: .codex, writeEnabled: true)?.hasSuffix(" --write") == true)
            #expect(commands.mcpJSONSample(writeEnabled: true)?.contains("--write") == true)
            let sample = try JSONDecoder().decode(MCPJSONSample.self, from: Data(#require(commands.mcpJSONSample(writeEnabled: false)).utf8))
            #expect(sample.mcpServers["dahlia"]?.args.isEmpty == true)
        }

        @Test
        func registrationCommandsAreWorkspaceScopedAndQuoteArguments() throws {
            let workspaceID = try #require(UUID(uuidString: "019F6651-CCBE-7CF2-83B0-6EF955A9FD41"))
            let commands = MCPRegistrationCommands(
                helperURL: URL(filePath: "/Applications/Dahlia's App.app/Contents/Helpers/dahlia-mcp"),
                workspaceID: workspaceID
            )

            let quotedHelper = "'/Applications/Dahlia'\\''s App.app/Contents/Helpers/dahlia-mcp'"
            let quotedWorkspace = "'ws_01kxk53k5yfks87c3ez5atkza1'"
            #expect(commands.registrationCommand(for: .codex, writeEnabled: false)
                == "codex mcp add dahlia -- \(quotedHelper) --workspace-id \(quotedWorkspace)")
            #expect(commands.registrationCommand(for: .codex, writeEnabled: true)
                == "codex mcp add dahlia -- \(quotedHelper) --workspace-id \(quotedWorkspace) --write")
            #expect(commands.registrationCommand(for: .claude, writeEnabled: false)
                == "claude mcp add --scope user dahlia -- \(quotedHelper) --workspace-id \(quotedWorkspace)")
            #expect(commands.registrationCommand(for: .claude, writeEnabled: true)
                == "claude mcp add --scope user dahlia -- \(quotedHelper) --workspace-id \(quotedWorkspace) --write")
            #expect(commands.registrationCommand(for: .mcpJSON, writeEnabled: false) == nil)
        }

        @Test
        func removalCommandsRemainAvailableSeparatelyForReRegistrationHelp() throws {
            let workspaceID = try #require(UUID(uuidString: "019F6651-CCBE-7CF2-83B0-6EF955A9FD41"))
            let commands = MCPRegistrationCommands(
                helperURL: URL(filePath: "/Applications/Dahlia.app/Contents/Helpers/dahlia-mcp"),
                workspaceID: workspaceID
            )

            #expect(commands.removalCommand(for: .codex) == "codex mcp remove dahlia")
            #expect(commands.removalCommand(for: .claude) == "claude mcp remove --scope user dahlia")
            #expect(commands.removalCommand(for: .mcpJSON) == nil)
        }

        @Test
        func mcpJSONSampleReflectsTheSelectedWorkspaceAndWriteAccess() throws {
            let workspaceID = try #require(UUID(uuidString: "019F6651-CCBE-7CF2-83B0-6EF955A9FD41"))
            let commands = MCPRegistrationCommands(
                helperURL: URL(filePath: "/Applications/Dahlia.app/Contents/Helpers/dahlia-mcp"),
                workspaceID: workspaceID
            )

            let json = try #require(commands.mcpJSONSample(writeEnabled: true))
            let sample = try JSONDecoder().decode(
                MCPJSONSample.self,
                from: Data(json.utf8)
            )
            let server = try #require(sample.mcpServers["dahlia"])

            #expect(server.command == "/Applications/Dahlia.app/Contents/Helpers/dahlia-mcp")
            #expect(server.args == ["--workspace-id", "ws_01kxk53k5yfks87c3ez5atkza1", "--write"])

            let commandRange = try #require(json.range(of: "\"command\""))
            let argsRange = try #require(json.range(of: "\"args\""))
            #expect(commandRange.lowerBound < argsRange.lowerBound)
        }

        @Test
        func developmentCommandsInvokeTheHelperDirectly() throws {
            let workspaceID = try #require(UUID(uuidString: "019F6651-CCBE-7CF2-83B0-6EF955A9FD41"))
            let commands = MCPRegistrationCommands(
                helperURL: URL(filePath: "/Applications/Dahlia Dev.app/Contents/Helpers/dahlia-mcp"),
                workspaceID: workspaceID
            )

            let helper = "'/Applications/Dahlia Dev.app/Contents/Helpers/dahlia-mcp'"
            let codex = try #require(commands.registrationCommand(for: .codex, writeEnabled: false))
            let claude = try #require(commands.registrationCommand(for: .claude, writeEnabled: false))
            let codexWrite = try #require(commands.registrationCommand(for: .codex, writeEnabled: true))
            let claudeWrite = try #require(commands.registrationCommand(for: .claude, writeEnabled: true))
            #expect(codex.contains("-- \(helper) --workspace-id"))
            #expect(claude.contains("-- \(helper) --workspace-id"))
            #expect(codexWrite.hasSuffix("--write"))
            #expect(claudeWrite.hasSuffix("--write"))
            #expect(!codex.contains("DAHLIA_RUNTIME_PROFILE"))
            #expect(!claude.contains("DAHLIA_RUNTIME_PROFILE"))

            let json = try #require(commands.mcpJSONSample(writeEnabled: false))
            #expect(!json.contains("\"env\""))
        }

        private struct MCPJSONSample: Decodable {
            let mcpServers: [String: MCPServer]
        }

        private struct MCPServer: Decodable {
            let command: String
            let args: [String]
        }
    }
#endif
