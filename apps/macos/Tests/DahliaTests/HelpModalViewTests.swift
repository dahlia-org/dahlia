#if canImport(Testing)
    import AppKit
    import SwiftUI
    import Testing
    @testable import Dahlia

    @MainActor
    struct HelpModalViewTests {
        @Test
        func proseFitsTheMinimumWindowWidth() async throws {
            let host = NSHostingView(rootView: HelpModalView(onClose: {}, onOpenSettings: { _ in }))
            host.frame = CGRect(x: 0, y: 0, width: 720, height: 520)
            let window = NSWindow(contentRect: host.frame, styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            window.makeKeyAndOrderFront(nil)
            host.layoutSubtreeIfNeeded()

            var topicScroll: NSScrollView?
            try #require(await pollUntil {
                topicScroll = scrollViews(in: host).max { $0.bounds.width < $1.bounds.width }
                return topicScroll != nil
            })
            let topic = try #require(topicScroll)
            #expect(topic.bounds.width <= 451)
            #expect(!topic.hasHorizontalScroller)
            #expect(scrollViews(in: host).contains { $0.hasHorizontalScroller })
        }

        @Test(arguments: ["ja", "en"])
        func chatAndAgentDifferencesAreLocalized(language: String) throws {
            let path = try #require(Bundle.appModule.path(forResource: language, ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))
            let keys = [
                "topic", "lead", "column.feature", "column.chat",
                "column.agent", "column.task", "column.intake", "column.scheduled",
                "row.trigger", "row.files", "row.dahlia", "row.connectors",
                "row.resources", "row.web", "row.skills", "row.memory",
                "row.threads", "row.approval", "cell.chat.trigger", "cell.agent.trigger",
                "cell.task.trigger", "cell.intake.trigger", "cell.scheduled.trigger", "cell.chat.files",
                "cell.agent.files", "cell.chat.dahlia", "cell.chat.connectors", "cell.intake.connectors",
                "cell.scheduled.tools", "cell.chat.resources", "cell.chat.web", "cell.chat.skills",
                "cell.intake.skills", "cell.chat.memory", "cell.chat.threads", "cell.agent.threads",
                "cell.chat.approval", "cell.task.approval", "cell.sameAsChat", "cell.readOnly",
                "cell.none", "cell.noWrites", "subagent.title", "subagent.body",
                "other.title", "other.body", "note",
            ]
            for key in keys {
                let fullKey = "help.howItWorks.modes." + key
                #expect(bundle.localizedString(forKey: fullKey, value: nil, table: nil) != fullKey, "\(language): \(key)")
            }
            #expect(HelpModesTable.rows.allSatisfy { $0.cells.count == HelpModesTable.columns.count })
        }

        private func scrollViews(in view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
        }

        @Test(arguments: ["outside", "close", "escape"])
        func dismissesThroughEveryExit(exit: String) async throws {
            var closeCount = 0
            var isLaidOut = false
            let host = NSHostingView(rootView: HelpModalView(onClose: { closeCount += 1 }, onOpenSettings: { _ in })
                .onGeometryChange(for: CGSize.self) { $0.size } action: { isLaidOut = $0.width > 0 })
            host.frame = CGRect(x: 0, y: 0, width: 1100, height: 850)
            let window = NSWindow(contentRect: host.frame, styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            window.makeKeyAndOrderFront(nil)
            host.layoutSubtreeIfNeeded()
            try #require(await pollUntil { isLaidOut })

            // Blank space in the header belongs to the card, not its dismissing backdrop.
            try click(CGPoint(x: 550, y: 790), in: window)
            #expect(closeCount == 0)

            switch exit {
            case "outside":
                try click(CGPoint(x: 12, y: 12), in: window)
            case "close":
                let point = CGPoint(
                    x: 1040 - DahliaDesign.windowHeaderHorizontalPadding - DahliaDesign.windowHeaderControlSize / 2,
                    y: 805 - DahliaDesign.windowHeaderHeight / 2
                )
                try click(point, in: window)
            default:
                let escape = try #require(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                    isARepeat: false, keyCode: 53
                ))
                NSApplication.shared.sendEvent(escape)
            }
            #expect(await pollUntil { closeCount == 1 })
        }

        private func click(_ point: CGPoint, in window: NSWindow) throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0
                ))
                NSApplication.shared.sendEvent(event)
            }
        }
    }
#endif
