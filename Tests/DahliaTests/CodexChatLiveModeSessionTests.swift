import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CodexChatLiveModeSessionTests {
        @Test
        func manualMessageOmitsContextBeforeTheFirstTranscript() async {
            let service = TestCodexChatService(mode: .staleRollout)
            let settings = AppSettings()
            settings.currentVault = Self.testVault()
            let session = Self.session(service: service, settings: settings)

            session.toggleLiveMode()
            session.draft = "Manual question"
            session.sendDraft()
            await waitUntil { !session.isGenerating }

            #expect(await service.sentTextBlocks == [["Manual question"]])

            session.receiveFinalizedLiveTranscript("First live speech")
            await waitUntil { !session.isGenerating }

            #expect(await service.sentTextBlocks.last == [
                TestCodexChatFixtures.liveTranscriptContext,
                "<live_transcript source=\"dahlia\">First live speech</live_transcript>",
            ])
        }

        @Test
        func contextIsResolvedOnlyForTheFirstTranscriptOfEachSession() async throws {
            let service = TestCodexChatService(mode: .staleRollout)
            let settings = AppSettings()
            settings.currentVault = Self.testVault()
            let context = CodexChatContext.meeting(
                id: try #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")),
                name: "Current meeting",
                calendarEvent: nil
            )
            let contextProvider = TestCodexChatContextProvider(context: context)
            let session = Self.session(
                service: service,
                settings: settings,
                contextProvider: contextProvider
            )

            session.toggleLiveMode()
            session.draft = "Manual question"
            session.sendDraft()
            await waitUntil { !session.isGenerating }

            #expect(contextProvider.requestCount == 0)
            #expect(session.messages.first(where: { $0.role == .user })?.context == nil)

            session.receiveFinalizedLiveTranscript("First transcript")
            await waitUntil { !session.isGenerating }
            session.receiveFinalizedLiveTranscript("Second transcript")
            await waitUntil { !session.isGenerating }

            #expect(contextProvider.requestCount == 1)
            #expect(await service.sentTextBlocks.suffix(2).map { $0.first } == [
                CodexChatPromptCodec.encodeTextBlocks(
                    text: nil,
                    context: context,
                    includesLiveModeContext: true,
                    liveTranscript: "First transcript"
                ).first,
                "<live_transcript source=\"dahlia\">Second transcript</live_transcript>",
            ])

            session.disableLiveMode()
            session.toggleLiveMode()
            session.receiveFinalizedLiveTranscript("New session transcript")
            await waitUntil { !session.isGenerating }

            #expect(contextProvider.requestCount == 2)
            #expect(await service.sentTextBlocks.last?.first == CodexChatPromptCodec.encodeTextBlocks(
                text: nil,
                context: context,
                includesLiveModeContext: true,
                liveTranscript: "New session transcript"
            ).first)
        }

        @Test
        func staleSendCannotMarkANewSessionAsContextualized() async {
            let service = TestCodexChatService(mode: .delayFirstSendIgnoringCancellation)
            let settings = AppSettings()
            settings.currentVault = Self.testVault()
            let session = Self.session(service: service, settings: settings)

            session.toggleLiveMode()
            session.receiveFinalizedLiveTranscript("Old session")
            await waitUntilAsync { await service.isSendWaiting }

            session.disableLiveMode()
            session.toggleLiveMode()
            session.receiveFinalizedLiveTranscript("New session")
            await waitUntilAsync { await service.sentTextBlocks.count == 2 }
            await service.resumeDelayedSend()
            await waitUntil { !session.isGenerating }

            let sentTextBlocks = await service.sentTextBlocks
            #expect(sentTextBlocks[0].first == TestCodexChatFixtures.liveTranscriptContext)
            #expect(sentTextBlocks[1].first == TestCodexChatFixtures.liveTranscriptContext)
        }

        private static func session(
            service: TestCodexChatService,
            settings: AppSettings,
            contextProvider: any CodexChatContextProviding = TestCodexChatContextProvider()
        ) -> CodexChatSessionModel {
            CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings,
                contextProvider: contextProvider
            )
        }

        private static func testVault() -> VaultRecord {
            VaultRecord(
                id: .v7(),
                path: "/tmp/chat-live-mode-session-test-vault",
                name: "Chat Live Mode Session Test",
                createdAt: .now,
                lastOpenedAt: .now
            )
        }

        private func waitUntil(_ predicate: @MainActor () -> Bool) async {
            for _ in 0 ..< 1000 {
                if predicate() { return }
                await Task.yield()
            }
            Issue.record("Timed out waiting for chat state")
        }

        private func waitUntilAsync(_ predicate: @escaping @Sendable () async -> Bool) async {
            for _ in 0 ..< 1000 {
                if await predicate() { return }
                await Task.yield()
            }
            Issue.record("Timed out waiting for async chat state")
        }
    }
#endif
