import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CodexChatMeetingReviewShortcutTests {
        @Test
        func promptInvokesOnlyTheSkill() {
            let prompt = CodexChatMeetingReviewShortcut.prompt

            #expect(prompt == "$meeting-reviewer")
            #expect(CodexChatMeetingReviewShortcut.title == L10n.chatMeetingReviewShortcutTitle)
        }

        @Test
        func sendsWithoutChangingComposer() async {
            let service = TestCodexChatService(mode: .staleRollout)
            let settings = AppSettings()
            let vault = Self.testVault()
            settings.currentVault = vault
            var telemetryEvents: [UsageTelemetryEvent] = []
            let reviewMeetingID = UUID.v7()
            let context = CodexChatContext.meeting(
                id: reviewMeetingID,
                name: "Current meeting",
                calendarEvent: nil
            )
            let contextProvider = TestCodexChatContextProvider(context: .meeting(
                id: reviewMeetingID,
                name: "Current meeting",
                calendarEvent: nil
            ))
            let session = CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings,
                contextProvider: contextProvider,
                usageTelemetryReporter: { telemetryEvents.append($0) }
            )
            let meeting = Self.meetingReference(name: "Keep reference")
            let attachment = CodexChatImageAttachment(data: Data([0x01]), mimeType: "image/png")
            session.updateAvailableMeetings([meeting], catalogVaultID: vault.id)
            session.addMeetingReference(meeting)
            session.attachedImages = [attachment]
            session.draft = "Keep draft"

            session.sendMeetingReviewShortcut()
            #expect(await pollUntil { !session.isGenerating })

            #expect(await service.sentTextBlocks == [CodexChatPromptCodec.encodeTextBlocks(
                text: CodexChatMeetingReviewShortcut.prompt,
                context: context
            )])
            #expect(session.draft == "Keep draft")
            #expect(session.selectedMeetingReferenceIDs == [meeting.id])
            #expect(session.attachedImages == [attachment])
            #expect(contextProvider.requestCount == 1)
            #expect(telemetryEvents == [.aiChatPromptSubmitted])
        }

        @Test
        func retryResolvesTheCurrentMeetingContextAgain() async {
            let service = TestCodexChatService(mode: .failThenComplete)
            let settings = AppSettings()
            let vault = Self.testVault()
            settings.currentVault = vault
            let contextProvider = TestCodexChatContextProvider(context: .meeting(
                id: .v7(),
                name: "Meeting selected after the click",
                calendarEvent: nil
            ))
            let session = CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings,
                contextProvider: contextProvider
            )
            let prompt = CodexChatPromptCodec.encodeTextBlocks(
                text: CodexChatMeetingReviewShortcut.prompt,
                context: contextProvider.context
            )

            session.sendMeetingReviewShortcut()
            #expect(await pollUntil { !session.isGenerating })
            session.retry()
            #expect(await pollUntil { await service.sentTextBlocks.count == 2 && !session.isGenerating })

            #expect(await service.sentTextBlocks == [prompt, prompt])
            #expect(contextProvider.requestCount == 2)
        }

        @Test
        func requiresCurrentVaultAndIdleSession() async {
            let service = TestCodexChatService(mode: .block)
            let settings = AppSettings()
            let boundVault = Self.testVault()
            settings.currentVault = boundVault
            var telemetryEvents: [UsageTelemetryEvent] = []
            let session = CodexChatSessionModel(
                vaultID: boundVault.id,
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings,
                usageTelemetryReporter: { telemetryEvents.append($0) }
            )

            session.isTurnCleanupPending = true
            session.sendMeetingReviewShortcut()
            #expect(!session.isGenerating)
            #expect(await service.sentTextBlocks.isEmpty)
            session.isTurnCleanupPending = false

            settings.currentVault = Self.testVault()
            session.sendMeetingReviewShortcut()
            #expect(!session.isGenerating)
            #expect(await service.sentTextBlocks.isEmpty)

            settings.currentVault = boundVault
            session.sendMeetingReviewShortcut()
            #expect(await pollUntil { await service.sentTextBlocks.count == 1 })
            session.sendMeetingReviewShortcut()

            #expect(await service.sentTextBlocks.count == 1)
            #expect(telemetryEvents == [.aiChatPromptSubmitted])
            session.stop()
            #expect(await pollUntil { !session.isGenerating })
        }

        @Test
        func unavailableWhileAHistoryThreadIsRestoring() async {
            let service = TestCodexChatService(mode: .staleRollout)
            let settings = AppSettings()
            let vault = Self.testVault()
            settings.currentVault = vault
            let session = CodexChatSessionModel(
                vaultID: vault.id,
                backendThreadID: "history-thread",
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings
            )

            #expect(session.messages.isEmpty)
            #expect(!session.showsMeetingReviewShortcut)
            #expect(!session.canSendMeetingReviewShortcut)

            session.sendMeetingReviewShortcut()

            #expect(await service.sentTextBlocks.isEmpty)
        }

        private static func testVault() -> VaultRecord {
            VaultRecord(
                id: .v7(),
                path: "/tmp/chat-meeting-review-shortcut-test-vault",
                name: "Meeting Review Shortcut Test",
                createdAt: .now,
                lastOpenedAt: .now
            )
        }

        private static func meetingReference(name: String) -> CodexChatMeetingReference {
            CodexChatMeetingReference(id: .v7(), name: name, recordingStartedAt: .now)
        }
    }
#endif
