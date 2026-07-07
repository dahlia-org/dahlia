import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct FolderProjectServiceTests {
        @Test
        func createsAndUpdatesContextFile() throws {
            let service = FolderProjectService()
            let projectURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: projectURL)
            }

            let contextURL = try #require(service.ensureContextFileExists(at: projectURL))
            let initialContent = try service.readContext(at: projectURL)

            #expect(contextURL.lastPathComponent == "CONTEXT.md")
            #expect(initialContent.contains("<context>"))

            let updatedContent = "# context\n<context>\nProject-specific context.\n</context>\n"
            try service.writeContext(updatedContent, at: projectURL)

            #expect(try service.readContext(at: projectURL) == updatedContent)
        }
    }
#endif
