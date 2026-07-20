import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CodexChatSessionModelTests {
        @Test
        func liveTranscriptIsSentWithoutAddingAUserMessageAndManualChatStaysVisible() async {
            let service = TestCodexChatService(mode: .staleRollout)
            let settings = AppSettings()
            settings.currentVault = Self.testVault()
            let session = CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings
            )

            session.toggleLiveMode()
            session.receiveFinalizedLiveTranscript("Finalized speech")
            await waitUntil { !session.isGenerating }

            #expect(session.messages.allSatisfy { $0.role == .assistant })
            #expect(await service.sentTextBlocks == [
                [
                    TestCodexChatFixtures.liveTranscriptContext,
                    "<live_transcript source=\"dahlia\">Finalized speech</live_transcript>",
                ],
            ])
            #expect(await service.threadNames == [L10n.chatLiveMode])

            session.receiveFinalizedLiveTranscript("More finalized speech")
            await waitUntil { !session.isGenerating }

            #expect(await service.sentTextBlocks.last == [
                "<live_transcript source=\"dahlia\">More finalized speech</live_transcript>",
            ])

            session.draft = "A visible question"
            session.sendDraft()
            await waitUntil { !session.isGenerating }

            #expect(session.messages.filter { $0.role == .user }.map(\.text) == ["A visible question"])
            #expect(await service.sentTextBlocks.last == ["A visible question"])
            #expect(session.title == "A visible question")
            #expect(await service.threadNames == [L10n.chatLiveMode, "A visible question"])
        }

        @Test
        func firstSendCreatesThreadAndStreamsThenReconcilesRollout() async {
            let service = TestCodexChatService(mode: .complete)
            let settings = AppSettings()
            let oldModel = settings.codexChatModelID
            let oldEffort = settings.codexChatReasoningEffort
            settings.currentVault = Self.testVault()
            defer {
                settings.codexChatModelID = oldModel
                settings.codexChatReasoningEffort = oldEffort
            }
            let session = CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings
            )

            #expect(session.backendThreadID == nil)
            session.draft = "Question"
            session.sendDraft()
            await waitUntil { !session.isGenerating }

            #expect(session.backendThreadID == "thread-1")
            #expect(session.messages.map(\.text) == ["Question", "Final answer"])
            #expect(session.messages.last?.reasoning == "Considered the question")
            #expect(session.title == "Question")
            #expect(await service.sentTextBlocks == [["Question"]])
            #expect(await service.threadNames == ["Question"])
        }

        @Test
        func sendDraftSerializesMultipleMeetingReferencesBeforeInstruction() async {
            let service = TestCodexChatService(mode: .complete)
            let settings = AppSettings()
            let vault = Self.testVault()
            settings.currentVault = vault
            let session = CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings
            )
            let first = Self.meetingReference(vaultID: vault.id, name: "First", offset: -60)
            let second = Self.meetingReference(vaultID: vault.id, name: "Second", offset: 0)
            session.updateAvailableMeetings([first, second], catalogVaultID: vault.id)
            session.addMeetingReference(CodexChatMeetingReference(meeting: first))
            session.addMeetingReference(CodexChatMeetingReference(meeting: second))
            session.addMeetingReference(CodexChatMeetingReference(meeting: first))
            session.draft = "Compare them"

            session.sendDraft()
            await waitUntil { !session.isGenerating }

            let expected = "meeting:\(first.meetingId.uuidString.lowercased()) "
                + "meeting:\(second.meetingId.uuidString.lowercased()) Compare them"
            #expect(await service.sentTextBlocks == [[expected]])
            #expect(session.selectedMeetingReferenceIDs.isEmpty)
            #expect(session.draft.isEmpty)
            #expect(session.displayText(expected) == "First Second Compare them")

            session.retry()
            await waitUntil { !session.isGenerating }
            #expect(await service.sentTextBlocks == [[expected], [expected]])
        }

        @Test
        func meetingReferenceCanBeSentWithoutInstruction() async {
            let service = TestCodexChatService(mode: .complete)
            let settings = AppSettings()
            let vault = Self.testVault()
            settings.currentVault = vault
            let session = CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings
            )
            let meeting = Self.meetingReference(vaultID: vault.id, name: "Reference Only", offset: 0)
            session.updateAvailableMeetings([meeting], catalogVaultID: vault.id)
            session.addMeetingReference(CodexChatMeetingReference(meeting: meeting))

            #expect(session.canSend)
            session.sendDraft()
            await waitUntil { !session.isGenerating }

            #expect(await service.sentTextBlocks == [["meeting:\(meeting.meetingId.uuidString.lowercased())"]])
        }

        @Test
        func meetingCatalogUpdatesNamesAndPrunesDeletedDraftReferences() {
            let settings = AppSettings()
            let vault = Self.testVault()
            settings.currentVault = vault
            let session = CodexChatSessionModel(
                service: TestCodexChatService(mode: .complete),
                settings: settings
            )
            var meeting = Self.meetingReference(vaultID: vault.id, name: "Original", offset: 0)
            session.updateAvailableMeetings([meeting], catalogVaultID: vault.id)
            session.addMeetingReference(CodexChatMeetingReference(meeting: meeting))
            meeting.meetingName = "Renamed"
            session.updateAvailableMeetings([meeting], catalogVaultID: vault.id)

            #expect(session.meetingDisplayName(for: meeting.meetingId) == "Renamed")
            session.updateAvailableMeetings([], catalogVaultID: vault.id)
            #expect(session.selectedMeetingReferenceIDs.isEmpty)
            #expect(session.meetingDisplayName(for: meeting.meetingId) == "Renamed")
        }

        @Test
        func anotherVaultCatalogDoesNotPruneDetachedSessionReferences() {
            let settings = AppSettings()
            let vault = Self.testVault()
            settings.currentVault = vault
            let session = CodexChatSessionModel(
                vaultID: vault.id,
                service: TestCodexChatService(mode: .complete),
                settings: settings
            )
            let meeting = Self.meetingReference(vaultID: vault.id, name: "Original", offset: 0)
            session.updateAvailableMeetings([meeting], catalogVaultID: vault.id)
            session.addMeetingReference(CodexChatMeetingReference(meeting: meeting))

            let otherVault = Self.testVault()
            session.updateAvailableMeetings([], catalogVaultID: otherVault.id)

            #expect(session.selectedMeetingReferenceIDs == [meeting.meetingId])
            #expect(session.meetingDisplayName(for: meeting.meetingId) == "Original")

            session.updateAvailableMeetings([], catalogVaultID: vault.id)
            #expect(session.selectedMeetingReferenceIDs.isEmpty)
        }

        @Test
        func loadingSameVaultCatalogDoesNotPruneReferences() {
            let settings = AppSettings()
            let vault = Self.testVault()
            settings.currentVault = vault
            let session = CodexChatSessionModel(
                vaultID: vault.id,
                service: TestCodexChatService(mode: .complete),
                settings: settings
            )
            let meeting = Self.meetingReference(vaultID: vault.id, name: "Original", offset: 0)
            session.updateAvailableMeetings([meeting], catalogVaultID: vault.id)
            session.addMeetingReference(CodexChatMeetingReference(meeting: meeting))

            session.updateAvailableMeetings(
                [],
                catalogVaultID: vault.id,
                isCatalogLoaded: false
            )
            #expect(session.selectedMeetingReferenceIDs == [meeting.meetingId])

            session.updateAvailableMeetings([meeting], catalogVaultID: vault.id)
            #expect(session.selectedMeetingReferenceIDs == [meeting.meetingId])
        }

        @Test
        func missingVaultCatalogDoesNotPruneReferences() {
            let settings = AppSettings()
            settings.currentVault = nil
            let session = CodexChatSessionModel(
                service: TestCodexChatService(mode: .complete),
                settings: settings
            )
            let reference = CodexChatMeetingReference(id: .v7(), name: "Cached", createdAt: .now)
            session.addMeetingReference(reference)

            session.updateAvailableMeetings([], catalogVaultID: nil)

            #expect(session.selectedMeetingReferenceIDs == [reference.id])
        }

        @Test
        func restoredRawReferencesUseCachedNamesAcrossTitleAndMessages() {
            let settings = AppSettings()
            let vault = Self.testVault()
            settings.currentVault = vault
            let meeting = Self.meetingReference(vaultID: vault.id, name: "Weekly Sync", offset: 0)
            let token = "meeting:\(meeting.meetingId.uuidString)"
            let session = CodexChatSessionModel(
                vaultID: vault.id,
                title: "\(token) Review",
                messages: [CodexChatMessage(role: .user, text: "Use (\(token)).")],
                service: TestCodexChatService(mode: .complete),
                settings: settings
            )

            session.updateAvailableMeetings([meeting], catalogVaultID: vault.id)

            #expect(session.displayTitle == "Weekly Sync Review")
            #expect(session.displayText(session.messages[0].text) == "Use (Weekly Sync).")
        }

        @Test
        func stopKeepsPartialResponse() async {
            let service = TestCodexChatService(mode: .block)
            let settings = AppSettings()
            settings.currentVault = Self.testVault()
            let session = CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings
            )
            session.draft = "Question"
            session.sendDraft()
            await waitUntil { session.messages.last?.text == "Partial" }

            session.stop()
            await waitUntil { !session.isGenerating }
            await waitUntilAsync { await service.interruptCount == 1 }

            #expect(session.messages.last?.text == "Partial")
            #expect(session.messages.last?.isStreaming == false)
            #expect(await service.interruptCount == 1)
        }

        @Test
        func staleRolloutDoesNotReplaceCompletedStream() async {
            let service = TestCodexChatService(mode: .staleRollout)
            let settings = AppSettings()
            settings.currentVault = Self.testVault()
            let session = CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings
            )

            session.draft = "Question"
            session.sendDraft()
            await waitUntil { !session.isGenerating }

            #expect(session.messages.map(\.text) == ["Question", "Final answer"])
        }

        @Test
        func rolloutWithoutReasoningPreservesStreamedSummary() async {
            let service = TestCodexChatService(mode: .rolloutWithoutReasoning)
            let settings = AppSettings()
            settings.currentVault = Self.testVault()
            let session = CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings
            )

            session.draft = "Question"
            session.sendDraft()
            await waitUntil { !session.isGenerating }

            #expect(session.messages.last?.text == "Final answer")
            #expect(session.messages.last?.reasoning == "Considered the question")
        }

        @Test
        func multipleAgentMessageItemsAreCombinedIntoOneResponse() async {
            let service = TestCodexChatService(mode: .multipleMessages)
            let settings = AppSettings()
            settings.currentVault = Self.testVault()
            let session = CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings
            )

            session.draft = "Question"
            session.sendDraft()
            await waitUntil { !session.isGenerating }

            #expect(session.messages.map(\.text) == ["Question", "First answer\n\nSecond answer"])
            #expect(session.messages.allSatisfy { !$0.isStreaming })
        }

        @Test
        func releasedGeneratingSessionInterruptsAndUnsubscribes() async {
            let service = TestCodexChatService(mode: .block)
            let settings = AppSettings()
            settings.currentVault = Self.testVault()
            let session = CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings
            )
            session.draft = "Question"
            session.sendDraft()
            await waitUntil { session.activeTurnID != nil }

            session.release()
            await waitUntil { !session.isGenerating }
            await waitUntilAsync { await service.interruptCount == 1 }
            await waitUntilAsync { await service.unsubscribeCount == 1 }

            #expect(await service.unsubscribedThreadIDs == ["thread-1"])
        }

        @Test
        func sessionCannotSendWhileAnotherVaultIsSelected() {
            let settings = AppSettings()
            let boundVault = Self.testVault()
            settings.currentVault = boundVault
            let session = CodexChatSessionModel(
                vaultID: boundVault.id,
                service: TestCodexChatService(mode: .complete),
                settings: settings
            )
            settings.currentVault = Self.testVault()

            session.draft = "Do not send"
            #expect(!session.canSend)
            session.sendDraft()
            #expect(session.messages.isEmpty)
        }

        @Test
        func everyTurnUsesLatestContextWithoutExposingPromptMarkup() async throws {
            let service = TestCodexChatService(mode: .staleRollout)
            let settings = AppSettings()
            let vault = Self.testVault()
            settings.currentVault = vault
            let firstContext = try CodexChatContext.meeting(
                id: #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")),
                name: "First",
                calendarEvent: nil
            )
            let secondContext = try CodexChatContext.meeting(
                id: #require(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")),
                name: "Second",
                calendarEvent: nil
            )
            let contextProvider = TestCodexChatContextProvider(context: firstContext)
            let session = CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings,
                contextProvider: contextProvider
            )

            session.draft = "First question"
            session.sendDraft()
            await waitUntil { !session.isGenerating }
            contextProvider.context = secondContext
            session.draft = "Second question"
            session.sendDraft()
            await waitUntil { !session.isGenerating }

            #expect(await service.sentTextBlocks == [
                CodexChatPromptCodec.encodeTextBlocks(text: "First question", context: firstContext),
                CodexChatPromptCodec.encodeTextBlocks(text: "Second question", context: secondContext),
            ])
            #expect(session.messages.filter { $0.role == .user }.map(\.text) == [
                "First question", "Second question",
            ])
            #expect(session.messages.filter { $0.role == .user }.map(\.context) == [
                firstContext, secondContext,
            ])
            #expect(await service.threadNames == ["First question"])
        }

        @Test
        func contextFailureKeepsDraftAndDoesNotSend() async {
            let service = TestCodexChatService(mode: .complete)
            let settings = AppSettings()
            settings.currentVault = Self.testVault()
            let contextProvider = TestCodexChatContextProvider(
                error: CodexAppServerError.invalidProtocolResponse
            )
            let session = CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings,
                contextProvider: contextProvider
            )
            session.draft = "Keep this"

            session.sendDraft()
            await waitUntil { !session.isGenerating }

            #expect(session.draft == "Keep this")
            #expect(session.messages.isEmpty)
            #expect(session.errorMessage != nil)
            #expect(session.lastSubmittedText == "Keep this")
            #expect(await service.sentTextBlocks.isEmpty)
        }

        @Test
        func contextFailureReplacesStaleRetryAndSuccessfulRetryClearsDraft() async {
            let service = TestCodexChatService(mode: .staleRollout)
            let settings = AppSettings()
            settings.currentVault = Self.testVault()
            let contextProvider = TestCodexChatContextProvider()
            let session = CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings,
                contextProvider: contextProvider
            )
            session.draft = "Previous question"
            session.sendDraft()
            await waitUntil { !session.isGenerating }

            contextProvider.error = CodexAppServerError.invalidProtocolResponse
            session.draft = "Current question"
            session.sendDraft()
            await waitUntil { !session.isGenerating }

            #expect(session.lastSubmittedText == "Current question")
            #expect(session.draft == "Current question")
            #expect(await service.sentTextBlocks == [["Previous question"]])

            contextProvider.error = nil
            session.retry()
            await waitUntil { !session.isGenerating }

            #expect(session.draft.isEmpty)
            #expect(await service.sentTextBlocks == [["Previous question"], ["Current question"]])
        }

        @Test
        func unavailableSelectedMeetingKeepsDraftAndDoesNotSend() async {
            let service = TestCodexChatService(mode: .complete)
            let settings = AppSettings()
            let vault = Self.testVault()
            settings.currentVault = vault
            let contextProvider = CodexChatContextProvider()
            contextProvider.update(
                vaultID: vault.id,
                meetingID: UUID.v7(),
                draftMeeting: nil,
                dbQueue: nil
            )
            let session = CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings,
                contextProvider: contextProvider
            )
            session.draft = "Keep selected meeting question"

            session.sendDraft()
            await waitUntil { !session.isGenerating }

            #expect(session.draft == "Keep selected meeting question")
            #expect(session.messages.isEmpty)
            #expect(session.errorMessage == L10n.chatSelectedMeetingUnavailable)
            #expect(await service.sentTextBlocks.isEmpty)
        }

        private static func testVault() -> VaultRecord {
            VaultRecord(
                id: .v7(),
                path: "/tmp/chat-test-vault",
                name: "Chat Test",
                createdAt: .now,
                lastOpenedAt: .now
            )
        }

        private static func meetingReference(vaultID: UUID, name: String, offset: TimeInterval) -> MeetingOverviewItem {
            MeetingOverviewItem(
                meetingId: .v7(),
                vaultId: vaultID,
                projectId: nil,
                projectName: nil,
                meetingName: name,
                status: .ready,
                duration: nil,
                createdAt: .now.addingTimeInterval(offset),
                hasSummary: false,
                segmentCount: 0,
                latestSegmentText: nil,
                tags: []
            )
        }

        private func waitUntil(
            _ predicate: @MainActor () -> Bool
        ) async {
            for _ in 0 ..< 1000 {
                if predicate() { return }
                await Task.yield()
            }
            Issue.record("Timed out waiting for chat state")
        }

        private func waitUntilAsync(
            _ predicate: @escaping @Sendable () async -> Bool
        ) async {
            for _ in 0 ..< 1000 {
                if await predicate() { return }
                await Task.yield()
            }
            Issue.record("Timed out waiting for asynchronous chat state")
        }

    }

    extension CodexChatSessionModelTests {
        @Test
        func failedLiveTranscriptCanBeRetriedWithoutBecomingVisible() async {
            let service = TestCodexChatService(mode: .failThenComplete)
            let settings = AppSettings()
            settings.currentVault = Self.testVault()
            let session = CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings
            )

            session.toggleLiveMode()
            session.receiveFinalizedLiveTranscript("Retry this speech")
            await waitUntil { !session.isGenerating }

            #expect(session.failedLiveTranscript == "Retry this speech")
            #expect(session.hasRetryableSubmission)
            #expect(session.messages.allSatisfy { $0.role != .user })

            session.retry()
            await waitUntil { !session.isGenerating }

            #expect(session.failedLiveTranscript == nil)
            let sentTextBlocks = await service.sentTextBlocks
            #expect(sentTextBlocks.count == 2)
            #expect(sentTextBlocks[0] == sentTextBlocks[1])
            #expect(session.messages.allSatisfy { $0.role != .user })
        }

        @Test
        func disablingLiveModeCancelsTranscriptBeforeContextResolutionCompletes() async {
            let service = TestCodexChatService(mode: .complete)
            let settings = AppSettings()
            settings.currentVault = Self.testVault()
            let contextProvider = TestCodexChatContextProvider(shouldBlock: true)
            let session = CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings,
                contextProvider: contextProvider
            )

            session.toggleLiveMode()
            session.receiveFinalizedLiveTranscript("Do not send this")
            await waitUntil { contextProvider.requestCount == 1 }
            session.disableLiveMode()
            await waitUntil { !session.isGenerating }

            #expect(await service.sentTextBlocks.isEmpty)
            #expect(session.failedLiveTranscript == nil)
            contextProvider.resume()
        }

        @Test
        func manualSendAfterLiveFailureSteersTheRecoveredTranscript() async {
            let service = TestCodexChatService(mode: .failThenComplete)
            let settings = AppSettings()
            settings.currentVault = Self.testVault()
            let session = CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings
            )

            session.toggleLiveMode()
            session.receiveFinalizedLiveTranscript("Failed live speech")
            await waitUntil { !session.isGenerating }
            #expect(session.failedLiveTranscript == "Failed live speech")

            session.draft = "Manual recovery"
            session.sendDraft()
            await waitUntilAsync { await service.steeredTextBlocks.count == 1 }
            await waitUntil { !session.isGenerating }

            let sentTextBlocks = await service.sentTextBlocks
            #expect(sentTextBlocks[1].last == "Manual recovery")
            #expect(await service.steeredTextBlocks[0].last == "<live_transcript source=\"dahlia\">Failed live speech</live_transcript>")
            #expect(session.failedLiveTranscript == nil)
        }

        @Test
        func retryUsesTheMostRecentlyFailedManualSubmission() async {
            let service = TestCodexChatService(mode: .alwaysFail)
            let settings = AppSettings()
            settings.currentVault = Self.testVault()
            let session = CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings
            )

            session.toggleLiveMode()
            session.receiveFinalizedLiveTranscript("Earlier live failure")
            await waitUntil { !session.isGenerating }

            session.draft = "Latest manual failure"
            session.sendDraft()
            await waitUntil { !session.isGenerating }
            session.retry()
            await waitUntilAsync { await service.sentTextBlocks.count == 3 }
            await waitUntil { !session.isGenerating }

            let sentTextBlocks = await service.sentTextBlocks
            #expect(sentTextBlocks[1].last == "Latest manual failure")
            #expect(sentTextBlocks[2].last == "Latest manual failure")
        }

        @Test
        func truncatedLiveTranscriptUsesNoticeWithoutRetryError() async {
            let service = TestCodexChatService(mode: .block)
            let settings = AppSettings()
            settings.currentVault = Self.testVault()
            let session = CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings
            )

            session.toggleLiveMode()
            session.receiveFinalizedLiveTranscript("Truncated speech", wasTruncated: true)
            await waitUntilAsync { await service.sentTextBlocks.count == 1 }

            #expect(session.isGenerating)
            #expect(session.noticeMessage == L10n.chatLiveTranscriptBacklogTruncated)
            #expect(session.errorMessage == nil)

            session.disableLiveMode()
            await waitUntil { !session.isGenerating }
        }
    }

    actor TestCodexChatService: CodexChatServicing {
        enum Mode {
            case complete
            case block
            case burstThenBlock
            case bufferedBurstThenInterrupt
            case finishesWithoutTerminal
            case interruptedThenBlock
            case failThenComplete
            case alwaysFail
            case staleRollout
            case rolloutWithoutReasoning
            case multipleMessages
            case delayFirstSendIgnoringCancellation
        }

        let mode: Mode
        private var steerErrors: [CodexAppServerError]
        private(set) var sentTextBlocks: [[String]] = []
        private(set) var steeredTextBlocks: [[String]] = []
        private(set) var threadNames: [String] = []
        private(set) var interruptCount = 0
        private(set) var unsubscribedThreadIDs: [String] = []
        private var blockedContinuation: AsyncThrowingStream<CodexChatTurnEvent, any Error>.Continuation?
        private var delayedSendContinuation: CheckedContinuation<Void, Never>?

        var unsubscribeCount: Int {
            unsubscribedThreadIDs.count
        }

        var isSendWaiting: Bool {
            delayedSendContinuation != nil
        }

        init(mode: Mode, steerErrors: [CodexAppServerError] = []) {
            self.mode = mode
            self.steerErrors = steerErrors
        }

        func models(forceRefresh _: Bool) async throws -> [CodexModel] {
            [Self.model]
        }

        func listThreads(cursor _: String?, vaultID _: UUID) async throws -> CodexChatThreadPage {
            CodexChatThreadPage(threads: [], nextCursor: nil)
        }

        func loadThread(id: String) async throws -> CodexChatThread {
            let assistantMessages: [CodexChatMessage] = switch mode {
            case .complete, .block, .burstThenBlock, .bufferedBurstThenInterrupt,
                 .finishesWithoutTerminal, .interruptedThenBlock, .failThenComplete, .alwaysFail,
                 .delayFirstSendIgnoringCancellation:
                [CodexChatMessage(role: .assistant, text: "Final answer", reasoning: "Considered the question")]
            case .rolloutWithoutReasoning:
                [CodexChatMessage(role: .assistant, text: "Final answer")]
            case .staleRollout, .multipleMessages:
                []
            }
            let decoded = CodexChatPromptCodec.decodeTextBlocks(sentTextBlocks.last ?? ["Question"])
            let userMessages: [CodexChatMessage] = decoded.text.nilIfBlank.map { text in
                let message = CodexChatMessage(
                    role: .user,
                    text: text,
                    context: decoded.context
                )
                return [message]
            } ?? []
            return CodexChatThread(
                id: id,
                title: "Question",
                messages: userMessages + assistantMessages,
                model: nil,
                reasoningEffort: nil
            )
        }

        func resumeThread(id: String, vaultID _: UUID) async throws -> CodexChatThread {
            try await loadThread(id: id)
        }

        func startThread(model _: String?, effort: String, vaultID _: UUID) async throws -> CodexChatThread {
            CodexChatThread(
                id: "thread-1",
                title: "",
                messages: [],
                model: "default-model",
                reasoningEffort: effort
            )
        }

        func setThreadName(threadID _: String, name: String) async {
            threadNames.append(name)
        }

        func send(
            threadID _: String,
            textBlocks: [String],
            model _: String?,
            effort _: String
        ) async throws -> AsyncThrowingStream<CodexChatTurnEvent, any Error> {
            sentTextBlocks.append(textBlocks)
            if mode == .delayFirstSendIgnoringCancellation, sentTextBlocks.count == 1 {
                await withCheckedContinuation { continuation in
                    delayedSendContinuation = continuation
                }
            }
            if mode == .failThenComplete, sentTextBlocks.count == 1 {
                throw CodexAppServerError.invalidProtocolResponse
            }
            if mode == .alwaysFail {
                throw CodexAppServerError.invalidProtocolResponse
            }
            let (stream, continuation) = AsyncThrowingStream<CodexChatTurnEvent, any Error>.makeStream()
            continuation.yield(.started(turnID: "turn-1"))
            switch mode {
            case .complete, .staleRollout, .rolloutWithoutReasoning, .failThenComplete, .alwaysFail,
                 .delayFirstSendIgnoringCancellation:
                continuation.yield(.reasoningDelta(
                    itemID: "reasoning-1",
                    summaryIndex: 0,
                    text: "Considered the question"
                ))
                continuation.yield(.reasoningCompleted(itemID: "reasoning-1", text: "Considered the question"))
                continuation.yield(.delta(itemID: "item-1", text: "Final "))
                continuation.yield(.completed(itemID: "item-1", text: "Final answer"))
                continuation.yield(.completed(itemID: nil, text: nil))
                continuation.finish()
            case .block:
                continuation.yield(.delta(itemID: "item-1", text: "Partial"))
                blockedContinuation = continuation
            case .burstThenBlock:
                continuation.yield(.delta(itemID: "item-1", text: "First"))
                continuation.yield(.delta(itemID: "item-1", text: " second"))
                blockedContinuation = continuation
            case .bufferedBurstThenInterrupt:
                for _ in 0 ..< 2048 {
                    continuation.yield(.delta(itemID: "item-1", text: "x"))
                }
                continuation.yield(.interrupted)
                continuation.finish()
            case .finishesWithoutTerminal:
                continuation.yield(.delta(itemID: "item-1", text: "Partial answer"))
                continuation.finish()
            case .interruptedThenBlock:
                continuation.yield(.delta(itemID: "item-1", text: "Partial answer"))
                continuation.yield(.interrupted)
                blockedContinuation = continuation
            case .multipleMessages:
                continuation.yield(.delta(itemID: "item-1", text: "First "))
                continuation.yield(.completed(itemID: "item-1", text: "First answer"))
                continuation.yield(.delta(itemID: "item-2", text: "Second "))
                continuation.yield(.completed(itemID: "item-2", text: "Second answer"))
                continuation.yield(.completed(itemID: nil, text: nil))
                continuation.finish()
            }
            return stream
        }

        func interrupt(threadID _: String, turnID _: String) async {
            interruptCount += 1
            blockedContinuation?.yield(.interrupted)
            blockedContinuation?.finish()
            blockedContinuation = nil
        }

        func steer(threadID _: String, turnID _: String, textBlocks: [String]) async throws {
            steeredTextBlocks.append(textBlocks)
            if !steerErrors.isEmpty {
                throw steerErrors.removeFirst()
            }
        }

        func completeBlockedTurn() {
            blockedContinuation?.yield(.completed(itemID: nil, text: nil))
            blockedContinuation?.finish()
            blockedContinuation = nil
        }

        func resumeDelayedSend() {
            delayedSendContinuation?.resume()
            delayedSendContinuation = nil
        }

        func unsubscribe(threadID: String) async {
            unsubscribedThreadIDs.append(threadID)
        }

        private static let model = CodexModel(
            id: "default",
            model: "default-model",
            displayName: "Default",
            description: "",
            hidden: false,
            isDefault: true,
            supportedReasoningEfforts: [
                CodexReasoningEffortOption(reasoningEffort: "medium", description: ""),
            ],
            defaultReasoningEffort: "medium",
            inputModalities: ["text"]
        )
    }

    @MainActor
    final class TestCodexChatContextProvider: CodexChatContextProviding {
        var context: CodexChatContext?
        var error: CodexAppServerError?
        var requestCount = 0
        private var shouldBlock: Bool
        private var continuation: CheckedContinuation<Void, Never>?

        init(
            context: CodexChatContext? = nil,
            error: CodexAppServerError? = nil,
            shouldBlock: Bool = false
        ) {
            self.context = context
            self.error = error
            self.shouldBlock = shouldBlock
        }

        func currentContext(vaultID _: UUID) async throws -> CodexChatContext? {
            requestCount += 1
            if shouldBlock {
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                }
            }
            if let error {
                throw error
            }
            return context
        }

        func resume() {
            shouldBlock = false
            continuation?.resume()
            continuation = nil
        }
    }

#endif
