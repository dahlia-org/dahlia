#if canImport(Testing)
    import DahliaRuntimeSupport
    import Foundation
    import Testing
    @testable import Dahlia

    @MainActor
    struct CodexChatFreshSessionTests {
        @Test(arguments: ["image", "meeting", "thread"])
        func typedClearPreservesAttachmentsForTheNextMessage(attachment: String) async throws {
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
            #expect(session.startsFreshSession)
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

            func turn(_ text: String, fresh: Bool = false) async throws {
                let handle = try await chat.beginTurn(
                    threadID: threadID, inputs: [.text(text)], model: nil, effort: "medium",
                    approvalMethod: .autoReview, startsFreshSession: fresh
                )
                for try await _ in handle.events {}
            }
        }

        private static func fixture() async throws -> Fixture {
            let log = TestPiTransportLog()
            let pi = TestPiRuntime { options in
                let transport = options.mode == .chat
                    ? TestPiTransport { command in
                        guard let id = command["id"] else { return [] }
                        let started = TestPiTransport.response(id: id, data: .object(["disposition": .string("started")]))
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
        func freshTurnMovesTheSessionFileAsideAndStartsPiUnderTheSameThread() async throws {
            let fixture = try await Self.fixture()
            try await fixture.turn("before")
            let file = try #require(PiChatSessionFiles.file(id: fixture.threadID, in: fixture.sessions))

            try await fixture.turn("after", fresh: true)
            #expect(FileManager.default.fileExists(atPath: file.appendingPathExtension("cleared").path))
            #expect(fixture.log.all.count == 2)
            let reopened = try #require(fixture.pi.launches.all.last { $0.mode == .chat })
            #expect(reopened.arguments.contains("--session-id") && !reopened.arguments.contains("--session"))
            let users = try fixture.store.messagePage(threadID: fixture.threadID).messages.filter { $0.role == .user }
            #expect(users.map(\.startsFreshSession) == [false, true])

            try await fixture.turn("again")
            #expect(fixture.log.all.count == 2)
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
            #expect(!FileManager.default.fileExists(atPath: file.appendingPathExtension("cleared").path))
            #expect(try fixture.store.hasAssistantReply(threadID: fixture.threadID))
        }
    }
#endif
