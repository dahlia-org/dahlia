import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct CodexChatConversationItemTests {
        @Test
        func insertsDividersOnlyAtContextTransitions() throws {
            let meetingA = try CodexChatContext.meeting(
                id: #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")),
                name: "Meeting A",
                calendarEvent: nil
            )
            let meetingB = try CodexChatContext.meeting(
                id: #require(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")),
                name: "Meeting B",
                calendarEvent: nil
            )
            let messages = [
                CodexChatMessage(id: "u0", role: .user, text: "No context"),
                CodexChatMessage(id: "a0", role: .assistant, text: "Answer"),
                CodexChatMessage(id: "u1", role: .user, text: "A1", context: meetingA),
                CodexChatMessage(id: "u2", role: .user, text: "A2", context: meetingA),
                CodexChatMessage(id: "u3", role: .user, text: "B", context: meetingB),
                CodexChatMessage(id: "u4", role: .user, text: "None"),
            ]

            let dividerIDs = CodexChatConversationItem.build(from: messages).compactMap { item -> String? in
                guard case let .contextDivider(id, _) = item else { return nil }
                return id
            }

            #expect(dividerIDs == ["u1", "u3", "u4"])
        }

        @Test
        func firstMeetingHasDividerButFirstNoContextDoesNot() throws {
            let context = try CodexChatContext.meeting(
                id: #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")),
                name: "Meeting",
                calendarEvent: nil
            )

            let contextual = CodexChatConversationItem.build(from: [
                CodexChatMessage(id: "meeting", role: .user, text: "Question", context: context),
            ])
            let plain = CodexChatConversationItem.build(from: [
                CodexChatMessage(id: "plain", role: .user, text: "Question"),
            ])

            #expect(contextual.count == 2)
            #expect(plain.count == 1)
        }

        @Test
        func materializingSameCalendarDraftDoesNotStartNewSection() throws {
            let start = Date(timeIntervalSince1970: 1_704_067_200)
            let calendarEvent = CodexChatCalendarEventContext(
                icalUID: "same-event@example.com",
                title: "Planning",
                description: "",
                start: start,
                end: start.addingTimeInterval(3600)
            )
            let draft = CodexChatContext.meetingDraft(
                id: UUID.v7(),
                name: "Planning",
                calendarEvent: calendarEvent
            )
            let meeting = try CodexChatContext.meeting(
                id: #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")),
                name: "Planning",
                calendarEvent: calendarEvent
            )
            let items = CodexChatConversationItem.build(from: [
                CodexChatMessage(id: "draft", role: .user, text: "Draft question", context: draft),
                CodexChatMessage(id: "saved", role: .user, text: "Saved question", context: meeting),
            ])
            let dividerCount = items.count { item in
                if case .contextDivider = item { true } else { false }
            }

            #expect(dividerCount == 1)
        }

        @Test
        func restoredDraftWithoutIdentityContinuesWhileMetadataIsUnchanged() {
            let draft = CodexChatContext.meetingDraft(
                id: nil,
                name: "Unsaved",
                calendarEvent: nil
            )
            let changedDraft = CodexChatContext.meetingDraft(
                id: nil,
                name: "Renamed",
                calendarEvent: nil
            )
            let items = CodexChatConversationItem.build(from: [
                CodexChatMessage(id: "first", role: .user, text: "One", context: draft),
                CodexChatMessage(id: "second", role: .user, text: "Two", context: draft),
                CodexChatMessage(id: "third", role: .user, text: "Three", context: changedDraft),
            ])
            let dividerIDs = items.compactMap { item -> String? in
                guard case let .contextDivider(id, _) = item else { return nil }
                return id
            }

            #expect(dividerIDs == ["first", "third"])
        }

        @Test
        func savedMeetingsRemainDistinctEvenWhenTheyShareCalendarMetadata() throws {
            let calendarEvent = CodexChatCalendarEventContext(
                icalUID: "shared@example.com",
                title: "Event",
                description: "",
                start: Date(timeIntervalSince1970: 1_704_067_200),
                end: Date(timeIntervalSince1970: 1_704_070_800)
            )
            let first = try CodexChatContext.meeting(
                id: #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")),
                name: "First",
                calendarEvent: calendarEvent
            )
            let second = try CodexChatContext.meeting(
                id: #require(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")),
                name: "Second",
                calendarEvent: calendarEvent
            )
            let items = CodexChatConversationItem.build(from: [
                CodexChatMessage(id: "first", role: .user, text: "One", context: first),
                CodexChatMessage(id: "second", role: .user, text: "Two", context: second),
            ])

            #expect(items.count { if case .contextDivider = $0 { true } else { false } } == 2)
        }

        @Test
        func sameMeetingIDContinuesWhenMetadataChanges() throws {
            let meetingID = try #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
            let first = CodexChatContext.meeting(
                id: meetingID,
                name: "Original",
                calendarEvent: nil
            )
            let updated = CodexChatContext.meeting(
                id: meetingID,
                name: "Updated",
                calendarEvent: CodexChatCalendarEventContext(
                    icalUID: "added@example.com",
                    title: "Added",
                    description: "",
                    start: Date(timeIntervalSince1970: 1_704_067_200),
                    end: Date(timeIntervalSince1970: 1_704_070_800)
                )
            )
            let items = CodexChatConversationItem.build(from: [
                CodexChatMessage(id: "first", role: .user, text: "One", context: first),
                CodexChatMessage(id: "second", role: .user, text: "Two", context: updated),
            ])

            #expect(items.count { if case .contextDivider = $0 { true } else { false } } == 1)
        }
    }
#endif
