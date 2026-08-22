import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CodexChatLiveModeSessionTests {
        @Test
        func startingLiveModeSendsVisibleInitialPromptWithoutDoubleCountingTelemetry() async {
            let service = TestCodexChatService(mode: .complete)
            let settings = AppSettings()
            settings.currentVault = Self.testVault()
            var telemetryEvents: [UsageTelemetryEvent] = []
            let session = CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings,
                usageTelemetryReporter: { telemetryEvents.append($0) }
            )

            session.startLiveMode()
            await waitUntil { !session.isGenerating }

            #expect(session.liveModeEnabled)
            #expect(session.messages.first(where: { $0.role == .user })?.text == L10n.chatLiveModeInitialPrompt)
            #expect(await service.sentTextBlocks == [[L10n.chatLiveModeInitialPrompt]])
            #expect(telemetryEvents == [.aiChatLiveModeEnabled])
        }

        @Test
        func disablingLiveModeCancelsTheInitialPromptBeforeItStarts() async {
            let service = TestCodexChatService(mode: .staleRollout)
            let settings = AppSettings()
            settings.currentVault = Self.testVault()
            let session = Self.session(service: service, settings: settings)

            session.startLiveMode()
            session.disableLiveMode()
            await waitUntil { !session.isGenerating && !session.isTurnCleanupPending }

            #expect(await service.sentTextBlocks.isEmpty)
            #expect(session.messages.isEmpty)
        }

        @Test
        func restartingLiveModeSendsOneInitialPromptPerActivation() async {
            let service = TestCodexChatService(mode: .staleRollout)
            let settings = AppSettings()
            settings.currentVault = Self.testVault()
            var telemetryEvents: [UsageTelemetryEvent] = []
            let session = CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings,
                usageTelemetryReporter: { telemetryEvents.append($0) }
            )

            session.startLiveMode()
            await waitUntil { !session.isGenerating }
            session.disableLiveMode()
            session.startLiveMode()
            await waitUntil { !session.isGenerating }

            #expect(await service.sentTextBlocks == [
                [L10n.chatLiveModeInitialPrompt],
                [L10n.chatLiveModeInitialPrompt],
            ])
            #expect(session.messages.filter { $0.role == .user }.map(\.text) == [
                L10n.chatLiveModeInitialPrompt,
                L10n.chatLiveModeInitialPrompt,
            ])
            #expect(telemetryEvents == [.aiChatLiveModeEnabled, .aiChatLiveModeEnabled])
        }

        @Test
        func failedInitialPromptRetriesWithoutAdditionalTelemetry() async {
            let service = TestCodexChatService(mode: .failThenComplete)
            let settings = AppSettings()
            settings.currentVault = Self.testVault()
            var telemetryEvents: [UsageTelemetryEvent] = []
            let session = CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings,
                usageTelemetryReporter: { telemetryEvents.append($0) }
            )

            session.startLiveMode()
            await waitUntil { !session.isGenerating }

            #expect(session.errorMessage != nil)
            #expect(session.messages.allSatisfy { $0.role != .user })

            session.retry()
            await waitUntil { !session.isGenerating }

            #expect(session.errorMessage == nil)
            #expect(await service.sentTextBlocks == [
                [L10n.chatLiveModeInitialPrompt],
                [L10n.chatLiveModeInitialPrompt],
            ])
            #expect(session.messages.filter { $0.role == .user }.map(\.text) == [L10n.chatLiveModeInitialPrompt])
            #expect(telemetryEvents == [.aiChatLiveModeEnabled])
        }

        @Test
        func liveModeShortcutSteersWithoutClearingComposerBeforeTranscriptContext() async throws {
            let service = TestCodexChatService(mode: .block)
            let settings = AppSettings()
            settings.currentVault = Self.testVault()
            let context = try CodexChatContext.meeting(
                id: #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")),
                name: "Current meeting",
                calendarEvent: nil
            )
            let contextProvider = TestCodexChatContextProvider(context: context)
            let session = Self.session(
                service: service,
                settings: settings,
                contextProvider: contextProvider
            )
            let referenceID = UUID.v7()
            let image = CodexChatImageAttachment(data: Data([0x01]), mimeType: "image/png")
            session.draft = "Unsent draft"
            session.selectedMeetingReferenceIDs = [referenceID]
            session.attachedImages = [image]

            session.startLiveMode()
            await waitUntil { session.activeTurnID != nil }
            session.sendLiveModeShortcut(L10n.chatLiveModeSummarizeShortcut)
            await waitUntilAsync { await service.steeredTextBlocks.count == 1 }

            #expect(session.draft == "Unsent draft")
            #expect(session.selectedMeetingReferenceIDs == [referenceID])
            #expect(session.attachedImages == [image])
            #expect(session.messages.filter { $0.role == .user }.map(\.text) == [
                L10n.chatLiveModeInitialPrompt,
                L10n.chatLiveModeSummarizeShortcut,
            ])
            #expect(contextProvider.requestCount == 0)

            session.receiveFinalizedLiveTranscript("First live speech")
            await waitUntilAsync { await service.steeredTextBlocks.count == 2 }

            #expect(await service.steeredTextBlocks == [
                [L10n.chatLiveModeSummarizeShortcut],
                CodexChatPromptCodec.encodeTextBlocks(
                    text: nil,
                    context: context,
                    includesLiveModeContext: true,
                    liveTranscript: "First live speech"
                ),
            ])
            #expect(contextProvider.requestCount == 1)

            await service.completeBlockedTurn()
            await waitUntil { !session.isGenerating }
        }

        @Test
        func repeatedLiveModeShortcutsDoNotQueueWhileSteering() async {
            let service = TestCodexChatService(mode: .block)
            let settings = AppSettings()
            settings.currentVault = Self.testVault()
            let session = Self.session(service: service, settings: settings)

            session.startLiveMode()
            await waitUntil { session.activeTurnID != nil }
            session.sendLiveModeShortcut(L10n.chatLiveModeSummarizeShortcut)
            #expect(!session.canSendLiveModeShortcut)
            session.sendLiveModeShortcut(L10n.chatLiveModeExplainShortcut)
            session.sendLiveModeShortcut(L10n.chatLiveModeHistoryShortcut)
            await waitUntilAsync { await service.steeredTextBlocks.count == 1 }

            #expect(await service.steeredTextBlocks == [[L10n.chatLiveModeSummarizeShortcut]])

            await service.completeBlockedTurn()
            await waitUntil { !session.isGenerating }
        }

        @Test
        func failedShortcutCannotRetryAfterLiveModeEnds() async {
            let service = TestCodexChatService(
                mode: .block,
                steerErrors: [.invalidProtocolResponse]
            )
            let settings = AppSettings()
            settings.currentVault = Self.testVault()
            let session = Self.session(service: service, settings: settings)

            session.startLiveMode()
            await waitUntil { session.activeTurnID != nil }
            session.sendLiveModeShortcut(L10n.chatLiveModeSummarizeShortcut)
            await waitUntil { session.errorMessage != nil }

            session.disableLiveMode()
            await waitUntil { !session.isGenerating && !session.isTurnCleanupPending }
            session.retry()
            await waitUntil { !session.isGenerating && !session.isTurnCleanupPending }

            #expect(await service.sentTextBlocks == [[L10n.chatLiveModeInitialPrompt]])
            #expect(await service.steeredTextBlocks == [[L10n.chatLiveModeSummarizeShortcut]])
        }

        @Test
        func disablingLiveModeDropsAQueuedShortcut() async {
            let service = TestCodexChatService(mode: .block)
            let settings = AppSettings()
            settings.currentVault = Self.testVault()
            let session = Self.session(service: service, settings: settings)

            session.draft = "Root question"
            session.sendDraft()
            await waitUntil { session.activeTurnID != nil }
            session.toggleLiveMode()
            session.sendLiveModeShortcut(L10n.chatLiveModeSummarizeShortcut)
            #expect(!session.canSendLiveModeShortcut)

            session.disableLiveMode()
            await service.completeBlockedTurn()
            await waitUntil { !session.isGenerating }

            #expect(await service.sentTextBlocks == [["Root question"]])
            #expect(await service.steeredTextBlocks.isEmpty)
            #expect(!session.messages.contains { $0.text == L10n.chatLiveModeSummarizeShortcut })
        }

        @Test
        func disablingLiveModeCancelsAnIdleShortcutBeforeItStarts() async {
            let service = TestCodexChatService(mode: .staleRollout)
            let settings = AppSettings()
            settings.currentVault = Self.testVault()
            let session = Self.session(service: service, settings: settings)

            session.startLiveMode()
            await waitUntil { !session.isGenerating }

            session.sendLiveModeShortcut(L10n.chatLiveModeSummarizeShortcut)
            session.disableLiveMode()
            await waitUntil { !session.isGenerating && !session.isTurnCleanupPending }

            #expect(await service.sentTextBlocks == [[L10n.chatLiveModeInitialPrompt]])
            #expect(!session.messages.contains { $0.text == L10n.chatLiveModeSummarizeShortcut })
        }

        @Test
        func eachLiveModeShortcutSendsItsDisplayedText() async {
            let service = TestCodexChatService(mode: .staleRollout)
            let settings = AppSettings()
            settings.currentVault = Self.testVault()
            let session = Self.session(service: service, settings: settings)
            let shortcuts = [
                L10n.chatLiveModeSummarizeShortcut,
                L10n.chatLiveModeExplainShortcut,
                L10n.chatLiveModeHistoryShortcut,
            ]
            session.toggleLiveMode()

            for (index, shortcut) in shortcuts.enumerated() {
                session.sendLiveModeShortcut(shortcut)
                await waitUntilAsync { await service.sentTextBlocks.count == index + 1 }
                await waitUntil { !session.isGenerating }
            }

            #expect(await service.sentTextBlocks == shortcuts.map { [$0] })
        }

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
            let context = try CodexChatContext.meeting(
                id: #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")),
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
            #expect(await service.sentTextBlocks.suffix(2).map(\.first) == [
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
            await Task.yield()
            await Task.yield()

            #expect(await service.sentTextBlocks.count == 1)

            await service.resumeDelayedSend()
            await waitUntilAsync { await service.interruptCount == 1 }
            await waitUntilAsync { await service.sentTextBlocks.count == 2 }
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
            if await pollUntil({ predicate() }) { return }
            Issue.record("Timed out waiting for chat state")
        }

        private func waitUntilAsync(_ predicate: @escaping @Sendable () async -> Bool) async {
            if await pollUntil({ await predicate() }) { return }
            Issue.record("Timed out waiting for async chat state")
        }
    }
#endif
