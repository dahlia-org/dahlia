#if canImport(Testing)
    import AppKit
    import SwiftUI
    import Testing
    @testable import Dahlia

    @MainActor
    struct CodexChatWelcomeLayoutTests {
        @Test(arguments: [CGSize(width: 1000, height: 760), CGSize(width: 420, height: 360), CGSize(width: 320, height: 600)], [false, true])
        func newChatKeepsTheComposerInsideItsViewport(size: CGSize, hasLongDraft: Bool) throws {
            let suite = "CodexChatWelcomeLayoutTests.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let coordinator = CodexChatCoordinator(service: TestCodexChatService(mode: .complete), settings: AppSettings())
            if hasLongDraft {
                coordinator.dockedSession.draft = Array(repeating: "A draft with many lines", count: 15).joined(separator: "\n")
            }
            let view = CodexChatView(
                session: coordinator.dockedSession,
                coordinator: coordinator,
                meetingReferences: [],
                meetingCatalogWorkspaceID: nil,
                isMeetingCatalogLoaded: true,
                showsHistory: .constant(false),
                onNewChat: {}, onOpenHistory: { _ in }, onShowFullScreen: nil, onPopOut: nil,
                reservesSidebarToggle: false, reservesWindowControls: false, headerLeadingInset: 0,
                contentMaxWidth: 1000
            )
            .environment(MainWindowNavigation(openMainWindow: {}, initialSettingsCategory: .general))
            .defaultAppStorage(defaults)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()

            func textEditor(in view: NSView) -> NSTextView? {
                (view as? NSTextView) ?? view.subviews.lazy.compactMap(textEditor(in:)).first
            }
            let editor = try #require(textEditor(in: host))
            // The scrolling document can extend beyond the window; its visible viewport must remain inside it.
            let viewport = try #require(editor.enclosingScrollView?.contentView)
            let frame = host.convert(viewport.bounds, from: viewport)
            #expect(frame.width > 100)
            #expect(frame.height > 10)
            #expect(host.bounds.contains(frame))
            #expect(editor.font?.pointSize == 14)

            if let directory = ProcessInfo.processInfo.environment["DAHLIA_CHAT_WELCOME_SNAPSHOTS"] {
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: directory).appending(path: "chat-\(Int(size.width))x\(Int(size.height))-\(hasLongDraft).png"))
            }
        }
    }
#endif
