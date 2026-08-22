import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Observation
    import Synchronization
    import Testing

    @MainActor
    struct CodexChatSessionModelTests {
        @Test
        func approvalMethodDefaultsFollowTheConfiguredProvider() {
            #expect(CodexChatApprovalMethod.defaultMethod(for: .chatGPTSubscription) == .autoReview)
            #expect(CodexChatApprovalMethod.defaultMethod(for: .databricks) == .ask)
            #expect(CodexChatApprovalMethod.defaultMethod(for: nil) == .ask)
            #expect(CodexChatApprovalMethod.autoReview.availableMethod(for: .databricks) == .ask)
        }

        @Test
        func approvalMethodSelectionUpdatesAnExistingTask() async {
            let service = TestCodexChatService(mode: .complete)
            let session = CodexChatSessionModel(
                backendThreadID: "thread-1",
                approvalMethod: .ask,
                service: service
            )

            session.selectApprovalMethod(.fullAccess)
            session.selectApprovalMethod(.ask)
            session.selectApprovalMethod(.fullAccess)
            await waitUntilAsync { await service.approvalMethodUpdates.last == .fullAccess }

            #expect(session.selectedApprovalMethod == .fullAccess)
            #expect(await service.approvalMethodUpdates == [.fullAccess])
        }

        @Test
        func approvalChangeDuringTurnStartIsPersistedAfterTheStartedMethod() async {
            let service = TestCodexChatService(mode: .delayTurnHandleIgnoringCancellation)
            let settings = AppSettings()
            settings.currentVault = Self.testVault()
            let session = CodexChatSessionModel(
                backendThreadID: "thread-1",
                approvalMethod: .ask,
                service: service,
                settings: settings
            )
            session.draft = "Question"
            session.sendDraft()
            await waitUntilAsync { await service.isSendWaiting }

            session.selectApprovalMethod(.fullAccess)
            await service.resumeDelayedSend()
            await waitUntilAsync { await service.completedApprovalMethodUpdates.last == .fullAccess }

            #expect(await service.turnApprovalMethods == [.ask])
            #expect(session.selectedApprovalMethod == .fullAccess)
            session.stop()
            await waitUntil { !session.isGenerating }
        }

        @Test
        func providerChangeImmediatelyFallsBackAndPersistsAsk() async {
            let service = TestCodexChatService(mode: .complete)
            let session = CodexChatSessionModel(
                backendThreadID: "thread-1",
                approvalMethod: .autoReview,
                service: service
            )

            session.configuredAccountProviderDidChange(to: .chatGPTSubscription)
            session.configuredAccountProviderDidChange(to: .databricks)
            await waitUntilAsync { await service.completedApprovalMethodUpdates.last == .ask }

            #expect(session.selectedApprovalMethod == .ask)
        }

        @Test
        func providerChangePublishesAvailabilityWhenSelectionStaysAsk() {
            let session = CodexChatSessionModel(approvalMethod: .ask)
            session.configuredAccountProviderDidChange(to: .chatGPTSubscription)
            let didObserveChange = Mutex(false)
            withObservationTracking {
                _ = session.canUseAutoReview
            } onChange: {
                didObserveChange.withLock { $0 = true }
            }

            session.configuredAccountProviderDidChange(to: .databricks)

            #expect(didObserveChange.withLock { $0 })
            #expect(!session.canUseAutoReview)
            #expect(session.selectedApprovalMethod == .ask)
        }

        @Test
        func approvalUpdateRetryDoesNotResendThePreviousPrompt() async {
            let service = TestCodexChatService(
                mode: .complete,
                approvalMethodUpdateError: .invalidProtocolResponse
            )
            let settings = AppSettings()
            settings.currentVault = Self.testVault()
            let session = CodexChatSessionModel(
                backendThreadID: "thread-1",
                approvalMethod: .ask,
                service: service,
                settings: settings
            )
            session.draft = "Question"
            session.sendDraft()
            await waitUntil { !session.isGenerating }
            session.selectApprovalMethod(.fullAccess)
            await waitUntil { session.hasApprovalMethodUpdateFailure }

            session.retry()
            await waitUntilAsync { await service.approvalMethodUpdates.count == 2 }

            #expect(await service.sentTextBlocks == [["Question"]])
        }

        @Test
        func revertingToTheSavedApprovalMethodClearsFailureAndContinuesQueuedInput() async {
            let service = TestCodexChatService(
                mode: .complete,
                approvalMethodUpdateError: .invalidProtocolResponse
            )
            let settings = AppSettings()
            settings.currentVault = Self.testVault()
            let session = CodexChatSessionModel(
                backendThreadID: "thread-1",
                approvalMethod: .ask,
                service: service,
                settings: settings
            )
            session.draft = "Initial question"
            session.sendDraft()
            await waitUntil { !session.isGenerating }
            session.selectApprovalMethod(.fullAccess)
            await waitUntil { session.hasApprovalMethodUpdateFailure }
            session.enqueueManualInput(CodexChatManualSubmission(text: "Queued question", images: []))

            session.selectApprovalMethod(.ask)
            await waitUntil { !session.isGenerating }

            #expect(!session.hasApprovalMethodUpdateFailure)
            #expect(session.errorMessage == nil)
            #expect(await service.sentTextBlocks == [["Initial question"], ["Queued question"]])
            #expect(await service.approvalMethodUpdates == [.fullAccess])
        }

        @Test
        func failedTurnStartKeepsTheApprovalUpdateRetryAvailable() async {
            let service = TestCodexChatService(
                mode: .alwaysFail,
                approvalMethodUpdateError: .invalidProtocolResponse
            )
            let settings = AppSettings()
            settings.currentVault = Self.testVault()
            let session = CodexChatSessionModel(
                backendThreadID: "thread-1",
                approvalMethod: .ask,
                service: service,
                settings: settings
            )
            session.selectApprovalMethod(.fullAccess)
            await waitUntil { session.hasApprovalMethodUpdateFailure }

            session.draft = "Question"
            session.sendDraft()
            await waitUntil { !session.isGenerating }

            #expect(session.hasApprovalMethodUpdateFailure)
            #expect(await service.sentTextBlocks == [["Question"]])

            session.retry()
            await waitUntilAsync { await service.sentTextBlocks.count == 2 }
            await waitUntil { !session.isGenerating }

            #expect(session.hasApprovalMethodUpdateFailure)
            #expect(await service.approvalMethodUpdates == [.fullAccess])
        }

        @Test
        func releaseLetsAnAcceptedApprovalUpdateFinish() async {
            let service = TestCodexChatService(
                mode: .complete,
                delaysApprovalMethodUpdate: true
            )
            let session = CodexChatSessionModel(
                backendThreadID: "thread-1",
                approvalMethod: .ask,
                service: service
            )
            session.selectApprovalMethod(.fullAccess)
            await waitUntilAsync { await service.isApprovalMethodUpdateWaiting }

            session.release()
            await service.resumeDelayedApprovalMethodUpdate()
            await waitUntilAsync { await service.completedApprovalMethodUpdates == [.fullAccess] }
        }

        @Test
        func restoredTaskRestoresItsApprovalMethod() async {
            let service = TestCodexChatService(mode: .complete, restoredApprovalMethod: .fullAccess)
            let settings = AppSettings()
            let vault = Self.testVault()
            settings.currentVault = vault
            let session = CodexChatSessionModel(
                vaultID: vault.id,
                backendThreadID: "thread-1",
                approvalMethod: .ask,
                service: service,
                settings: settings
            )

            await session.restore()

            #expect(session.selectedApprovalMethod == .fullAccess)
        }

        @Test
        func selectionDuringRestoreWinsAndSendingWaitsForRestoredPermissions() async {
            let service = TestCodexChatService(
                mode: .complete,
                delaysLoad: true,
                restoredApprovalMethod: .fullAccess
            )
            let settings = AppSettings()
            let vault = Self.testVault()
            settings.currentVault = vault
            let session = CodexChatSessionModel(
                vaultID: vault.id,
                backendThreadID: "thread-1",
                approvalMethod: .ask,
                service: service,
                settings: settings
            )
            let restoreTask = Task { await session.restore() }
            await waitUntilAsync { await service.isLoadWaiting }

            session.draft = "Question"
            #expect(session.isRestoring)
            #expect(!session.canSend)
            session.sendDraft()
            session.selectApprovalMethod(.ask)

            await service.resumeDelayedLoad()
            await restoreTask.value
            await waitUntilAsync { await service.completedApprovalMethodUpdates.last == .ask }

            #expect(session.selectedApprovalMethod == .ask)
            #expect(await service.sentTextBlocks.isEmpty)
        }

        @Test
        func providerFallbackDuringRestoreDoesNotReplaceStoredFullAccess() async {
            let service = TestCodexChatService(
                mode: .complete,
                delaysLoad: true,
                restoredApprovalMethod: .fullAccess
            )
            let settings = AppSettings()
            let vault = Self.testVault()
            settings.currentVault = vault
            let session = CodexChatSessionModel(
                vaultID: vault.id,
                backendThreadID: "thread-1",
                service: service,
                settings: settings
            )
            let restoreTask = Task { await session.restore() }
            await waitUntilAsync { await service.isLoadWaiting }

            session.configuredAccountProviderDidChange(to: .chatGPTSubscription)
            session.configuredAccountProviderDidChange(to: .databricks)
            #expect(session.selectedApprovalMethod == .ask)

            await service.resumeDelayedLoad()
            await restoreTask.value

            #expect(session.selectedApprovalMethod == .fullAccess)
            #expect(await service.completedApprovalMethodUpdates.isEmpty)
        }

        @Test
        func concurrentRestoreCallsShareOneResumeAndLease() async {
            let service = TestCodexChatService(
                mode: .complete,
                delaysLoad: true,
                restoredApprovalMethod: .ask
            )
            let settings = AppSettings()
            let vault = Self.testVault()
            settings.currentVault = vault
            let session = CodexChatSessionModel(
                vaultID: vault.id,
                backendThreadID: "thread-1",
                service: service,
                settings: settings
            )
            let firstRestore = Task { await session.restore() }
            await waitUntilAsync { await service.isLoadWaiting }

            await session.restore()

            #expect(session.isRestoring)
            #expect(await service.resumedThreadIDs == ["thread-1"])
            await service.resumeDelayedLoad()
            await firstRestore.value

            #expect(await service.acquiredThreadLeaseCount == 1)
        }

        @Test
        func failedRestoreKeepsSendingDisabledUntilRetryRestoresPermissions() async {
            let service = TestCodexChatService(
                mode: .complete,
                restoredApprovalMethod: .fullAccess,
                resumeErrors: [.invalidProtocolResponse]
            )
            let settings = AppSettings()
            let vault = Self.testVault()
            settings.currentVault = vault
            let session = CodexChatSessionModel(
                vaultID: vault.id,
                backendThreadID: "thread-1",
                service: service,
                settings: settings
            )
            session.draft = "Question"

            await session.restore()

            #expect(session.needsRestore)
            #expect(!session.canSend)
            session.sendDraft()
            #expect(await service.sentTextBlocks.isEmpty)
            #expect(await service.approvalMethodUpdates.isEmpty)
            session.selectApprovalMethod(.ask)

            await session.restore()
            await waitUntilAsync { await service.completedApprovalMethodUpdates.last == .ask }

            #expect(!session.needsRestore)
            #expect(session.selectedApprovalMethod == .ask)
            #expect(session.canSend)
        }

        @Test
        func legacyTaskRestoresToAskAndPersistsTheSafeSetting() async {
            let service = TestCodexChatService(mode: .complete)
            let settings = AppSettings()
            let vault = Self.testVault()
            settings.currentVault = vault
            let session = CodexChatSessionModel(
                vaultID: vault.id,
                backendThreadID: "thread-1",
                approvalMethod: .fullAccess,
                service: service,
                settings: settings
            )

            await session.restore()
            await waitUntilAsync { await service.approvalMethodUpdates.last == .ask }

            #expect(session.selectedApprovalMethod == .ask)
        }

        @Test
        func composerContentIncludesTextMeetingReferencesAndImages() {
            let session = CodexChatSessionModel()

            #expect(!session.hasComposerContent)

            session.draft = "Question"
            #expect(session.hasComposerContent)

            session.draft = ""
            session.selectedMeetingReferenceIDs = [UUID.v7()]
            #expect(session.hasComposerContent)

            session.selectedMeetingReferenceIDs = []
            session.attachedImages = [CodexChatImageAttachment(data: Data([0x01]), mimeType: "image/png")]
            #expect(session.hasComposerContent)
        }

        @Test
        func telemetryCountsManualPromptsAndLiveModeTransitionsWithoutCountingRetriesOrTranscripts() async {
            let service = TestCodexChatService(mode: .complete, restoredApprovalMethod: .fullAccess)
            let settings = AppSettings()
            settings.currentVault = Self.testVault()
            var events: [UsageTelemetryEvent] = []
            let session = CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings,
                usageTelemetryReporter: { events.append($0) }
            )

            session.toggleLiveMode()
            session.receiveFinalizedLiveTranscript("Finalized speech")
            await waitUntil { !session.isGenerating }
            session.draft = "Question"
            session.sendDraft()
            await waitUntil { !session.isGenerating }
            session.retry()
            await waitUntil { !session.isGenerating }
            session.disableLiveMode()
            session.toggleLiveMode()

            #expect(events == [
                .aiChatLiveModeEnabled,
                .aiChatPromptSubmitted,
                .aiChatLiveModeEnabled,
            ])
        }

        @Test
        func liveTranscriptIsSentWithoutAddingAUserMessageAndManualChatStaysVisible() async {
            let service = TestCodexChatService(mode: .staleRollout)
            let settings = AppSettings()
            settings.currentVault = Self.testVault()
            let session = CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                approvalMethod: .ask,
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
        func missingThreadIsResumedBeforeRetryingFollowUp() async {
            let service = TestCodexChatService(mode: .complete)
            let settings = AppSettings()
            settings.currentVault = Self.testVault()
            let session = CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                approvalMethod: .ask,
                service: service,
                settings: settings
            )

            session.draft = "Question"
            session.sendDraft()
            await waitUntil { !session.isGenerating }
            await service.failNextTurn(with: .rpcError(
                code: -32600,
                message: "thread not found: thread-1"
            ))

            session.draft = "Follow up"
            session.sendDraft()
            await waitUntil { !session.isGenerating }

            #expect(session.backendThreadID == "thread-1")
            #expect(session.errorMessage == nil)
            #expect(await service.resumedThreadIDs == ["thread-1"])
            #expect(await service.sentTextBlocks == [["Question"], ["Follow up"], ["Follow up"]])
            #expect(await service.turnApprovalMethods == [.ask, .ask, .ask])
            #expect(session.selectedApprovalMethod == .ask)
            #expect(session.messages.map(\.text) == ["Question", "Final answer", "Follow up", "Final answer"])
        }

        @Test
        func stopWhileTurnHandleIsReturningStopsTheOwnedRuntime() async {
            let service = TestCodexChatService(mode: .delayTurnHandleIgnoringCancellation)
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
            await waitUntilAsync { await service.isSendWaiting }

            session.stop()
            await service.resumeDelayedSend()
            await waitUntilAsync { await service.interruptCount == 1 }

            #expect(!session.isGenerating)
            #expect(session.messages.isEmpty)
            #expect(session.draft == "Question")
        }

        @Test
        func stopBeforeTurnHandleReturnsWaitsBeforeStartingQueuedInput() async {
            let service = TestCodexChatService(mode: .delayTurnHandleIgnoringCancellation)
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
            await waitUntilAsync { await service.isSendWaiting }

            session.stop()
            session.draft = "Follow up"
            session.sendDraft()
            await Task.yield()
            await Task.yield()

            #expect(await service.sentTextBlocks == [["Question"]])

            await service.resumeDelayedSend()
            await waitUntilAsync { await service.interruptCount == 1 }
            await waitUntilAsync { await service.sentTextBlocks.count == 2 }

            #expect(await service.sentTextBlocks == [["Question"], ["Follow up"]])

            session.stop()
            await waitUntil { !session.isGenerating }
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
            let first = Self.meetingReference(name: "First", offset: -60)
            let second = Self.meetingReference(name: "Second", offset: 0)
            session.updateAvailableMeetings([first, second], catalogVaultID: vault.id)
            session.addMeetingReference(first)
            session.addMeetingReference(second)
            session.addMeetingReference(first)
            session.draft = "Compare them"

            session.sendDraft()
            await waitUntil { !session.isGenerating }

            let expected = "meeting:\(first.id.uuidString.lowercased()) "
                + "meeting:\(second.id.uuidString.lowercased()) Compare them"
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
            let meeting = Self.meetingReference(name: "Reference Only", offset: 0)
            session.updateAvailableMeetings([meeting], catalogVaultID: vault.id)
            session.addMeetingReference(meeting)

            #expect(session.canSend)
            session.sendDraft()
            await waitUntil { !session.isGenerating }

            #expect(await service.sentTextBlocks == [["meeting:\(meeting.id.uuidString.lowercased())"]])
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
            let meeting = Self.meetingReference(name: "Original", offset: 0)
            session.updateAvailableMeetings([meeting], catalogVaultID: vault.id)
            session.addMeetingReference(meeting)
            let renamed = CodexChatMeetingReference(
                id: meeting.id,
                name: "Renamed",
                recordingStartedAt: meeting.recordingStartedAt
            )
            session.updateAvailableMeetings([renamed], catalogVaultID: vault.id)

            #expect(session.meetingDisplayName(for: meeting.id) == "Renamed")
            session.updateAvailableMeetings([], catalogVaultID: vault.id)
            #expect(session.selectedMeetingReferenceIDs.isEmpty)
            #expect(session.meetingDisplayName(for: meeting.id) == "Renamed")
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
            let meeting = Self.meetingReference(name: "Original", offset: 0)
            session.updateAvailableMeetings([meeting], catalogVaultID: vault.id)
            session.addMeetingReference(meeting)

            let otherVault = Self.testVault()
            session.updateAvailableMeetings([], catalogVaultID: otherVault.id)

            #expect(session.selectedMeetingReferenceIDs == [meeting.id])
            #expect(session.meetingDisplayName(for: meeting.id) == "Original")

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
            let meeting = Self.meetingReference(name: "Original", offset: 0)
            session.updateAvailableMeetings([meeting], catalogVaultID: vault.id)
            session.addMeetingReference(meeting)

            session.updateAvailableMeetings(
                [],
                catalogVaultID: vault.id,
                isCatalogLoaded: false
            )
            #expect(session.selectedMeetingReferenceIDs == [meeting.id])

            session.updateAvailableMeetings([meeting], catalogVaultID: vault.id)
            #expect(session.selectedMeetingReferenceIDs == [meeting.id])
        }

        @Test
        func missingVaultCatalogDoesNotPruneReferences() {
            let settings = AppSettings()
            settings.currentVault = nil
            let session = CodexChatSessionModel(
                service: TestCodexChatService(mode: .complete),
                settings: settings
            )
            let reference = CodexChatMeetingReference(id: .v7(), name: "Cached", recordingStartedAt: .now)
            session.addMeetingReference(reference)

            session.updateAvailableMeetings([], catalogVaultID: nil)

            #expect(session.selectedMeetingReferenceIDs == [reference.id])
        }

        @Test
        func restoredRawReferencesUseCachedNamesAcrossTitleAndMessages() {
            let settings = AppSettings()
            let vault = Self.testVault()
            settings.currentVault = vault
            let meeting = Self.meetingReference(name: "Weekly Sync", offset: 0)
            let token = "meeting:\(meeting.id.uuidString)"
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
        func approvalRequestIsPresentedAndDecisionIsForwarded() async {
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

            let request = CodexChatApprovalRequest(
                id: "s:approval-1",
                kind: .commandExecution,
                command: "ls -la"
            )
            await service.yieldBlockedEvent(.approvalRequested(request))
            await waitUntil { session.pendingApproval == request }

            session.respondToApproval(id: request.id, decision: .accept)
            await waitUntilAsync { await service.approvalDecisions.count == 1 }

            #expect(session.pendingApproval == request)
            #expect(session.respondingApprovalID == request.id)
            #expect(await service.approvalDecisions == [
                TestCodexChatService.ApprovalDecision(id: "s:approval-1", decision: .accept),
            ])
            await service.yieldBlockedEvent(.approvalResolved(id: request.id))
            await waitUntil { session.pendingApproval == nil }
            #expect(session.respondingApprovalID == nil)
        }

        @Test
        func approvalDecisionOutsidePresentedActionsIsIgnored() async {
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

            let request = CodexChatApprovalRequest(
                id: "s:mcp-approval",
                kind: .mcpToolCall,
                mcpServer: "dahlia",
                mcpTool: "update_project",
                mcpArguments: "{}"
            )
            await service.yieldBlockedEvent(.approvalRequested(request))
            await waitUntil { session.pendingApproval == request }

            session.respondToApproval(id: request.id, decision: .acceptForSession)
            try? await Task.sleep(for: .milliseconds(20))

            #expect(await service.approvalDecisions.isEmpty)
            #expect(session.respondingApprovalID == nil)
            session.stop()
            await waitUntil { !session.isGenerating }
        }

        @Test
        func decidingOneApprovalDoesNotResolveAnotherPendingRequest() async {
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

            let first = CodexChatApprovalRequest(
                id: "s:approval-a",
                kind: .commandExecution,
                command: "date"
            )
            let second = CodexChatApprovalRequest(
                id: "s:approval-b",
                kind: .commandExecution,
                command: "uname -s"
            )
            await service.yieldBlockedEvent(.approvalRequested(first))
            await service.yieldBlockedEvent(.approvalRequested(second))
            await waitUntil { session.pendingApprovals.count == 2 }

            session.respondToApproval(id: first.id, decision: .accept)
            await waitUntilAsync { await service.approvalDecisions.count == 1 }

            #expect(session.pendingApprovals == [first, second])
            #expect(await service.approvalDecisions == [
                TestCodexChatService.ApprovalDecision(id: first.id, decision: .accept),
            ])
            await service.yieldBlockedEvent(.approvalResolved(id: first.id))
            await waitUntil { session.pendingApprovals == [second] }
            session.respondToApproval(id: second.id, decision: .accept)
            #expect(await service.approvalDecisions == [
                TestCodexChatService.ApprovalDecision(id: first.id, decision: .accept),
            ])
            await waitUntil { session.canDecidePendingApproval }
            session.respondToApproval(id: second.id, decision: .accept)
            await waitUntilAsync { await service.approvalDecisions.count == 2 }
            session.stop()
            await waitUntil { !session.isGenerating }
        }

        @Test
        func staleApprovalDecisionAdvancesToTheNextRequest() async {
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

            let first = CodexChatApprovalRequest(id: "s:first", kind: .commandExecution, command: "date")
            let second = CodexChatApprovalRequest(id: "s:second", kind: .commandExecution, command: "uname")
            await service.yieldBlockedEvent(.approvalRequested(first))
            await service.yieldBlockedEvent(.approvalRequested(second))
            await waitUntil { session.pendingApprovals == [first, second] }
            await service.expireApproval(id: first.id)

            session.respondToApproval(id: first.id, decision: .accept)
            await waitUntil { session.pendingApprovals == [second] }
            #expect(session.respondingApprovalID == nil)
            await waitUntil { session.canDecidePendingApproval }

            session.stop()
            await waitUntil { !session.isGenerating }
        }

        @Test
        func stopCancelsAllApprovalsBeforeInterrupting() async {
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

            await service.yieldBlockedEvent(.approvalRequested(CodexChatApprovalRequest(
                id: "s:approval-1",
                kind: .fileChange
            )))
            await service.yieldBlockedEvent(.approvalRequested(CodexChatApprovalRequest(
                id: "s:approval-2",
                kind: .commandExecution
            )))
            await waitUntil { session.pendingApprovals.count == 2 }

            session.stop()
            await waitUntil { !session.isGenerating }
            await waitUntilAsync { await service.lifecycleEvents.count == 3 }

            #expect(session.pendingApproval == nil)
            #expect(await service.approvalDecisions == [
                TestCodexChatService.ApprovalDecision(id: "s:approval-1", decision: .cancel),
                TestCodexChatService.ApprovalDecision(id: "s:approval-2", decision: .cancel),
            ])
            #expect(await service.lifecycleEvents == [
                .approval("s:approval-1", .cancel),
                .approval("s:approval-2", .cancel),
                .interrupt,
            ])
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
            #expect(!session.isPreparingTurn)
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

        private static func meetingReference(name: String, offset: TimeInterval) -> CodexChatMeetingReference {
            CodexChatMeetingReference(
                id: .v7(),
                name: name,
                recordingStartedAt: .now.addingTimeInterval(offset)
            )
        }

        private func waitUntil(
            _ predicate: @MainActor () -> Bool
        ) async {
            if await pollUntil({ predicate() }) { return }
            Issue.record("Timed out waiting for chat state")
        }

        private func waitUntilAsync(
            _ predicate: @escaping @Sendable () async -> Bool
        ) async {
            if await pollUntil({ await predicate() }) { return }
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
        struct ApprovalDecision: Equatable {
            let id: String
            let decision: CodexChatApprovalDecision
        }

        enum Mode {
            case complete
            case block
            case blockBeforeOutput
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
            case delayTurnHandleIgnoringCancellation
        }

        let mode: Mode
        private let delaysLoad: Bool
        private let restoredApprovalMethod: CodexChatApprovalMethod?
        private let approvalMethodUpdateError: CodexAppServerError?
        private let delaysApprovalMethodUpdate: Bool
        private var resumeErrors: [CodexAppServerError]
        private var steerErrors: [CodexAppServerError]
        private(set) var sentTextBlocks: [[String]] = []
        private(set) var steeredTextBlocks: [[String]] = []
        private(set) var threadNames: [String] = []
        private(set) var interruptCount = 0
        private(set) var approvalDecisions: [ApprovalDecision] = []
        private(set) var lifecycleEvents: [LifecycleEvent] = []
        private(set) var unsubscribedThreadIDs: [String] = []
        private(set) var resumedThreadIDs: [String] = []
        private(set) var acquiredThreadLeaseCount = 0
        private(set) var approvalMethodUpdates: [CodexChatApprovalMethod] = []
        private(set) var completedApprovalMethodUpdates: [CodexChatApprovalMethod] = []
        private(set) var turnApprovalMethods: [CodexChatApprovalMethod] = []
        private(set) var returnedSendCount = 0
        private var turnErrors: [CodexAppServerError] = []
        private var blockedContinuation: AsyncThrowingStream<CodexChatTurnEvent, any Error>.Continuation?
        private var delayedSendContinuation: CheckedContinuation<Void, Never>?
        private var delayedLoadContinuation: CheckedContinuation<Void, Never>?
        private var delayedApprovalMethodUpdateContinuation: CheckedContinuation<Void, any Error>?
        private var activeLocalTurnID: UUID?
        private var pendingApprovalIDs: [String] = []

        var unsubscribeCount: Int {
            unsubscribedThreadIDs.count
        }

        var isSendWaiting: Bool {
            delayedSendContinuation != nil
        }

        var isLoadWaiting: Bool {
            delayedLoadContinuation != nil
        }

        var isApprovalMethodUpdateWaiting: Bool {
            delayedApprovalMethodUpdateContinuation != nil
        }

        init(
            mode: Mode,
            steerErrors: [CodexAppServerError] = [],
            delaysLoad: Bool = false,
            restoredApprovalMethod: CodexChatApprovalMethod? = nil,
            approvalMethodUpdateError: CodexAppServerError? = nil,
            delaysApprovalMethodUpdate: Bool = false,
            resumeErrors: [CodexAppServerError] = []
        ) {
            self.mode = mode
            self.steerErrors = steerErrors
            self.delaysLoad = delaysLoad
            self.restoredApprovalMethod = restoredApprovalMethod
            self.approvalMethodUpdateError = approvalMethodUpdateError
            self.delaysApprovalMethodUpdate = delaysApprovalMethodUpdate
            self.resumeErrors = resumeErrors
        }

        func models(forceRefresh _: Bool) async throws -> [CodexModel] {
            [Self.model]
        }

        func listThreads(cursor _: String?, vaultID _: UUID) async throws -> CodexChatThreadPage {
            CodexChatThreadPage(threads: [], nextCursor: nil)
        }

        func loadThread(id: String) async throws -> CodexChatThread {
            if delaysLoad {
                await withCheckedContinuation { continuation in
                    delayedLoadContinuation = continuation
                }
            }
            let assistantMessages: [CodexChatMessage] = switch mode {
            case .complete, .block, .blockBeforeOutput, .burstThenBlock, .bufferedBurstThenInterrupt,
                 .finishesWithoutTerminal, .interruptedThenBlock, .failThenComplete, .alwaysFail,
                 .delayFirstSendIgnoringCancellation, .delayTurnHandleIgnoringCancellation:
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
            resumedThreadIDs.append(id)
            if !resumeErrors.isEmpty {
                throw resumeErrors.removeFirst()
            }
            let thread = try await loadThread(id: id)
            return CodexChatThread(
                id: thread.id,
                title: thread.title,
                messages: thread.messages,
                model: thread.model,
                reasoningEffort: thread.reasoningEffort,
                approvalMethod: restoredApprovalMethod
            )
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

        func acquireThreadLease(threadID _: String) async -> UUID {
            acquiredThreadLeaseCount += 1
            return UUID.v7()
        }

        func setThreadName(threadID _: String, name: String) async {
            threadNames.append(name)
        }

        func send(
            threadID _: String,
            inputs: [CodexAppServerInput],
            model _: String?,
            effort _: String
        ) async throws -> AsyncThrowingStream<CodexChatTurnEvent, any Error> {
            let textBlocks = inputs.compactMap(\.textValue)
            sentTextBlocks.append(textBlocks)
            if mode == .delayFirstSendIgnoringCancellation, sentTextBlocks.count == 1 {
                await withCheckedContinuation { continuation in
                    delayedSendContinuation = continuation
                }
            }
            returnedSendCount += 1
            if !turnErrors.isEmpty {
                let error = turnErrors.removeFirst()
                return AsyncThrowingStream { continuation in
                    continuation.finish(throwing: error)
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
            case .blockBeforeOutput:
                blockedContinuation = continuation
            case .delayTurnHandleIgnoringCancellation:
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

        func beginTurn(
            threadID: String,
            inputs: [CodexAppServerInput],
            model: String?,
            effort: String,
            approvalMethod: CodexChatApprovalMethod
        ) async throws -> CodexChatTurnHandle {
            turnApprovalMethods.append(approvalMethod)
            let stream = try await send(
                threadID: threadID,
                inputs: inputs,
                model: model,
                effort: effort
            )
            let id = UUID.v7()
            activeLocalTurnID = id
            if mode == .delayTurnHandleIgnoringCancellation, returnedSendCount == 1 {
                await withCheckedContinuation { continuation in
                    delayedSendContinuation = continuation
                }
            }
            return CodexChatTurnHandle(id: id, events: stream, approvalMethod: approvalMethod)
        }

        func updateApprovalMethod(
            threadID _: String,
            approvalMethod: CodexChatApprovalMethod
        ) async throws -> CodexChatApprovalMethod {
            approvalMethodUpdates.append(approvalMethod)
            if delaysApprovalMethodUpdate {
                try Task.checkCancellation()
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        delayedApprovalMethodUpdateContinuation = continuation
                    }
                } onCancel: {
                    Task { await self.cancelDelayedApprovalMethodUpdate() }
                }
            }
            if let approvalMethodUpdateError {
                throw approvalMethodUpdateError
            }
            completedApprovalMethodUpdates.append(approvalMethod)
            return approvalMethod
        }

        func failNextTurn(with error: CodexAppServerError) {
            turnErrors.append(error)
        }

        func decideApproval(turnID: UUID, id: String, decision: CodexChatApprovalDecision) async throws {
            guard turnID == activeLocalTurnID, pendingApprovalIDs.contains(id) else {
                throw CodexAppServerError.approvalNoLongerPending
            }
            pendingApprovalIDs.removeAll { $0 == id }
            await respondToApproval(id: id, decision: decision)
        }

        func stopTurn(_ turnID: UUID) async {
            guard turnID == activeLocalTurnID else { return }
            for approvalID in pendingApprovalIDs {
                await respondToApproval(id: approvalID, decision: .cancel)
            }
            pendingApprovalIDs.removeAll()
            await interrupt(threadID: "thread-1", turnID: "turn-1")
            activeLocalTurnID = nil
        }

        func interrupt(threadID _: String, turnID _: String) async {
            interruptCount += 1
            lifecycleEvents.append(.interrupt)
            blockedContinuation?.yield(.interrupted)
            blockedContinuation?.finish()
            blockedContinuation = nil
        }

        func respondToApproval(id: String, decision: CodexChatApprovalDecision) async {
            approvalDecisions.append(ApprovalDecision(id: id, decision: decision))
            lifecycleEvents.append(.approval(id, decision))
        }

        enum LifecycleEvent: Equatable {
            case approval(String, CodexChatApprovalDecision)
            case interrupt
        }

        func steer(threadID _: String, turnID _: String, inputs: [CodexAppServerInput]) async throws {
            let textBlocks = inputs.compactMap(\.textValue)
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

        func yieldBlockedEvent(_ event: CodexChatTurnEvent) {
            if case let .approvalRequested(request) = event {
                pendingApprovalIDs.append(request.id)
            }
            blockedContinuation?.yield(event)
        }

        func expireApproval(id: String) {
            pendingApprovalIDs.removeAll { $0 == id }
        }

        func resumeDelayedSend() {
            delayedSendContinuation?.resume()
            delayedSendContinuation = nil
        }

        func resumeDelayedLoad() {
            delayedLoadContinuation?.resume()
            delayedLoadContinuation = nil
        }

        func resumeDelayedApprovalMethodUpdate() {
            delayedApprovalMethodUpdateContinuation?.resume()
            delayedApprovalMethodUpdateContinuation = nil
        }

        private func cancelDelayedApprovalMethodUpdate() {
            delayedApprovalMethodUpdateContinuation?.resume(throwing: CancellationError())
            delayedApprovalMethodUpdateContinuation = nil
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

        func block() {
            shouldBlock = true
        }
    }

#endif
