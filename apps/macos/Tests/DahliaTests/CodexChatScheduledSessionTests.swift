#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    extension CodexChatSessionModelTests {
        @Test
        func readOnlyLiveThreadCanStopWithoutSendingInput() async {
            let service = TestCodexChatService(mode: .block)
            await service.addLiveAttachment(isReadOnly: true)
            let settings = AppSettings()
            settings.currentWorkspace = WorkspaceRecord(
                id: .v7(),
                path: "/tmp/scheduled-chat-test",
                name: "Test",
                createdAt: .now,
                lastOpenedAt: .now
            )
            let session = CodexChatSessionModel(backendThreadID: "thread-1", service: service, settings: settings)
            await session.restore()
            #expect(await pollUntil { @MainActor in session.isReadOnly && session.isGenerating })
            #expect(session.isReadOnly && session.isGenerating)
            session.draft = "Must not send"
            session.sendDraft()
            #expect(!session.canSend)
            #expect(await service.sentTextBlocks.isEmpty)
            session.stop()
            #expect(await pollUntil { @MainActor in !session.isGenerating })
            #expect(await pollUntil { await service.interruptCount == 1 })
            #expect(await service.interruptCount == 1)
            #expect(!session.isGenerating)
            #expect(session.messages.contains { $0.text == "Saved partial" })
        }

    }
#endif
