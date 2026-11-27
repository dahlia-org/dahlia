#if canImport(Testing)
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    struct AgentSourcePromptTests {
        private func source(service: String, instructions: String = "", options: AgentSourceOptions = .init()) -> AgentSourceRecord {
            var source = AgentSourceRecord(
                id: UUID.v7().uuidString, agentID: "agent", name: "Work", server: "server", instructions: instructions,
                intervalMinutes: 15, allowedSenders: "[]", cursor: nil, enabled: true, lastIntakeAt: nil,
                createdAt: .now, updatedAt: .now
            )
            source.service = service
            source.sourceOptions = options
            return source
        }

        @Test func everyRequestRunsTheIntakeSkillAndEndsWithItsRange() {
            let prompt = AgentSourcePrompt.intake(source(service: "", instructions: "Open Jira issues"), since: "2027-01-15T08:00:00Z")
            #expect(prompt.hasPrefix("/skill:intake Source: Work\n"))
            #expect(prompt.contains("What to read: Open Jira issues"))
            #expect(prompt.hasSuffix("Read the items that arrived since 2027-01-15T08:00:00Z."))
        }

        @Test(arguments: [false, true])
        func mailAddressedOnlyAddsItsLineAndNotesFollow(addressedOnly: Bool) {
            let prompt = AgentSourcePrompt.intake(
                source(service: "mail", instructions: "Invoices first", options: .init(addressedOnly: addressedOnly)), since: "x"
            )
            #expect(prompt.contains("in To or Cc") == addressedOnly)
            #expect(prompt.contains("The user's notes on what to read: Invoices first") && !prompt.contains("What to read:"))
        }

        @Test func mailSendersAndDomainsNarrowTheRead() {
            var mail = source(service: "mail", options: .init(allowedDomains: ["example.com"]))
            mail.allowedSenders = #"["boss@other.com"]"#
            #expect(AgentSourcePrompt.intake(mail, since: "x").contains("their subdomains: boss@other.com, example.com."))
            #expect(!AgentSourcePrompt.intake(source(service: "mail"), since: "x").contains("subdomains"))
        }

        @MainActor @Test func slackDropsSendersAndMailKeepsItsDomains() {
            let model = DahliaBotPanelModel()
            var draft = DahliaBotPanelModel.Draft(allowedSenders: "a@example.com", allowedDomains: " @Example.com, ", service: "slack")
            #expect(model.draftSource(draft).allowedSenders == "[]")
            draft.service = "mail"
            let mail = model.draftSource(draft)
            #expect(mail.allowedSenders == #"["a@example.com"]"# && mail.sourceOptions.allowedDomains == ["example.com"])
        }

        @Test func slackScopeAndChannelsBecomeTheirOwnLines() {
            let scopes: [(AgentSourceOptions.SlackScope, String)] = [
                (.mentions, "Read only messages that mention"), (.joined, "channels the user has joined"), (.all, "has not joined"),
            ]
            for (scope, line) in scopes {
                #expect(AgentSourcePrompt.intake(source(service: "slack", options: .init(slackScope: scope)), since: "x").contains(line))
            }
            let prompt = AgentSourcePrompt.intake(
                source(service: "slack", options: .init(slackScope: .mentions, includeChannels: ["team-dev"], excludeChannels: ["random", "ops"])),
                since: "x"
            )
            #expect(prompt.contains("only in these channels: #team-dev."))
            #expect(prompt.contains("even when the user is mentioned there: #random, #ops."))
            #expect(!prompt.contains("notes"))
        }

        @Test func channelNamesDropHashesSpacesAndEmptyEntries() {
            #expect(DahliaBotPanelModel.channels(" #general, ,team-dev ,# ops,") == ["general", "team-dev", "ops"])
        }

        @Test func readingUnjoinedChannelsNeedsChannelsOrNotes() {
            #expect(source(service: "slack", options: .init(slackScope: .all)).lacksSlackChannels)
            #expect(!source(service: "slack", options: .init(slackScope: .all, includeChannels: ["general"])).lacksSlackChannels)
            #expect(!source(service: "slack", instructions: "Channels about billing", options: .init(slackScope: .all)).lacksSlackChannels)
            #expect(!source(service: "slack", options: .init(slackScope: .joined)).lacksSlackChannels)
        }

        @Test func calendarNotesNarrowToAcceptedMeetingsOnlyWhenAsked() {
            let narrowed = source(service: "", options: .init(acceptedOnly: true))
            #expect(AgentSourcePrompt.weeklyNote(narrowed) == L10n.agentCalendarWeeklyNote + L10n.agentCalendarAcceptedOnlyNote)
            #expect(AgentSourcePrompt.dailyNote(source(service: "")) == L10n.agentCalendarDailyNote)
        }

        @Test func optionsRoundTripThroughTheirColumn() throws {
            let queue = try AppDatabaseManager(path: ":memory:").dbQueue
            let agent = try queue.write { try AgentRecord.insertForTest(in: $0) }
            var saved = source(service: "slack", options: .init(slackScope: .joined, excludeChannels: ["random"]))
            saved.agentID = agent.id
            saved.connectionID = "slack"
            let service = AgentInboxService(dbQueue: queue, agentID: agent.id)
            try service.saveSource(saved)
            let loaded = try #require(try service.sources().first)
            #expect(loaded.service == "slack" && loaded.sourceOptions == saved.sourceOptions)
        }
    }
#endif
