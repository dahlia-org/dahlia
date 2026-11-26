#if canImport(Testing)
    import DahliaRuntimeSupport
    import Foundation
    import Testing
    @testable import Dahlia

    @MainActor
    struct CodexChatFreshSessionTests {
        @Test(arguments: [false, true])
        func queuedResetStaysWithItsSubmissionThroughEditingAndRemoval(removeReset: Bool) async throws {
            let service = TestCodexChatService(mode: .blockBeforeOutput)
            let session = CodexChatSessionModel(service: service, settings: TestCodexChatFixtures.appSettings())
            session.draft = "Root"
            session.sendDraft()
            try #require(await pollUntil { session.activeTurnID != nil })
            session.draft = "A"
            session.sendDraft(mode: .queue)
            session.armFreshSession()
            session.draft = "B"
            session.sendDraft(mode: .steer)
            session.draft = "C"
            session.sendDraft(mode: .steer)
            #expect(session.pendingManualInputs.map(\.startsFreshSession) == [false, true, false])
            let reset = try #require(session.pendingManualInputs.first { $0.startsFreshSession })
            #expect(!session.canSendPendingInput(reset))
            #expect(await service.steeredTextBlocks.isEmpty)
            session.beginEditingPendingInput(id: reset.id)
            session.savePendingInput(id: reset.id, draft: "B edited", images: [])
            #expect(session.pendingManualInputs.first { $0.id == reset.id }?.startsFreshSession == true)
            if removeReset {
                session.removePendingInput(id: reset.id)
                try #require(await pollUntil { await service.steeredTextBlocks.count == 1 })
                #expect(!session.pendingManualInputs.contains { $0.startsFreshSession })
            } else {
                await service.completeBlockedTurn()
                try #require(await pollUntil { await service.freshSessionStarts.count == 2 && session.activeTurnID != nil })
                #expect(await service.freshSessionStarts == [false, false])
                await service.completeBlockedTurn()
                try #require(await pollUntil { await service.freshSessionStarts.count == 3 && session.activeTurnID != nil })
                #expect(await service.freshSessionStarts == [false, false, true])
                try #require(await pollUntil { await service.steeredTextBlocks.count == 1 })
            }
            session.stop()
            try #require(await pollUntil { !session.hasPendingGenerationWork })
        }

        @Test
        func idleSendNowCannotCrossAResetInEitherDirection() async throws {
            let service = TestCodexChatService(mode: .blockBeforeOutput)
            let session = CodexChatSessionModel(service: service, settings: TestCodexChatFixtures.appSettings())
            session.draft = "Root"
            session.sendDraft()
            try #require(await pollUntil { session.activeTurnID != nil })
            session.draft = "A"
            session.sendDraft(mode: .queue)
            session.armFreshSession()
            session.draft = "B"
            session.sendDraft(mode: .queue)
            session.draft = "C"
            session.sendDraft(mode: .queue)
            session.stop()
            try #require(await pollUntil { !session.hasPendingGenerationWork })
            let queued = session.pendingManualInputs
            try #require(queued.count == 3)
            #expect(session.canSendPendingInput(queued[0]))
            #expect(!session.canSendPendingInput(queued[1]))
            #expect(!session.canSendPendingInput(queued[2]))
            session.sendPendingInputNow(id: queued[2].id)
            session.sendPendingInputNow(id: queued[1].id)
            #expect(session.pendingManualInputs == queued)
            #expect(await service.freshSessionStarts == [false])
            session.removePendingInput(id: queued[0].id)
            #expect(session.canSendPendingInput(queued[1]))
            #expect(!session.canSendPendingInput(queued[2]))
            session.sendPendingInputNow(id: queued[1].id)
            try #require(await pollUntil { session.activeTurnID != nil })
            #expect(await service.freshSessionStarts == [false, true])
            await service.completeBlockedTurn()
            try #require(await pollUntil { await service.freshSessionStarts.count == 3 && session.activeTurnID != nil })
            #expect(await service.freshSessionStarts == [false, true, false])
            session.stop()
            try #require(await pollUntil { !session.hasPendingGenerationWork })
        }

        @Test
        func newInputAfterFailureWaitsBehindTheQueuedReset() async throws {
            let service = TestCodexChatService(mode: .blockBeforeOutput)
            let session = CodexChatSessionModel(service: service, settings: TestCodexChatFixtures.appSettings())
            session.draft = "A"
            session.sendDraft()
            try #require(await pollUntil { session.activeTurnID != nil })
            session.armFreshSession()
            session.draft = "B"
            session.sendDraft(mode: .queue)
            await service.completeBlockedTurn(with: .failed(message: "Test failure"))
            try #require(await pollUntil { !session.isGenerating && !session.isTurnCleanupPending && session.errorMessage != nil })
            try #require(session.errorMessage != nil)
            session.draft = "C"
            session.sendDraft(mode: .queue)
            #expect(session.pendingManualInputs.map(\.text) == ["B", "C"])
            #expect(await service.freshSessionStarts == [false])
            session.retry()
            try #require(await pollUntil { session.activeTurnID != nil })
            #expect(await service.freshSessionStarts == [false, false])
            await service.completeBlockedTurn()
            try #require(await pollUntil { await service.freshSessionStarts.count == 3 && session.activeTurnID != nil })
            #expect(await service.freshSessionStarts == [false, false, true])
            session.stop()
            try #require(await pollUntil { !session.hasPendingGenerationWork })
        }

        @Test(arguments: [false, true])
        func skippingRepeatedFailurePreservesResetAndFollowingQueue(paused: Bool) async throws {
            let service = TestCodexChatService(mode: .blockBeforeOutput)
            let session = CodexChatSessionModel(service: service, settings: TestCodexChatFixtures.appSettings())
            session.draft = "A"
            session.sendDraft()
            try #require(await pollUntil { session.activeTurnID != nil })
            session.armFreshSession()
            session.draft = "B"
            session.sendDraft(mode: .queue)
            await service.completeBlockedTurn(with: .failed(message: "Test failure"))
            try #require(await pollUntil { !session.isGenerating && session.errorMessage != nil })
            session.draft = "C"
            session.sendDraft(mode: .queue)
            await service.failNextTurn(with: .invalidProtocolResponse)
            session.retry()
            try #require(await pollUntil { !session.isGenerating && session.errorMessage != nil })
            #expect(await service.sentTextBlocks == [["A"], ["A"]])
            #expect(session.pendingManualInputs.map(\.text) == ["B", "C"])
            if paused { session.stop() }
            #expect(session.canSkipFailedSubmission)
            session.skipFailedSubmissionAndResumeQueue()
            try #require(await pollUntil { session.activeTurnID != nil })
            #expect(session.errorMessage == nil)
            #expect(!session.canSkipFailedSubmission)
            #expect(await service.freshSessionStarts == [false, false, true])
            #expect(session.pendingManualInputs.map(\.text) == ["C"])
            await service.completeBlockedTurn()
            try #require(await pollUntil { await service.freshSessionStarts.count == 4 && session.activeTurnID != nil })
            #expect(await service.freshSessionStarts == [false, false, true, false])
            #expect(await service.sentTextBlocks == [["A"], ["A"], ["B"], ["C"]])
            session.stop()
            try #require(await pollUntil { !session.hasPendingGenerationWork })
        }

        @Test(arguments: [false, true], [false, true])
        func skippingFailedResetPreservesOnlyItsUncommittedBoundary(committed: Bool, editingNext: Bool) async throws {
            let service = TestCodexChatService(
                mode: .failThenComplete, commitsFreshSessionBeforeFailure: committed, delaysFreshSessionStart: true
            )
            let session = CodexChatSessionModel(
                backendThreadID: "thread-1", messages: [CodexChatMessage(role: .assistant, text: "Earlier answer")],
                service: service, settings: TestCodexChatFixtures.appSettings()
            )
            session.armFreshSession()
            session.draft = "B"
            session.sendDraft()
            try #require(await pollUntil { await service.isSendWaiting })
            session.draft = "C"
            session.sendDraft(mode: .queue)
            await service.resumeDelayedSend()
            try #require(await pollUntil { !session.isGenerating && session.errorMessage != nil })
            let next = try #require(session.pendingManualInputs.first)
            if editingNext { session.beginEditingPendingInput(id: next.id) }
            session.skipFailedSubmissionAndResumeQueue()
            if editingNext {
                #expect(!session.isGenerating)
                #expect(session.pendingManualInputs.first?.startsFreshSession == !committed)
                session.savePendingInput(id: next.id, draft: "C edited", images: [])
            }
            try #require(await pollUntil { await service.freshSessionStarts.count == 2 && !session.hasPendingGenerationWork })
            #expect(await service.freshSessionStarts == [true, !committed])
            #expect(await service.sentTextBlocks == [["B"], [editingNext ? "C edited" : "C"]])
            #expect(!session.startsFreshSession)
        }

        @Test
        func newInputsAfterFailedResetWaitForExplicitRecovery() async throws {
            let service = TestCodexChatService(mode: .failThenComplete)
            let session = CodexChatSessionModel(
                backendThreadID: "thread-1", messages: [CodexChatMessage(role: .assistant, text: "Earlier answer")],
                service: service, settings: TestCodexChatFixtures.appSettings()
            )
            session.armFreshSession()
            session.draft = "B"
            session.sendDraft()
            try #require(await pollUntil { !session.isGenerating && session.errorMessage != nil })
            session.draft = "C"
            session.sendDraft(mode: .queue)
            session.draft = "D"
            session.sendDraft(mode: .queue)
            #expect(session.pendingManualInputs.map(\.text) == ["C", "D"])
            #expect(await service.freshSessionStarts == [true])
            #expect(session.canSkipFailedSubmission)
            session.skipFailedSubmissionAndResumeQueue()
            try #require(await pollUntil { await service.freshSessionStarts.count == 3 && !session.hasPendingGenerationWork })
            #expect(await service.freshSessionStarts == [true, true, false])
            #expect(await service.sentTextBlocks == [["B"], ["C"], ["D"]])
        }

        @Test
        func skipWithoutAFailedSubmissionDoesNotClearAnUnrelatedError() async {
            let service = TestCodexChatService(mode: .complete)
            let session = CodexChatSessionModel(service: service, settings: TestCodexChatFixtures.appSettings())
            let input = CodexChatManualSubmission(text: "Queued", images: [])
            session.pendingManualInputs = [input]
            session.errorMessage = "Connection error"
            #expect(!session.canSkipFailedSubmission)
            session.skipFailedSubmissionAndResumeQueue()
            #expect(session.errorMessage == "Connection error")
            #expect(session.pendingManualInputs == [input])
            #expect(await service.sentTextBlocks.isEmpty)
        }

        @Test(arguments: [false, true])
        func stoppingQueuedResetRetainsOnlyUncommittedIntent(committed: Bool) async throws {
            let service = TestCodexChatService(
                mode: .blockBeforeOutput, commitsFreshSessionBeforeFailure: committed, delaysFreshSessionStart: true
            )
            let session = CodexChatSessionModel(service: service, settings: TestCodexChatFixtures.appSettings())
            session.draft = "Root"
            session.sendDraft()
            try #require(await pollUntil { session.activeTurnID != nil })
            session.armFreshSession()
            session.draft = "B"
            session.sendDraft(mode: .queue)
            await service.completeBlockedTurn()
            try #require(await pollUntil { await service.isSendWaiting })
            session.stop()
            await service.resumeDelayedSend()
            try #require(await pollUntil { !session.hasPendingGenerationWork })
            let queued = try #require(session.pendingManualInputs.first)
            #expect(queued.text == "B")
            #expect(queued.startsFreshSession == !committed)
            #expect(!session.startsFreshSession)
            session.resumeQueue()
            try #require(await pollUntil { session.activeTurnID != nil })
            #expect(await service.freshSessionStarts == [false, true, !committed])
            session.stop()
            try #require(await pollUntil { !session.hasPendingGenerationWork })
        }

        @Test
        func committedResetFailureRetriesWithoutAnotherReset() async throws {
            let service = TestCodexChatService(mode: .failThenComplete, commitsFreshSessionBeforeFailure: true)
            let session = CodexChatSessionModel(
                backendThreadID: "thread-1", messages: [CodexChatMessage(role: .assistant, text: "Earlier answer")],
                service: service, settings: TestCodexChatFixtures.appSettings()
            )
            session.armFreshSession()
            session.draft = "Fresh question"
            session.sendDraft()
            try #require(await pollUntil { !session.hasPendingGenerationWork })
            #expect(session.errorMessage != nil)
            #expect(!session.startsFreshSession)
            #expect(session.lastManualSubmission?.startsFreshSession == false)
            session.retry()
            try #require(await pollUntil { !session.hasPendingGenerationWork })
            #expect(await service.freshSessionStarts == [true, false])
        }

        @Test
        func retryOfAnEarlierSubmissionDoesNotConsumeLaterArming() async throws {
            let service = TestCodexChatService(mode: .failThenComplete)
            let session = CodexChatSessionModel(
                backendThreadID: "thread-1", messages: [CodexChatMessage(role: .assistant, text: "Earlier answer")],
                service: service, settings: TestCodexChatFixtures.appSettings()
            )
            session.draft = "A"
            session.sendDraft()
            try #require(await pollUntil { !session.hasPendingGenerationWork })
            session.armFreshSession()
            session.retry()
            try #require(await pollUntil { !session.hasPendingGenerationWork })
            #expect(await service.freshSessionStarts == [false, false])
            #expect(session.startsFreshSession)
            session.draft = "B"
            session.sendDraft()
            try #require(await pollUntil { !session.hasPendingGenerationWork })
            #expect(await service.freshSessionStarts == [false, false, true])
        }

        @Test(arguments: ["image", "meeting", "thread"])
        func typedClearPreservesAttachmentsForTheNextMessage(attachment: String) async {
            let service = ImageChatService(supportsImages: true)
            let session = CodexChatSessionModel(
                backendThreadID: "thread-1", messages: [CodexChatMessage(role: .assistant, text: "Earlier answer")],
                service: service, settings: TestCodexChatFixtures.appSettings()
            )
            await session.prepare()
            switch attachment {
            case "image": session.attachedImages = [CodexChatImageAttachment(data: Data([1]), mimeType: "image/png")]
            case "meeting": session.selectedMeetingReferenceIDs = [.v7()]
            default: session.selectedThreadReferences = [CodexChatThreadSummary(id: "reference", title: "Reference", updatedAt: .now)]
            }
            let images = session.attachedImages
            let meetings = session.selectedMeetingReferenceIDs
            let threads = session.selectedThreadReferences
            session.draft = "/clear"
            session.sendDraft()
            #expect(session.startsFreshSession && session.draft.isEmpty)
            #expect(!session.isGenerating)
            #expect(session.attachedImages == images)
            #expect(session.selectedMeetingReferenceIDs == meetings)
            #expect(session.selectedThreadReferences == threads)
            #expect(await service.sentInputs.isEmpty)
        }

        @Test
        func clearArmedDuringPreparationBelongsToTheNextSubmission() async throws {
            let service = TestCodexChatService(mode: .complete)
            let settings = TestCodexChatFixtures.appSettings()
            settings.currentWorkspace = WorkspaceRecord(
                id: .v7(), path: "/tmp/chat-fresh-session-tests", name: "Fresh session tests",
                createdAt: .now, lastOpenedAt: .now
            )
            let contextProvider = TestCodexChatContextProvider(shouldBlock: true)
            let session = CodexChatSessionModel(
                backendThreadID: "thread-1", messages: [CodexChatMessage(role: .assistant, text: "Earlier answer")],
                service: service, settings: settings, contextProvider: contextProvider
            )
            session.draft = "Already submitted"
            session.sendDraft()
            try #require(await pollUntil { contextProvider.requestCount == 1 })
            session.armFreshSession()
            contextProvider.resume()
            try #require(await pollUntil { !session.hasPendingGenerationWork })
            #expect(await service.freshSessionStarts == [false])
            #expect(session.startsFreshSession)

            session.draft = "Next submission"
            session.sendDraft()
            try #require(await pollUntil { !session.hasPendingGenerationWork })
            #expect(await service.freshSessionStarts == [false, true])
            #expect(!session.startsFreshSession)
        }

        @Test(arguments: [false, true])
        func failedOrCancelledPreparationRestoresFreshSessionIntent(cancel: Bool) async throws {
            let service = TestCodexChatService(mode: .complete)
            let settings = TestCodexChatFixtures.appSettings()
            settings.currentWorkspace = WorkspaceRecord(
                id: .v7(), path: "/tmp/chat-fresh-session-tests", name: "Fresh session tests",
                createdAt: .now, lastOpenedAt: .now
            )
            let contextProvider = TestCodexChatContextProvider(shouldBlock: true)
            let session = CodexChatSessionModel(
                backendThreadID: "thread-1", messages: [CodexChatMessage(role: .assistant, text: "Earlier answer")],
                service: service, settings: settings, contextProvider: contextProvider
            )
            session.armFreshSession()
            session.draft = "Fresh question"
            session.sendDraft()
            #expect(!session.startsFreshSession)
            #expect(session.preparingUserMessage?.startsFreshSession == true)
            try #require(await pollUntil { contextProvider.requestCount == 1 })
            if cancel {
                session.stop()
            } else {
                contextProvider.error = .invalidProtocolResponse
            }
            contextProvider.resume()
            try #require(await pollUntil { !session.hasPendingGenerationWork })
            #expect(session.startsFreshSession == cancel)
            if !cancel { #expect(session.lastManualSubmission?.startsFreshSession == true) }
            #expect(await service.freshSessionStarts.isEmpty)

            contextProvider.error = nil
            if cancel {
                session.sendDraft()
            } else {
                session.retry()
            }
            try #require(await pollUntil { !session.hasPendingGenerationWork })
            #expect(await service.freshSessionStarts == [true])
            #expect(!session.startsFreshSession)
        }

        @Test
        func cancellingAnAcceptedFreshTurnDoesNotRearmIt() async throws {
            let service = TestCodexChatService(mode: .delayTurnHandleIgnoringCancellation)
            let session = CodexChatSessionModel(
                backendThreadID: "thread-1", messages: [CodexChatMessage(role: .assistant, text: "Earlier answer")],
                service: service, settings: TestCodexChatFixtures.appSettings()
            )
            session.armFreshSession()
            session.draft = "Fresh question"
            session.sendDraft()
            try #require(await pollUntil { await service.isSendWaiting })
            session.stop()
            await service.resumeDelayedSend()
            try #require(await pollUntil { !session.hasPendingGenerationWork })
            #expect(await service.freshSessionStarts == [true])
            #expect(!session.startsFreshSession)
        }

        @Test
        func clearArmsTheNextTurnWithoutReachingPiAndCanBeUndone() async throws {
            let service = TestCodexChatService(mode: .complete)
            let session = CodexChatSessionModel(service: service, settings: TestCodexChatFixtures.appSettings())
            #expect(!session.canStartFreshSession)
            session.draft = "Hello"
            session.sendDraft()
            try #require(await pollUntil { !session.hasPendingGenerationWork && session.canStartFreshSession })
            #expect(try await session.slashCommands().first?.name == "clear")

            session.draft = "/clear"
            session.sendDraft()
            #expect(session.startsFreshSession && session.draft.isEmpty)
            session.startsFreshSession = false
            // Choosing the suggestion arms it from the partial query, with nothing to send.
            session.draft = "/cle"
            session.armFreshSession()
            #expect(session.startsFreshSession && session.draft.isEmpty)
            #expect(await service.sentTextBlocks.count == 1)

            session.draft = "Next"
            session.sendDraft()
            try #require(await pollUntil { await service.freshSessionStarts.count == 2 && !session.hasPendingGenerationWork })
            #expect(await service.freshSessionStarts == [false, true])
            #expect(!session.startsFreshSession)
            #expect(session.messages.filter { $0.role == .user }.map(\.startsFreshSession) == [false, true])
        }

        @Test
        func anArmedClearHoldsSteersForTheNewSession() async throws {
            let settings = TestCodexChatFixtures.appSettings()
            settings.chatDeliveryMode = .steer
            let service = TestCodexChatService(mode: .blockBeforeOutput)
            let session = CodexChatSessionModel(service: service, settings: settings)
            session.draft = "Start"
            session.sendDraft()
            try #require(await pollUntil { session.activeTurnID != nil })
            session.draft = "/clear"
            session.sendDraft()
            session.draft = "Follow-up"
            session.sendDraft()
            #expect(session.pendingManualInputs.map(\.text) == ["Follow-up"])
            await service.completeBlockedTurn()
            try #require(await pollUntil { await service.freshSessionStarts.count == 2 })
            #expect(await service.steeredTextBlocks.isEmpty)
            #expect(await service.freshSessionStarts == [false, true])
            session.stop()
            try #require(await pollUntil { !session.hasPendingGenerationWork })
        }

        @Test
        func savedClearMarksTheMessageAndEndsTheEarlierRepliesResume() throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let store = ChatThreadStore(dbQueue: database.dbQueue)
            let record = ChatThreadRecord(
                id: UUID.v7().uuidString.lowercased(), accountID: "local", title: "", model: nil, reasoningEffort: "medium",
                createdAt: .now, updatedAt: .now
            )
            try store.createThread(record, items: [
                ChatHistoryCodec.user([.text("Before")]),
                ChatHistoryCodec.message(["role": .string("assistant"), "content": .string("Answer")]),
            ])
            #expect(try store.hasAssistantReply(threadID: record.id))

            try store.appendItems(threadID: record.id, items: [ChatHistoryCodec.user([.text("After")], startsFreshSession: true)])
            #expect(try !store.hasAssistantReply(threadID: record.id))
            let messages = try store.messagePage(threadID: record.id).messages
            #expect(messages.map(\.startsFreshSession) == [false, false, true])

            try store.appendItems(threadID: record.id, items: [
                ChatHistoryCodec.message(["role": .string("assistant"), "content": .string("Fresh answer")]),
            ])
            #expect(try store.hasAssistantReply(threadID: record.id))
        }
    }

    struct PiChatFreshSessionTests {
        private struct Fixture {
            let pi: TestPiRuntime
            let log: TestPiTransportLog
            let store: ChatThreadStore
            let chat: PiChatService
            let threadID: String
            let sessions: URL

            func reopenedChat() -> PiChatService {
                PiChatService(
                    runtime: pi.service, historyStore: store,
                    workingDirectory: PiWorkingDirectory(override: pi.rootURL.appending(path: "work")),
                    agentLocator: PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL),
                    mcpExecutableURL: URL(filePath: "/usr/bin/true"),
                    mcpSettings: { AgentMCPSettings() }, fileAccessSettings: { PiFileAccessSettings() }
                )
            }

            func turn(_ text: String, fresh: Bool = false) async throws {
                let handle = try await chat.beginTurn(
                    threadID: threadID, inputs: [.text(text)], model: nil, effort: "medium",
                    approvalMethod: .autoReview, startsFreshSession: fresh
                )
                for try await _ in handle.events {}
            }
        }

        private static func fixture(rejectSecondProcess: Bool = false) async throws -> Fixture {
            let log = TestPiTransportLog()
            let pi = TestPiRuntime { options in
                let processIndex = log.all.count
                let transport = options.mode == .chat
                    ? TestPiTransport { command in
                        guard let id = command["id"] else { return [] }
                        let started = TestPiTransport.response(id: id, data: .object(["disposition": .string("started")]))
                        if command["type"]?.stringValue == "prompt" {
                            if rejectSecondProcess, processIndex == 1 {
                                return [.object([
                                    "type": .string("response"), "id": id, "success": .bool(false), "error": .string("Rejected"),
                                ])]
                            }
                            if command["message"]?.stringValue == "active" { return [started] }
                        }
                        return command["type"]?.stringValue == "prompt"
                            ? [started, TestPiTransport.assistantEnd("answer"), TestPiTransport.settled()] : [started]
                    }
                    : TestPiTransport(reply: TestPiRuntime.modelsReply([TestPiTransport.model(provider: "own.cloud.databricks.com", id: "gpt-test")]))
                if options.mode == .chat { log.append(transport) }
                return transport
            }
            let store = try ChatThreadStore(dbQueue: AppDatabaseManager(path: ":memory:").dbQueue)
            let chat = PiChatService(
                runtime: pi.service,
                historyStore: store,
                workingDirectory: PiWorkingDirectory(override: pi.rootURL.appending(path: "work")),
                agentLocator: PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL),
                mcpExecutableURL: URL(filePath: "/usr/bin/true"),
                mcpSettings: { AgentMCPSettings() },
                fileAccessSettings: { PiFileAccessSettings() }
            )
            let thread = try await chat.startThread(model: nil, effort: "medium")
            _ = await chat.acquireThreadLease(threadID: thread.id)
            let sessions = try PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL).sessionsURL()
            return Fixture(pi: pi, log: log, store: store, chat: chat, threadID: thread.id, sessions: sessions)
        }

        @Test(.providerAccounts([.init(id: UUID(), workspaceURL: URL(string: "https://own.cloud.databricks.com")!)]))
        func rejectedResetNeverInterruptsAnotherActiveRun() async throws {
            let fixture = try await Self.fixture()
            try await fixture.turn("before")
            let handle = try await fixture.chat.beginTurn(
                threadID: fixture.threadID, inputs: [.text("active")], model: nil, effort: "medium", approvalMethod: .autoReview
            )
            let transport = try #require(fixture.log.all.last)
            await #expect(throws: (any Error).self) { try await fixture.turn("reset", fresh: true) }
            #expect(await !transport.isClosed)
            #expect(try fixture.store.run(id: handle.id)?.status == "running")
            await transport.emit(TestPiTransport.assistantEnd("still running"))
            await transport.emit(TestPiTransport.settled())
            for try await _ in handle.events {}
            #expect(try fixture.store.run(id: handle.id)?.status == "completed")
        }

        @Test(.providerAccounts([.init(id: UUID(), workspaceURL: URL(string: "https://own.cloud.databricks.com")!)]))
        func committedPromptRejectionReportsResetAcceptanceAndRetryKeepsOneBoundary() async throws {
            let fixture = try await Self.fixture(rejectSecondProcess: true)
            try await fixture.turn("before")
            await #expect(throws: CodexChatFreshSessionCommittedError.self) { try await fixture.turn("reset", fresh: true) }
            let sequence = try fixture.store.freshSessionSequence(threadID: fixture.threadID)
            #expect(sequence >= 0)
            try await fixture.turn("retry")
            #expect(try fixture.store.freshSessionSequence(threadID: fixture.threadID) == sequence)
        }

        @Test(
            .providerAccounts([.init(id: UUID(), workspaceURL: URL(string: "https://own.cloud.databricks.com")!)]),
            arguments: [false, true],
            [false, true]
        )
        func reopenRecoversPendingFileAccordingToTheDurableResetBoundary(committed: Bool, hasProvisionalFile: Bool) async throws {
            let fixture = try await Self.fixture()
            try await fixture.turn("before")
            await fixture.chat.unsubscribe(threadID: fixture.threadID)
            let file = try #require(PiChatSessionFiles.file(id: fixture.threadID, in: fixture.sessions))
            let original = try Data(contentsOf: file)
            let previous = try fixture.store.freshSessionSequence(threadID: fixture.threadID)
            let pending = file.appendingPathExtension("clearing.\(previous)")
            try FileManager.default.moveItem(at: file, to: pending)
            // Startup may already have created a provisional session under the same thread ID.
            let provisional = fixture.sessions.appendingPathComponent("provisional_\(fixture.threadID).jsonl")
            if hasProvisionalFile { try Data("provisional".utf8).write(to: provisional) }
            if committed {
                try fixture.store.appendItems(threadID: fixture.threadID, items: [ChatHistoryCodec.user([.text("reset")], startsFreshSession: true)])
            }
            let reopened = fixture.reopenedChat()
            if committed, !hasProvisionalFile {
                await #expect(throws: (any Error).self) { try await reopened.sessionFile(id: fixture.threadID) }
            } else {
                let resumedFile = try await reopened.sessionFile(id: fixture.threadID)
                #expect(resumedFile.resolvingSymlinksInPath() == (committed ? provisional : file).resolvingSymlinksInPath())
            }
            #expect(!FileManager.default.fileExists(atPath: pending.path))
            let saved = committed ? file.appendingPathExtension("\(previous).cleared") : file
            #expect(try Data(contentsOf: saved) == original)
        }

        @Test(.providerAccounts([.init(id: UUID(), workspaceURL: URL(string: "https://own.cloud.databricks.com")!)]))
        func freshTurnMovesTheSessionFileAsideAndStartsPiUnderTheSameThread() async throws {
            let fixture = try await Self.fixture()
            try await fixture.turn("before")
            let file = try #require(PiChatSessionFiles.file(id: fixture.threadID, in: fixture.sessions))

            try await fixture.turn("after", fresh: true)
            #expect(FileManager.default.fileExists(atPath: file.appendingPathExtension("-1.cleared").path))
            #expect(fixture.log.all.count == 2)
            let reopened = try #require(fixture.pi.launches.all.last { $0.mode == .chat })
            #expect(reopened.arguments.contains("--session-id") && !reopened.arguments.contains("--session"))
            let users = try fixture.store.messagePage(threadID: fixture.threadID).messages.filter { $0.role == .user }
            #expect(users.map(\.startsFreshSession) == [false, true])

            try await fixture.turn("again")
            #expect(fixture.log.all.count == 2)
            try await fixture.turn("another reset", fresh: true)
            #expect(fixture.log.all.count == 3)
            #expect(try fixture.store.messagePage(threadID: fixture.threadID).messages.filter(\.startsFreshSession).count == 2)
        }

        @Test(.providerAccounts([.init(id: UUID(), workspaceURL: URL(string: "https://own.cloud.databricks.com")!)]))
        func freshTurnThatNeverStartsKeepsTheEarlierSession() async throws {
            let fixture = try await Self.fixture()
            try await fixture.turn("before")
            let file = try #require(PiChatSessionFiles.file(id: fixture.threadID, in: fixture.sessions))
            // A read-only thread fails after the file moved, before the `/clear` message is saved.
            try await fixture.store.dbQueue.write { db in
                try db.execute(sql: "UPDATE chat_threads SET scheduleID = 'schedule' WHERE id = ?", arguments: [fixture.threadID])
            }
            await #expect(throws: (any Error).self) { try await fixture.turn("after", fresh: true) }
            #expect(PiChatSessionFiles.file(id: fixture.threadID, in: fixture.sessions) == file)
            #expect(!FileManager.default.fileExists(atPath: file.appendingPathExtension("-1.cleared").path))
            #expect(try fixture.store.hasAssistantReply(threadID: fixture.threadID))
        }
    }
#endif
