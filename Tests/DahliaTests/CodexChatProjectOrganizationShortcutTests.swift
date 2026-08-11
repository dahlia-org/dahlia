import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CodexChatProjectOrganizationShortcutTests {
        @Test
        func usesFixedThirtyDayBoundaries() throws {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
            let now = Date(timeIntervalSince1970: 1_800_000_000.125)
            let createdFrom = try #require(
                calendar.date(
                    byAdding: .day,
                    value: -CodexChatProjectOrganizationShortcut.periodDays,
                    to: now
                )
            )

            let prompt = CodexChatProjectOrganizationShortcut.prompt(now: now, calendar: calendar)

            #expect(CodexChatProjectOrganizationShortcut.periodDays == 30)
            #expect(
                CodexChatProjectOrganizationShortcut.title
                    == L10n.chatProjectOrganizationShortcutTitle(CodexChatProjectOrganizationShortcut.periodDays)
            )
            #expect(prompt.contains("$projects-optimizer"))
            #expect(prompt.contains("created_from: \(CodexChatPromptCodec.format(createdFrom))"))
            #expect(prompt.contains("created_before: \(CodexChatPromptCodec.format(now))"))
        }

        @Test
        func sendsWithoutChangingComposer() async throws {
            let service = TestCodexChatService(mode: .staleRollout)
            let settings = AppSettings()
            let vault = Self.testVault()
            settings.currentVault = vault
            var telemetryEvents: [UsageTelemetryEvent] = []
            let session = CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings,
                usageTelemetryReporter: { telemetryEvents.append($0) }
            )
            let meeting = Self.meetingReference(name: "Keep reference")
            let attachment = CodexChatImageAttachment(data: Data([0x01]), mimeType: "image/png")
            session.updateAvailableMeetings([meeting], catalogVaultID: vault.id)
            session.addMeetingReference(meeting)
            session.attachedImages = [attachment]
            session.draft = "Keep draft"
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
            let now = Date(timeIntervalSince1970: 1_800_000_000.125)
            let expectedPrompt = CodexChatProjectOrganizationShortcut.prompt(now: now, calendar: calendar)

            session.sendProjectOrganizationShortcut(now: now, calendar: calendar)
            #expect(await pollUntil { !session.isGenerating })

            #expect(await service.sentTextBlocks == [[expectedPrompt]])
            #expect(session.draft == "Keep draft")
            #expect(session.selectedMeetingReferenceIDs == [meeting.id])
            #expect(session.attachedImages == [attachment])
            #expect(telemetryEvents == [.aiChatPromptSubmitted])
        }

        @Test
        func requiresCurrentVaultAndIdleSession() async {
            let service = TestCodexChatService(mode: .block)
            let settings = AppSettings()
            let boundVault = Self.testVault()
            settings.currentVault = boundVault
            let session = CodexChatSessionModel(
                vaultID: boundVault.id,
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings
            )

            settings.currentVault = Self.testVault()
            session.sendProjectOrganizationShortcut()
            #expect(!session.isGenerating)
            #expect(await service.sentTextBlocks.isEmpty)

            settings.currentVault = boundVault
            session.sendProjectOrganizationShortcut()
            #expect(await pollUntil { await service.sentTextBlocks.count == 1 })
            session.sendProjectOrganizationShortcut()
            await Task.yield()

            #expect(await service.sentTextBlocks.count == 1)
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
            #expect(!session.showsProjectOrganizationShortcut)
            #expect(!session.canSendProjectOrganizationShortcut)

            session.sendProjectOrganizationShortcut()
            await Task.yield()

            #expect(await service.sentTextBlocks.isEmpty)
        }

        private static func testVault() -> VaultRecord {
            VaultRecord(
                id: .v7(),
                path: "/tmp/chat-shortcut-test-vault",
                name: "Chat Shortcut Test",
                createdAt: .now,
                lastOpenedAt: .now
            )
        }

        private static func meetingReference(name: String) -> CodexChatMeetingReference {
            CodexChatMeetingReference(id: .v7(), name: name, recordingStartedAt: .now)
        }
    }
#endif
