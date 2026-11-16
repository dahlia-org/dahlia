#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    @MainActor
    struct CodexChatSubscriptionTests {
        @Test
        func noticePreservingReconciliationKeepsChildCardsAcrossManualRuns() async throws {
            let service = TestCodexChatService(mode: .blockBeforeOutput)
            let session = CodexChatSessionModel(
                messages: [CodexChatMessage(role: .notice(.info), text: "Earlier result")],
                service: service, settings: AppSettings()
            )
            session.draft = "Delegate"
            session.sendDraft()
            #expect(await pollUntil { session.activeTurnHandleID != nil })
            let runID = try #require(session.activeTurnHandleID)
            await service.yieldBlockedEvent(.delta(itemID: "reply", text: "Started"))
            await service.completeBlockedTurn()
            #expect(await pollUntil { !session.hasPendingGenerationWork })
            let reply = try #require(session.messages.first { $0.role == .assistant && $0.runID == runID })
            let child = CodexChatThreadSummary(
                id: "child", title: "Child", updatedAt: .now, requestMessageID: "saved-question", requestRunID: runID
            )
            #expect(CodexChatConversationItem.relatedThreadAnchors(
                threads: [child], messages: session.messages, currentRunID: nil
            ) == [reply.id: [child]])
            session.draft = "Next task"
            session.sendDraft()
            #expect(await pollUntil { session.activeTurnHandleID != nil && session.activeTurnHandleID != runID })
            #expect(CodexChatConversationItem.relatedThreadAnchors(
                threads: [child], messages: session.messages, currentRunID: session.activeTurnHandleID
            ) == [reply.id: [child]])
            session.stop()
            #expect(await pollUntil { !session.hasPendingGenerationWork })
        }

        @Test
        func cancellingAToolOnlyResponseKeepsItsToolRow() async {
            let service = TestCodexChatService(mode: .blockBeforeOutput)
            let session = CodexChatSessionModel(service: service, settings: AppSettings())
            session.draft = "Inspect"
            session.sendDraft()
            #expect(await pollUntil { session.activeTurnHandleID != nil })
            let activity = CodexChatToolActivity(name: "read", status: .running, callID: "call")
            await service.yieldBlockedEvent(.toolActivity(activity))
            #expect(await pollUntil { session.toolActivity == activity })
            session.stop()
            #expect(await pollUntil { !session.hasPendingGenerationWork })
            #expect(session.messages.flatMap(\.toolActivities) == [activity])
        }

        @Test
        func attachedToolReplayUpdatesTheExistingRowWithinItsRun() async {
            let service = TestCodexChatService(mode: .complete)
            let runID = UUID.v7()
            let previousRunID = UUID.v7()
            let running = CodexChatToolActivity(name: "read", status: .running, callID: "shared", detail: "README.md")
            let succeeded = CodexChatToolActivity(name: "read", status: .succeeded, callID: "shared")
            let previous = CodexChatMessage(id: "previous", role: .assistant, text: "Earlier", toolActivities: [succeeded], runID: previousRunID)
            let restored = CodexChatMessage(id: "saved-call", role: .assistant, text: "Inspecting", toolActivities: [running], runID: runID)
            let snapshot = CodexChatThread(id: "thread-1", title: "Thread", messages: [previous, restored], model: nil, reasoningEffort: nil)
            let (events, reader) = AsyncThrowingStream<CodexChatTurnEvent, any Error>.makeStream()
            await service.setAttachment(CodexChatTurnHandle(id: runID, events: events, snapshot: snapshot))
            let session = CodexChatSessionModel(backendThreadID: "thread-1", service: service, settings: AppSettings())
            await session.synchronizeThread()
            reader.yield(.toolActivity(running))
            #expect(await pollUntil { session.toolActivity == running })
            #expect(session.messages.flatMap(\.toolActivities).count == 2)
            reader.yield(.toolActivity(succeeded))
            #expect(await pollUntil { session.toolActivity == succeeded })
            #expect(session.messages.first == previous)
            #expect(session.messages.first { $0.id == "saved-call" }?.toolActivities == [
                .init(name: "read", status: .succeeded, callID: "shared", detail: "README.md"),
            ])
            #expect(session.messages.flatMap(\.toolActivities).count == 2)
            reader.yield(.completed(itemID: nil, text: nil))
            reader.finish()
            #expect(await pollUntil { !session.isGenerating })
        }

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
