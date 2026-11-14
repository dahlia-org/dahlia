#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    @MainActor
    struct CodexChatHistoryPagingTests {
        @Test
        func earlierHistoryIsLoadedOnlyOnRequestAndErrorsKeepTheCursorForRetry() async {
            let older = CodexChatMessage(id: "older", role: .user, text: "Older question")
            let service = TestCodexChatService(
                mode: .complete,
                earlierPages: ["older": .init(messages: [older], earlierCursor: "oldest")],
                initialEarlierCursor: "older"
            )
            let session = session(service: service)
            await session.restore()
            #expect(session.messages.count == 2)
            #expect(session.earlierMessagesCursor == "older")
            #expect(await service.earlierRequests.isEmpty)
            let latest = session.messages
            await session.loadEarlierMessages()
            #expect(session.messages == [older] + latest)
            #expect(session.earlierMessagesCursor == "oldest")
            #expect(!session.isLoadingEarlierMessages)
            await session.loadEarlierMessages()
            #expect(session.earlierMessagesError != nil)
            #expect(session.messages == [older] + latest)
            #expect(session.earlierMessagesCursor == "oldest")
            #expect(await service.earlierRequests == ["older", "oldest"])
            session.release()
        }

        @Test(arguments: [false, true])
        func obsoleteOrCancelledPagesCannotMutateTheConversation(release: Bool) async {
            let service = TestCodexChatService(
                mode: .complete,
                earlierPages: ["older": .init(
                    messages: [CodexChatMessage(role: .user, text: "Old")],
                    earlierCursor: nil
                )],
                initialEarlierCursor: "older",
                delaysEarlierMessages: true
            )
            let session = session(service: service)
            await session.restore()
            let latest = session.messages
            let loading = Task { await session.loadEarlierMessages() }
            #expect(await pollUntil { await service.isEarlierWaiting })
            #expect(session.isLoadingEarlierMessages)
            // A second click must not launch the same request twice.
            await session.loadEarlierMessages()
            #expect(await service.earlierRequests == ["older"])
            if release { session.release() } else { loading.cancel() }
            await service.completeEarlierLoad()
            await loading.value
            #expect(session.messages == latest)
            #expect(session.earlierMessagesCursor == "older")
            #expect(!session.isLoadingEarlierMessages)
            session.release()
        }

        @Test
        func anEarlierPageCanBeSelectedAfterPrependingAndReturnsToLatest() {
            var window = CodexChatConversationWindow()
            let messages = (0 ..< 80).map { CodexChatMessage(role: $0.isMultiple(of: 2) ? .user : .assistant, text: String($0)) }
            let ranges = CodexChatConversationWindow.pageRanges(in: messages)
            window.showEarliestMessages()
            #expect(window.visibleRange(in: ranges) == 0 ..< 40)
            window.showLaterMessages(in: ranges)
            #expect(window.visibleRange(in: ranges) == 40 ..< 80)
        }

        private func session(service: TestCodexChatService) -> CodexChatSessionModel {
            let settings = AppSettings()
            settings.currentWorkspace = WorkspaceRecord(id: .v7(), path: nil, name: "History", createdAt: .now, lastOpenedAt: .now)
            return CodexChatSessionModel(backendThreadID: "thread", service: service, settings: settings)
        }
    }
#endif
