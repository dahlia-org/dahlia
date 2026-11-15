#if canImport(Testing)
    import AppKit
    import SwiftUI
    import Testing
    @testable import Dahlia

    @MainActor
    struct AgentMemoryEditorTests {
        @Test(
            arguments: [CGSize(width: 800, height: 1600), CGSize(width: 800, height: 600), CGSize(width: 420, height: 500)],
            ["", String(repeating: "長いメモリーの内容\n", count: 100)]
        )
        func editorKeepsABoundedViewportAndRoomForActions(size: CGSize, content: String) throws {
            let model = AgentLearningSettingsModel(account: .local)
            let host = NSHostingView(rootView: AgentMemoryEditor(
                model: model, target: "user", content: content, onClose: {}, onSave: { _ in }
            ))
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()

            func textEditor(in view: NSView) -> NSTextView? {
                (view as? NSTextView) ?? view.subviews.lazy.compactMap(textEditor(in:)).first
            }
            let editor = try #require(textEditor(in: host))
            let viewport = try #require(editor.enclosingScrollView?.contentView)
            let frame = host.convert(viewport.bounds, from: viewport)
            #expect(frame.height >= 100)
            #expect(frame.height <= 220)
            #expect(frame.width >= 200)
            #expect(host.bounds.insetBy(dx: 24, dy: 60).contains(frame))
            #expect(editor.string == content)
            #expect(editor.font?.pointSize == NSFont.dahliaBody.pointSize)

            if let directory = ProcessInfo.processInfo.environment["DAHLIA_MEMORY_EDITOR_SNAPSHOTS"] {
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data
                    .write(to: URL(fileURLWithPath: directory)
                        .appending(path: "memory-\(Int(size.width))x\(Int(size.height))-\(content.isEmpty).png"))
            }
        }
    }
#endif
