#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    @MainActor
    struct CodexChatSubscriptionTests {
        @Test(arguments: [false, true], [false, true])
        func readerOverflowResynchronizesWithoutAResend(attached: Bool, stillRunning: Bool) async {
            let service = TestCodexChatService(mode: .readerOverflow)
            let settings = AppSettings()
            let session = CodexChatSessionModel(backendThreadID: attached ? "thread-1" : nil, service: service, settings: settings)
            if attached {
                await service.setAttachment(CodexChatTurnHandle(id: .v7(), events: TestCodexChatService.overflowStream()))
            }
            if stillRunning { await service.addLiveAttachment() }
            if attached {
                await session.synchronizeThread()
            } else {
                session.draft = "Question"
                session.sendDraft()
            }
            if stillRunning {
                #expect(await pollUntil { session.isGenerating && session.messages.contains { $0.text == "Saved partial" } })
                await service.completeBlockedTurn()
            }
            #expect(await pollUntil { !session.isGenerating && session.messages.last?.text == "Final answer" })
            #expect(session.errorMessage == nil)
            #expect(session.messages.filter { $0.role == .assistant }.map(\.text) == ["Final answer"])
            #expect(await service.sentTextBlocks.count == (attached ? 0 : 1))
        }

        @Test
        func aRunThisViewShowedToItsEndIsNotFollowedAgainWhileItWindsDown() async {
            let service = TestCodexChatService(mode: .complete)
            let session = CodexChatSessionModel(backendThreadID: "thread-1", service: service, settings: AppSettings())
            let runID = UUID.v7()
            let (events, reader) = AsyncThrowingStream<CodexChatTurnEvent, any Error>.makeStream()
            await service.setAttachment(CodexChatTurnHandle(id: runID, events: events))
            await session.synchronizeThread()
            #expect(session.isGenerating)
            // The service still reports the same run, as it does between a stop and the runtime settling.
            for _ in 0 ..< 2 {
                await service.setAttachment(CodexChatTurnHandle(id: runID, events: AsyncThrowingStream { _ in }))
            }
            reader.finish()
            #expect(await pollUntil { !session.isGenerating })
            await session.synchronizeThread()
            #expect(!session.isGenerating)
        }

        @Test
        func attachingToARunThisViewDidNotStartKeepsTheModelPickedForTheNextMessage() async {
            let service = TestCodexChatService(mode: .complete)
            let session = CodexChatSessionModel(backendThreadID: "thread-1", service: service, settings: AppSettings())
            session.selectModel("picked-model")
            let (events, reader) = AsyncThrowingStream<CodexChatTurnEvent, any Error>.makeStream()
            let snapshot = CodexChatThread(id: "thread-1", title: "Requested", messages: [], model: "agent-model", reasoningEffort: "high")
            await service.setAttachment(CodexChatTurnHandle(id: .v7(), events: events, snapshot: snapshot))
            await session.synchronizeThread()
            #expect(session.isGenerating)
            #expect(session.selectedModelID == "picked-model")
            reader.finish()
            #expect(await pollUntil { !session.isGenerating })
            #expect(session.selectedModelID == "picked-model")
        }

    }

    extension TestCodexChatService {
        nonisolated static func overflowStream() -> AsyncThrowingStream<CodexChatTurnEvent, any Error> {
            let (stream, reader) = AsyncThrowingStream<CodexChatTurnEvent, any Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
            var broadcast = ChatTurnBroadcast()
            broadcast.readers[.v7()] = reader
            for _ in 0 ..< 300 {
                broadcast.yield(.delta(itemID: "partial", text: "x"))
            }
            broadcast.finish()
            return stream
        }

    }
#endif
