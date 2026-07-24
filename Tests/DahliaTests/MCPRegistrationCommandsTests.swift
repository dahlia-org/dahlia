import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct MCPRegistrationCommandsTests {
        @Test
        func commandsReplaceOneVaultScopedServerAndQuoteArguments() throws {
            let vaultID = try #require(UUID(uuidString: "019F6651-CCBE-7CF2-83B0-6EF955A9FD41"))
            let commands = MCPRegistrationCommands(
                helperURL: URL(filePath: "/Applications/Dahlia's App.app/Contents/Helpers/dahlia-mcp"),
                vaultID: vaultID,
                runtimeProfile: .production
            )

            let quotedHelper = "'/Applications/Dahlia'\\''s App.app/Contents/Helpers/dahlia-mcp'"
            let quotedVault = "'019F6651-CCBE-7CF2-83B0-6EF955A9FD41'"
            #expect(commands.codex == "codex mcp remove dahlia\ncodex mcp add dahlia -- \(quotedHelper) --vault-id \(quotedVault)")
            #expect(commands.codexWrite
                == "codex mcp remove dahlia\ncodex mcp add dahlia -- \(quotedHelper) --vault-id \(quotedVault) --write")
            #expect(commands
                .claude == "claude mcp remove --scope user dahlia\nclaude mcp add --scope user dahlia -- \(quotedHelper) --vault-id \(quotedVault)")
            #expect(commands.claudeWrite
                == "claude mcp remove --scope user dahlia\nclaude mcp add --scope user dahlia -- \(quotedHelper) --vault-id \(quotedVault) --write")
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
            #expect(commands.codex.contains("-- \(invocation) --vault-id"))
            #expect(commands.claude.contains("-- \(invocation) --vault-id"))
            #expect(commands.codexWrite.hasSuffix("--write"))
            #expect(commands.claudeWrite.hasSuffix("--write"))
        }
    }
#endif
