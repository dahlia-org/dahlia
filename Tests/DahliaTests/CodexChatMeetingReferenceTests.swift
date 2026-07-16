import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct CodexChatMeetingReferenceTests {
        @Test
        func serializesReferencesAndDraftAsSpaceSeparatedWords() throws {
            let firstID = try #require(UUID(uuidString: "019b6f79-18c5-7000-8000-000000000001"))
            let secondID = try #require(UUID(uuidString: "019b6f79-18c5-7000-8000-000000000002"))

            let text = CodexChatMeetingReference.serializedText(
                referenceIDs: [firstID, secondID],
                draft: "Compare these meetings"
            )

            #expect(text == "meeting:019b6f79-18c5-7000-8000-000000000001 "
                + "meeting:019b6f79-18c5-7000-8000-000000000002 Compare these meetings")
            #expect(CodexChatMeetingReference.serializedText(referenceIDs: [firstID], draft: "  ")
                == "meeting:019b6f79-18c5-7000-8000-000000000001")
        }

        @Test
        func recognizesOnlyStandaloneValidMeetingTokens() throws {
            let firstID = try #require(UUID(uuidString: "019b6f79-18c5-7000-8000-000000000001"))
            let secondID = try #require(UUID(uuidString: "019b6f79-18c5-7000-8000-000000000002"))
            let text = "meeting:\(firstID.uuidString) compare meeting:\(secondID.uuidString) "
                + "suffixmeeting:\(firstID.uuidString) meeting:not-a-uuid meeting:\(firstID.uuidString)."

            #expect(CodexChatMeetingReference.meetingIDs(in: text) == [firstID, secondID])
        }

        @Test
        func resolvesDisplayNamesWithoutExposingUnknownIDs() throws {
            let knownID = try #require(UUID(uuidString: "019b6f79-18c5-7000-8000-000000000001"))
            let unknownID = try #require(UUID(uuidString: "019b6f79-18c5-7000-8000-000000000002"))
            let text = "Review meeting:\(knownID.uuidString) and meeting:\(unknownID.uuidString)"

            let display = CodexChatMeetingReference.displayText(
                for: text,
                namesByID: [knownID: "Weekly Sync"],
                unavailableName: "Unavailable"
            )

            #expect(display == "Review Weekly Sync and Unavailable")
            #expect(!display.contains(knownID.uuidString))
            #expect(!display.contains(unknownID.uuidString))
        }

        @Test
        func resolvesDisplayNamesInsidePunctuationAndMarkdown() throws {
            let knownID = try #require(UUID(uuidString: "019b6f79-18c5-7000-8000-000000000001"))
            let unknownID = try #require(UUID(uuidString: "019b6f79-18c5-7000-8000-000000000002"))
            let text = "Review (Meeting:\(knownID.uuidString)), `MEETING:\(unknownID.uuidString)`."

            let display = CodexChatMeetingReference.displayText(
                for: text,
                namesByID: [knownID: "Weekly Sync"],
                unavailableName: "Unavailable"
            )

            #expect(display == "Review (Weekly Sync), `Unavailable`.")
            #expect(!display.contains(knownID.uuidString))
            #expect(!display.contains(unknownID.uuidString))
            #expect(CodexChatMeetingReference.meetingIDs(in: text).isEmpty)
        }

        @Test
        func suggestionsAreRecentFilteredAndExcludeSelectedMeetings() throws {
            let selectedID = try #require(UUID(uuidString: "019b6f79-18c5-7000-8000-000000000001"))
            let olderID = try #require(UUID(uuidString: "019b6f79-18c5-7000-8000-000000000002"))
            let newerID = try #require(UUID(uuidString: "019b6f79-18c5-7000-8000-000000000003"))
            let references = [
                CodexChatMeetingReference(id: olderID, name: "Weekly Planning", createdAt: .now.addingTimeInterval(-60)),
                CodexChatMeetingReference(id: selectedID, name: "Weekly Review", createdAt: .now),
                CodexChatMeetingReference(id: newerID, name: "Weekly Planning", createdAt: .now.addingTimeInterval(-30)),
            ]

            let suggestions = CodexChatMeetingReference.suggestions(
                from: references,
                excluding: [selectedID],
                query: "planning"
            )

            #expect(suggestions.map(\.id) == [newerID, olderID])
        }

        @Test
        func extractsAndRemovesTrailingMentionQuery() {
            #expect(CodexChatMeetingReference.trailingMentionQuery(in: "Review @week") == "week")
            #expect(CodexChatMeetingReference.removingTrailingMentionQuery(from: "Review @week") == "Review ")
            #expect(CodexChatMeetingReference.removingTrailingMentionQuery(from: "  @week") == "  ")
            #expect(CodexChatMeetingReference.trailingMentionQuery(in: "mail@example.com") == nil)
            #expect(CodexChatMeetingReference.trailingMentionQuery(in: "@")?.isEmpty == true)
            #expect(CodexChatMeetingReference.trailingMentionQuery(in: "Review @week ") == nil)
            #expect(CodexChatMeetingReference.draftAfterSelectingReference(
                "Keep @word",
                consumesTrailingMention: false
            ) == "Keep @word")
        }

        @Test
        func pickerSelectionMovesAndClamps() throws {
            let first = CodexChatMeetingReference(id: .v7(), name: "First", createdAt: .now)
            let second = CodexChatMeetingReference(id: .v7(), name: "Second", createdAt: .now)
            let references = [first, second]

            #expect(CodexChatMeetingPickerSelection.moving(currentID: nil, in: references, by: 1) == first.id)
            #expect(CodexChatMeetingPickerSelection.moving(currentID: first.id, in: references, by: -1) == first.id)
            #expect(CodexChatMeetingPickerSelection.moving(currentID: first.id, in: references, by: 1) == second.id)
            #expect(CodexChatMeetingPickerSelection.moving(currentID: second.id, in: references, by: 1) == second.id)
            #expect(CodexChatMeetingPickerSelection.moving(currentID: first.id, in: [], by: 1) == nil)
        }
    }
#endif
