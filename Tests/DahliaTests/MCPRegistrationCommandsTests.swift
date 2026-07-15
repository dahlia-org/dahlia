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
                vaultID: vaultID
            )

            let quotedHelper = "'/Applications/Dahlia'\\''s App.app/Contents/Helpers/dahlia-mcp'"
            let quotedVault = "'019F6651-CCBE-7CF2-83B0-6EF955A9FD41'"
            #expect(commands.codex == "codex mcp remove dahlia\ncodex mcp add dahlia -- \(quotedHelper) --vault-id \(quotedVault)")
            #expect(commands
                .claude == "claude mcp remove --scope user dahlia\nclaude mcp add --scope user dahlia -- \(quotedHelper) --vault-id \(quotedVault)")
        }
    }
#endif
