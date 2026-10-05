import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct ApplicationLogFileTests {
        @Test
        func ignoresLinesBeforeStart() async {
            let file = ApplicationLogFile(directoryURL: temporaryDirectory())

            file.append("before start", level: .notice, category: "Test")

            #expect(await file.recentLines(limit: 10).isEmpty)
        }

        @Test
        func rotatesAndKeepsNewestLinesAcrossFiles() async throws {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = ApplicationLogFile(directoryURL: directory, maximumFileBytes: 200, maximumFileCount: 3)
            file.start()

            for index in 0 ..< 20 {
                file.append("line \(index)\nnext", level: .error, category: "Test")
            }
            let lines = await file.recentLines(limit: 100)

            let fileNames = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
            #expect(fileNames == ["Dahlia.1.log", "Dahlia.2.log", "Dahlia.log"])
            #expect(lines.allSatisfy { $0.contains("[ERROR] [Test] line ") && $0.hasSuffix(" next") })
            #expect(lines.last?.contains("line 19 next") == true)
            #expect(lines.first?.contains("line 0 next") == false)
            #expect(await file.recentLines(limit: 2).count == 2)
        }

        private func temporaryDirectory() -> URL {
            FileManager.default.temporaryDirectory.appending(path: "application-log-\(UUID.v7())", directoryHint: .isDirectory)
        }
    }
#endif
