import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct MCPRegistrationCommandsTests {
        @Test
        func registrationCommandsAreVaultScopedAndQuoteArguments() throws {
            let vaultID = try #require(UUID(uuidString: "019F6651-CCBE-7CF2-83B0-6EF955A9FD41"))
            let commands = MCPRegistrationCommands(
                helperURL: URL(filePath: "/Applications/Dahlia's App.app/Contents/Helpers/dahlia-mcp"),
                vaultID: vaultID,
                runtimeProfile: .production
            )

            let quotedHelper = "'/Applications/Dahlia'\\''s App.app/Contents/Helpers/dahlia-mcp'"
            let quotedVault = "'019F6651-CCBE-7CF2-83B0-6EF955A9FD41'"
            #expect(commands.registrationCommand(for: .codex, writeEnabled: false)
                == "codex mcp add dahlia -- \(quotedHelper) --vault-id \(quotedVault)")
            #expect(commands.registrationCommand(for: .codex, writeEnabled: true)
                == "codex mcp add dahlia -- \(quotedHelper) --vault-id \(quotedVault) --write")
            #expect(commands.registrationCommand(for: .claude, writeEnabled: false)
                == "claude mcp add --scope user dahlia -- \(quotedHelper) --vault-id \(quotedVault)")
            #expect(commands.registrationCommand(for: .claude, writeEnabled: true)
                == "claude mcp add --scope user dahlia -- \(quotedHelper) --vault-id \(quotedVault) --write")
        }

        @Test
        func removalCommandsRemainAvailableSeparatelyForReRegistrationHelp() throws {
            let vaultID = try #require(UUID(uuidString: "019F6651-CCBE-7CF2-83B0-6EF955A9FD41"))
            let commands = MCPRegistrationCommands(
                helperURL: URL(filePath: "/Applications/Dahlia.app/Contents/Helpers/dahlia-mcp"),
                vaultID: vaultID,
                runtimeProfile: .production
            )

            #expect(commands.removalCommand(for: .codex) == "codex mcp remove dahlia")
            #expect(commands.removalCommand(for: .claude) == "claude mcp remove --scope user dahlia")
        }

        @Test
        func mcpJSONSampleReflectsTheSelectedVaultAndWriteAccess() throws {
            let vaultID = try #require(UUID(uuidString: "019F6651-CCBE-7CF2-83B0-6EF955A9FD41"))
            let commands = MCPRegistrationCommands(
                helperURL: URL(filePath: "/Applications/Dahlia.app/Contents/Helpers/dahlia-mcp"),
                vaultID: vaultID,
                runtimeProfile: .production
            )

            let json = try #require(commands.mcpJSONSample(writeEnabled: true))
            let sample = try JSONDecoder().decode(
                MCPJSONSample.self,
                from: Data(json.utf8)
            )
            let server = try #require(sample.mcpServers["dahlia"])

            #expect(server.command == "/Applications/Dahlia.app/Contents/Helpers/dahlia-mcp")
            #expect(server.args == ["--vault-id", vaultID.uuidString, "--write"])
            #expect(server.env == nil)
        }

        @Test
        func developmentCommandsPreserveTheDevelopmentProfileForExternalHelpers() throws {
            let vaultID = try #require(UUID(uuidString: "019F6651-CCBE-7CF2-83B0-6EF955A9FD41"))
            let commands = MCPRegistrationCommands(
                helperURL: URL(filePath: "/Applications/Dahlia Dev.app/Contents/Helpers/dahlia-mcp"),
                vaultID: vaultID,
                runtimeProfile: .development
            )

            let invocation = "/usr/bin/env 'DAHLIA_RUNTIME_PROFILE=development' '/Applications/Dahlia Dev.app/Contents/Helpers/dahlia-mcp'"
            #expect(commands.registrationCommand(for: .codex, writeEnabled: false).contains("-- \(invocation) --vault-id"))
            #expect(commands.registrationCommand(for: .claude, writeEnabled: false).contains("-- \(invocation) --vault-id"))
            #expect(commands.registrationCommand(for: .codex, writeEnabled: true).hasSuffix("--write"))
            #expect(commands.registrationCommand(for: .claude, writeEnabled: true).hasSuffix("--write"))

            let json = try #require(commands.mcpJSONSample(writeEnabled: false))
            let sample = try JSONDecoder().decode(
                MCPJSONSample.self,
                from: Data(json.utf8)
            )
            #expect(sample.mcpServers["dahlia"]?.env == ["DAHLIA_RUNTIME_PROFILE": "development"])
        }

        private struct MCPJSONSample: Decodable {
            let mcpServers: [String: MCPServer]
        }

        private struct MCPServer: Decodable {
            let command: String
            let args: [String]
            let env: [String: String]?
        }
    }
#endif
