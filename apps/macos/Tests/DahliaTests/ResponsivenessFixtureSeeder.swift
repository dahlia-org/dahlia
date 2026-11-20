#if canImport(Testing)
    import AppKit
    import DahliaMeetingAccess
    import DahliaRuntimeSupport
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    /// 応答性の計測用データを開発 profile の DB へ書く道具。通常のテスト実行では動かない。
    /// `apps/macos/scripts/seed-responsiveness-fixture.sh` から、DB のパスを環境変数で渡して実行する。
    struct ResponsivenessFixtureSeeder {
        static let databasePathKey = "DAHLIA_RESPONSIVENESS_FIXTURE_DB"
        static let workspaceName = "Responsiveness Fixture"
        static let meetingCount = 500
        static let transcriptSegmentCount = 5000
        static let screenshotCount = 500

        @Test(.enabled(if: ProcessInfo.processInfo.environment[databasePathKey] != nil))
        func seed() async throws {
            let path = try #require(ProcessInfo.processInfo.environment[Self.databasePathKey])
            let database = try AppDatabaseManager(path: path)
            let queue = database.dbQueue
            let alreadySeeded = try await queue.read { db in
                try WorkspaceRecord.filter(Column("name") == Self.workspaceName).fetchCount(db) > 0
            }
            guard !alreadySeeded else { return }

            let workspace = WorkspaceRecord(id: .v7(), path: nil, name: Self.workspaceName, createdAt: .now, lastOpenedAt: .now)
            let base = Date.now.addingTimeInterval(-Double(Self.meetingCount) * 86400 / 2)
            let meetings = (0 ..< Self.meetingCount).map { index in
                MeetingRecord(
                    id: .v7(),
                    workspaceId: workspace.id,
                    projectId: nil,
                    name: "Fixture meeting \(index + 1) — weekly product and engineering sync",
                    createdAt: base.addingTimeInterval(Double(index) * 43200),
                    updatedAt: base.addingTimeInterval(Double(index) * 43200)
                )
            }
            // 最新の Meeting に長い文字起こしとスクリーンショットを集める。サイドバーの先頭に出る。
            let target = try #require(meetings.last)
            try await queue.write { db in
                try workspace.insert(db)
                for meeting in meetings {
                    try meeting.insert(db)
                }
                for index in 0 ..< Self.transcriptSegmentCount {
                    try TranscriptContent(
                        id: .v7(),
                        meetingId: target.id,
                        startTime: target.createdAt.addingTimeInterval(Double(index) * 2.5),
                        text: Self.sentence(index),
                        translatedText: index.isMultiple(of: 3) ? "Translated line \(index): \(Self.sentence(index + 7))" : nil,
                        isConfirmed: true,
                        audioSource: index.isMultiple(of: 2) ? "mic" : "system"
                    ).insert(db)
                }
            }

            let provider = ScreenshotContentProvider()
            for index in 0 ..< Self.screenshotCount {
                let bytes = try #require(await MainActor.run { Self.screenshotPNG(index) })
                let record = MeetingScreenshotRecord(
                    id: .v7(),
                    meetingId: target.id,
                    capturedAt: target.createdAt.addingTimeInterval(Double(index) * 20),
                    imageData: bytes,
                    mimeType: "image/png"
                )
                try await provider.persistCapture(record, dbQueue: queue)
            }

            let store = ChatThreadStore(dbQueue: queue)
            let thread = ChatThreadRecord(
                id: UUID.v7().uuidString.lowercased(),
                accountID: AppAccountScope.local.storageKey,
                title: "Fixture long answer",
                createdAt: .now,
                updatedAt: .now
            )
            var items: [JSONValue] = []
            for turn in 0 ..< 20 {
                items.append(ChatHistoryCodec.user([.text("Question \(turn): summarize the meeting in detail.")]))
                items.append(ChatHistoryCodec.message(["role": .string("assistant"), "content": .string(Self.longMarkdown(turn))]))
            }
            try store.createThread(thread, items: items)
        }

        private static func sentence(_ index: Int) -> String {
            let words = ["roadmap", "latency", "customer", "release", "dashboard", "migration", "budget", "review", "pipeline", "onboarding"]
            let count = 8 + index % 30
            return (0 ..< count).map { words[($0 * 7 + index) % words.count] }.joined(separator: " ") + "."
        }

        /// 約 50 KB。見出し、箇条書き、表、コードを含む。
        static func longMarkdown(_ seed: Int) -> String {
            var text = ""
            var section = 0
            while text.utf8.count < 50000 {
                section += 1
                text += "## Section \(section)\n\n\(sentence(seed + section)) \(sentence(seed + section * 3))\n\n"
                text += (0 ..< 5).map { "- \(sentence(seed + section + $0))" }.joined(separator: "\n") + "\n\n"
                text += "| Item | Owner | Status | Notes |\n| --- | --- | --- | --- |\n"
                text += (0 ..< 6).map { "| Task \($0) | Team \($0 % 3) | open | \(sentence($0 + section)) |" }.joined(separator: "\n") + "\n\n"
                text += "```swift\nfunc section\(section)() {\n    let value = \(section)\n    print(value)\n}\n```\n\n"
            }
            return text
        }

        /// 1600×1000 の PNG。枚ごとに色と矩形を変え、同じ内容にならないようにする。
        @MainActor
        static func screenshotPNG(_ index: Int) -> Data? {
            let size = NSSize(width: 1600, height: 1000)
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor(calibratedHue: Double(index % 36) / 36, saturation: 0.25, brightness: 0.95, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()
            for row in 0 ..< 24 {
                NSColor(calibratedWhite: 0.2 + Double((row + index) % 5) / 10, alpha: 1).setFill()
                NSRect(x: 80, y: 60 + row * 38, width: 400 + ((row * 97 + index * 31) % 1000), height: 18).fill()
            }
            ("Slide \(index + 1)" as NSString).draw(
                at: NSPoint(x: 80, y: 940),
                withAttributes: [.font: NSFont.systemFont(ofSize: 40, weight: .bold)]
            )
            NSGraphicsContext.restoreGraphicsState()
            return bitmap.representation(using: .png, properties: [:])
        }
    }
#endif
