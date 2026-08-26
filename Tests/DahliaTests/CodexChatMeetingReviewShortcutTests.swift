import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CodexChatMeetingReviewShortcutTests {
        @Test
        func promptPinsTheSelectedMeeting() throws {
            let meetingID = try #require(UUID(uuidString: "019b6f79-18c5-7000-8000-000000000001"))

            let prompt = CodexChatMeetingReviewShortcut.prompt(meetingID: meetingID)

            #expect(prompt.contains("$meeting-reviewer"))
            #expect(prompt.contains("meeting:\(meetingID.uuidString.lowercased())"))
            #expect(
                CodexChatMeetingReviewShortcut.title(meetingName: "Weekly Review")
                    == L10n.chatMeetingReviewShortcutTitle("Weekly Review")
            )
        }

        @Test
        func sendsWithoutChangingComposer() async {
            let service = TestCodexChatService(mode: .staleRollout)
            let settings = AppSettings()
            let vault = Self.testVault()
            settings.currentVault = vault
            var telemetryEvents: [UsageTelemetryEvent] = []
            let contextProvider = TestCodexChatContextProvider(context: .meeting(
                id: .v7(),
                name: "Another meeting",
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
            let reviewMeetingID = UUID.v7()
            let attachment = CodexChatImageAttachment(data: Data([0x01]), mimeType: "image/png")
            session.updateAvailableMeetings([meeting], catalogVaultID: vault.id)
            session.addMeetingReference(meeting)
            session.attachedImages = [attachment]
            session.draft = "Keep draft"

            session.sendMeetingReviewShortcut(meetingID: reviewMeetingID)
            #expect(await pollUntil { !session.isGenerating })

            #expect(await service.sentTextBlocks == [[CodexChatMeetingReviewShortcut.prompt(meetingID: reviewMeetingID)]])
            #expect(session.draft == "Keep draft")
            #expect(session.selectedMeetingReferenceIDs == [meeting.id])
            #expect(session.attachedImages == [attachment])
            #expect(contextProvider.requestCount == 0)
            #expect(telemetryEvents == [.aiChatPromptSubmitted])
        }

        @Test
        func retryKeepsThePinnedMeetingWithoutResolvingCurrentContext() async {
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
            let meetingID = UUID.v7()
            let prompt = CodexChatMeetingReviewShortcut.prompt(meetingID: meetingID)

            session.sendMeetingReviewShortcut(meetingID: meetingID)
            #expect(await pollUntil { !session.isGenerating })
            session.retry()
            #expect(await pollUntil { await service.sentTextBlocks.count == 2 && !session.isGenerating })

            #expect(await service.sentTextBlocks == [[prompt], [prompt]])
            #expect(contextProvider.requestCount == 0)
        }

        @Test
        func requiresATargetCurrentVaultAndIdleSession() async {
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

            session.sendMeetingReviewShortcut(meetingID: nil)
            #expect(!session.isGenerating)
            #expect(await service.sentTextBlocks.isEmpty)

            session.isTurnCleanupPending = true
            session.sendMeetingReviewShortcut(meetingID: UUID.v7())
            #expect(!session.isGenerating)
            #expect(await service.sentTextBlocks.isEmpty)
            session.isTurnCleanupPending = false

            settings.currentVault = Self.testVault()
            session.sendMeetingReviewShortcut(meetingID: UUID.v7())
            #expect(!session.isGenerating)
            #expect(await service.sentTextBlocks.isEmpty)

            settings.currentVault = boundVault
            session.sendMeetingReviewShortcut(meetingID: UUID.v7())
            #expect(await pollUntil { await service.sentTextBlocks.count == 1 })
            session.sendMeetingReviewShortcut(meetingID: UUID.v7())

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
            #expect(!session.canSendMeetingReviewShortcut(meetingID: UUID.v7()))

            session.sendMeetingReviewShortcut(meetingID: UUID.v7())

            #expect(await service.sentTextBlocks.isEmpty)
        }

        @Test
        func coordinatorExposesOnlySavedMeetingContext() {
            let coordinator = CodexChatCoordinator(
                service: TestCodexChatService(mode: .staleRollout),
                settings: AppSettings()
            )
            let vaultID = UUID.v7()
            let meetingID = UUID.v7()

            coordinator.updateCurrentContext(
                vaultID: vaultID,
                meetingID: meetingID,
                draftMeeting: nil,
                dbQueue: nil
            )
            #expect(coordinator.currentMeetingID == meetingID)

            coordinator.updateCurrentContext(
                vaultID: vaultID,
                meetingID: nil,
                projectID: UUID.v7(),
                draftMeeting: nil,
                dbQueue: nil
            )
            #expect(coordinator.currentMeetingID == nil)

            coordinator.updateCurrentContext(
                vaultID: vaultID,
                meetingID: meetingID,
                draftMeeting: DraftMeeting(id: .v7(), title: "Unsaved draft"),
                dbQueue: nil
            )
            #expect(coordinator.currentMeetingID == nil)

            coordinator.updateCurrentContext(
                vaultID: vaultID,
                meetingID: nil,
                draftMeeting: nil,
                dbQueue: nil
            )
            #expect(coordinator.currentMeetingID == nil)
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
