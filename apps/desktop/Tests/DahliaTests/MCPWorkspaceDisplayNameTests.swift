import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct MCPWorkspaceDisplayNameTests {
        @Test
        func duplicateWorkspaceNamesIncludePaths() {
            let first = makeWorkspace(id: .v7(), path: "/Users/example/Customers/Meetings")
            let second = makeWorkspace(id: .v7(), path: "/Users/example/Internal/Meetings")

            #expect(MCPWorkspaceDisplayName.resolve(for: first, among: [first, second]) ==
                "Meetings — /Users/example/Customers/Meetings")
            #expect(MCPWorkspaceDisplayName.resolve(for: second, among: [first, second]) ==
                "Meetings — /Users/example/Internal/Meetings")
        }

        @Test
        func uniqueWorkspaceNameRemainsConcise() {
            let workspace = makeWorkspace(id: .v7(), path: "/Users/example/Customers")

            #expect(MCPWorkspaceDisplayName.resolve(for: workspace, among: [workspace]) == "Customers")
        }

        private func makeWorkspace(id: UUID, path: String) -> WorkspaceRecord {
            WorkspaceRecord(
                id: id,
                path: path,
                name: URL(filePath: path).lastPathComponent,
                createdAt: .distantPast,
                lastOpenedAt: .distantPast
            )
        }
    }
#endif
