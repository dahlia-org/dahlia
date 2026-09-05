import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct MCPVaultDisplayNameTests {
        @Test
        func duplicateVaultNamesIncludePaths() {
            let first = makeVault(id: .v7(), path: "/Users/example/Customers/Meetings")
            let second = makeVault(id: .v7(), path: "/Users/example/Internal/Meetings")

            #expect(MCPVaultDisplayName.resolve(for: first, among: [first, second]) ==
                "Meetings — /Users/example/Customers/Meetings")
            #expect(MCPVaultDisplayName.resolve(for: second, among: [first, second]) ==
                "Meetings — /Users/example/Internal/Meetings")
        }

        @Test
        func uniqueVaultNameRemainsConcise() {
            let vault = makeVault(id: .v7(), path: "/Users/example/Customers")

            #expect(MCPVaultDisplayName.resolve(for: vault, among: [vault]) == "Customers")
        }

        private func makeVault(id: UUID, path: String) -> VaultRecord {
            VaultRecord(
                id: id,
                path: path,
                name: URL(filePath: path).lastPathComponent,
                createdAt: .distantPast,
                lastOpenedAt: .distantPast
            )
        }
    }
#endif
