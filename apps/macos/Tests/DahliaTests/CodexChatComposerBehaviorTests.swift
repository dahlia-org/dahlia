#if canImport(Testing)
    import AppKit
    import SwiftUI
    import Testing
    @testable import Dahlia

    @MainActor
    struct CodexChatComposerBehaviorTests {
        @Test(arguments: [CodexChatDeliveryMode.queue, .steer], [false, true])
        func commandUsesTheOppositeOfTheSavedBehavior(mode: CodexChatDeliveryMode, commandPressed: Bool) async throws {
            let settings = TestCodexChatFixtures.appSettings()
            settings.chatDeliveryMode = mode
            let service = TestCodexChatService(mode: .blockBeforeOutput)
            let session = CodexChatSessionModel(service: service, settings: settings)
            session.draft = "Start"
            session.sendDraft()
            try #require(await pollUntil { session.activeTurnID != nil })
            session.draft = "Follow-up"
            session.sendDraft(commandPressed: commandPressed)
            if mode.resolved(commandPressed: commandPressed) == .queue {
                #expect(session.pendingManualInputs.map(\.text) == ["Follow-up"])
                #expect(await service.steeredTextBlocks.isEmpty)
            } else {
                try #require(await pollUntil { await service.steeredTextBlocks.count == 1 })
                #expect(await service.steeredTextBlocks == [["Follow-up"]])
            }
            session.stop()
            try #require(await pollUntil { !session.hasPendingGenerationWork })
        }

        @Test
        func savedBehaviorDefaultsToQueueAndIsSharedByNewSessions() throws {
            let suite = "CodexChatComposerBehaviorTests.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = AppSettings(generalDefaults: defaults)
            #expect(settings.chatDeliveryMode == .queue)
            settings.chatDeliveryMode = .steer
            #expect(defaults.string(forKey: AppSettings.chatDeliveryModeUserDefaultsKey) == "steer")
            let restored = AppSettings(generalDefaults: defaults)
            let session = CodexChatSessionModel(service: TestCodexChatService(mode: .complete), settings: restored)
            #expect(session.deliveryMode == .steer)
            settings.chatDeliveryMode = .queue
            #expect(session.deliveryMode == .queue)
        }

        @Test(arguments: [CGFloat(320), 900])
        func shortQueuedMessagesStayCompact(width: CGFloat) throws {
            let session = CodexChatSessionModel(service: TestCodexChatService(mode: .complete), settings: TestCodexChatFixtures.appSettings())
            let input = CodexChatManualSubmission(deliveryMode: .queue, text: "Short", images: [])
            let host = NSHostingView(rootView: CodexChatQueuedInputRow(session: session, input: input)
                .frame(width: width, height: 160, alignment: .top)
                .environment(\.colorScheme, .light)
                .background(.white))
            host.frame = CGRect(x: 0, y: 0, width: width, height: 160)
            host.layoutSubtreeIfNeeded()
            let bitmap = try snapshot(host)
            var leftmost = bitmap.pixelsWide
            for y in 0 ..< bitmap.pixelsHigh {
                for x in 0 ..< bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if min(color.redComponent, color.greenComponent, color.blueComponent) < 0.9 {
                        leftmost = min(leftmost, x)
                    }
                }
            }
            #expect(leftmost < bitmap.pixelsWide)
            #expect(CGFloat(leftmost) / CGFloat(bitmap.pixelsWide) > (width > 500 ? 0.65 : 0.2))
            if let directory = ProcessInfo.processInfo.environment["DAHLIA_CHAT_COMPOSER_SNAPSHOTS"] {
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: directory).appending(path: "queued-\(Int(width)).png"))
            }
        }

        @Test
        func commandStateChangesTheVisibleIconAndSavedPreferenceReversesIt() async throws {
            let suite = "CodexChatComposerModifierTests.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let session = CodexChatSessionModel(service: TestCodexChatService(mode: .complete), settings: AppSettings(generalDefaults: defaults))
            session.isGenerating = true
            session.draft = "Follow-up"
            func button(commandPressed: Bool) -> some View {
                CodexChatSendButton(session: session, isCommandPressed: commandPressed)
                    .defaultAppStorage(defaults)
                    .environment(\.colorScheme, .light)
                    .frame(width: 60, height: 60)
                    .background(.white)
            }
            let host = NSHostingView(rootView: button(commandPressed: false))
            host.frame = CGRect(x: 0, y: 0, width: 60, height: 60)
            let queue = try #require(snapshot(host).tiffRepresentation)
            host.rootView = button(commandPressed: true)
            let steer = try #require(snapshot(host).tiffRepresentation)
            #expect(steer != queue)
            host.rootView = button(commandPressed: false)
            #expect(try snapshot(host).tiffRepresentation == queue)
            defaults.set("steer", forKey: AppSettings.chatDeliveryModeUserDefaultsKey)
            try #require(await pollUntil { (try? snapshot(host).tiffRepresentation) == steer })
            host.rootView = button(commandPressed: true)
            #expect(try snapshot(host).tiffRepresentation == queue)
            session.draft = ""
            let stop = try #require(snapshot(host).tiffRepresentation)
            #expect(stop != queue)
            #expect(stop != steer)
            host.rootView = button(commandPressed: false)
            #expect(try snapshot(host).tiffRepresentation == stop)
        }

        private func snapshot(_ host: NSView, in region: CGRect? = nil) throws -> NSBitmapImageRep {
            host.layoutSubtreeIfNeeded()
            let bounds = region ?? host.bounds
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: bounds))
            host.cacheDisplay(in: bounds, to: bitmap)
            return bitmap
        }
    }
#endif
