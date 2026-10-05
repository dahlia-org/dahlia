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

        @Test
        func keepsReadableLinesWhenAFileHasInvalidUTF8() async throws {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // 前回プロセスが「エ」(E3 82 A8) の途中で終了した行を再現する。
            let tornLine = Data("before crash\ntorn ".utf8) + Data([0xE3, 0x82]) + Data("\n".utf8)
            try tornLine.write(to: directory.appending(path: "Dahlia.log"))
            let file = ApplicationLogFile(directoryURL: directory)
            file.start()

            file.append("after relaunch", level: .notice, category: "Test")
            let lines = await file.recentLines(limit: 10)

            #expect(lines.first == "before crash")
            #expect(lines.last?.hasSuffix("[NOTICE] [Test] after relaunch") == true)
        }

        private func temporaryDirectory() -> URL {
            FileManager.default.temporaryDirectory.appending(path: "application-log-\(UUID.v7())", directoryHint: .isDirectory)
        }
    }
#endif
