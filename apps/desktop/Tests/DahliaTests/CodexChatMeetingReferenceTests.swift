import DahliaRuntimeSupport
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

            #expect(text == "meeting:\(TypeID.encode(firstID, as: .meeting)) "
                + "meeting:\(TypeID.encode(secondID, as: .meeting)) Compare these meetings")
            #expect(CodexChatMeetingReference.serializedText(referenceIDs: [firstID], draft: "  ")
                == "meeting:\(TypeID.encode(firstID, as: .meeting))")
        }

        @Test(arguments: [false, true])
        func recognizesOnlyStandaloneValidMeetingTokens(legacy: Bool) throws {
            let firstID = try #require(UUID(uuidString: "019b6f79-18c5-7000-8000-000000000001"))
            let secondID = try #require(UUID(uuidString: "019b6f79-18c5-7000-8000-000000000002"))
            let text = "meeting:\(legacy ? firstID.uuidString : TypeID.encode(firstID, as: .meeting)) compare meeting:\(legacy ? secondID.uuidString : TypeID.encode(secondID, as: .meeting)) "
                + "suffixmeeting:\(legacy ? firstID.uuidString : TypeID.encode(firstID, as: .meeting)) meeting:not-a-uuid meeting:\(legacy ? firstID.uuidString : TypeID.encode(firstID, as: .meeting))."

            #expect(CodexChatMeetingReference.meetingIDs(in: text) == [firstID, secondID])
        }

        @Test(arguments: [false, true])
        func separatesStandaloneReferencesFromMessagePreview(legacy: Bool) throws {
            let firstID = try #require(UUID(uuidString: "019b6f79-18c5-7000-8000-000000000001"))
            let secondID = try #require(UUID(uuidString: "019b6f79-18c5-7000-8000-000000000002"))
            let text = "meeting:\(legacy ? firstID.uuidString : TypeID.encode(firstID, as: .meeting)) meeting:\(legacy ? secondID.uuidString : TypeID.encode(secondID, as: .meeting)) Compare these\nmeetings"

            let content = CodexChatMeetingReference.previewContent(in: text)

            #expect(content.referenceIDs == [firstID, secondID])
            #expect(content.instruction == "Compare these\nmeetings")
            let embedded = CodexChatMeetingReference.previewContent(
                in: "Compare meeting:\(legacy ? firstID.uuidString : TypeID.encode(firstID, as: .meeting))"
            )
            #expect(embedded.referenceIDs == [firstID])
            #expect(embedded.instruction == "Compare")
            let duplicate = CodexChatMeetingReference.previewContent(
                in: "meeting:\(legacy ? firstID.uuidString : TypeID.encode(firstID, as: .meeting)) Repeat meeting:\(legacy ? firstID.uuidString : TypeID.encode(firstID, as: .meeting))  "
            )
            #expect(duplicate.referenceIDs == [firstID, firstID])
            #expect(duplicate.instruction == "Repeat")
            let invalid = CodexChatMeetingReference.previewContent(in: "Keep meeting:not-a-uuid")
            #expect(invalid.referenceIDs.isEmpty)
            #expect(invalid.instruction == "Keep meeting:not-a-uuid")
            let indented = CodexChatMeetingReference.previewContent(
                in: "meeting:\(legacy ? firstID.uuidString : TypeID.encode(firstID, as: .meeting)) \n  Keep indentation"
            )
            #expect(indented.instruction == "\n  Keep indentation")
        }

        @Test(arguments: [false, true])
        func resolvesDisplayNamesWithoutExposingUnknownIDs(legacy: Bool) throws {
            let knownID = try #require(UUID(uuidString: "019b6f79-18c5-7000-8000-000000000001"))
            let unknownID = try #require(UUID(uuidString: "019b6f79-18c5-7000-8000-000000000002"))
            let text = "Review meeting:\(legacy ? knownID.uuidString : TypeID.encode(knownID, as: .meeting)) and meeting:\(legacy ? unknownID.uuidString : TypeID.encode(unknownID, as: .meeting))"

            let display = CodexChatMeetingReference.displayText(
                for: text,
                namesByID: [knownID: "Weekly Sync"],
                unavailableName: "Unavailable"
            )

            #expect(display == "Review Weekly Sync and Unavailable")
            #expect(!display.contains(knownID.uuidString))
            #expect(!display.contains(unknownID.uuidString))
        }

        @Test(arguments: [false, true])
        func resolvesDisplayNamesInsidePunctuationAndMarkdown(legacy: Bool) throws {
            let knownID = try #require(UUID(uuidString: "019b6f79-18c5-7000-8000-000000000001"))
            let unknownID = try #require(UUID(uuidString: "019b6f79-18c5-7000-8000-000000000002"))
            let text = "Review (Meeting:\(legacy ? knownID.uuidString : TypeID.encode(knownID, as: .meeting))), `MEETING:\(legacy ? unknownID.uuidString : TypeID.encode(unknownID, as: .meeting))`."

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
        func rejectsWrongKindAndMalformedTypeIDReferences() {
            let id = UUID()
            for value in [TypeID.encode(id, as: .project), TypeID.encode(id, as: .meeting) + "x", "mtg_" + String(repeating: "8", count: 26)] {
                let text = "meeting:" + value
                #expect(CodexChatMeetingReference.meetingIDs(in: text).isEmpty)
                #expect(CodexChatMeetingReference.previewContent(in: text).instruction == text)
                #expect(CodexChatMeetingReference.displayText(for: text, namesByID: [id: "Meeting"]) == text)
            }
        }

        @Test
        func suggestionsAreRecentFilteredAndExcludeSelectedMeetings() throws {
            let selectedID = try #require(UUID(uuidString: "019b6f79-18c5-7000-8000-000000000001"))
            let olderID = try #require(UUID(uuidString: "019b6f79-18c5-7000-8000-000000000002"))
            let newerID = try #require(UUID(uuidString: "019b6f79-18c5-7000-8000-000000000003"))
            let references = [
                CodexChatMeetingReference(id: olderID, name: "Weekly Planning", recordingStartedAt: .now.addingTimeInterval(-60)),
                CodexChatMeetingReference(id: selectedID, name: "Weekly Review", recordingStartedAt: .now),
                CodexChatMeetingReference(id: newerID, name: "Weekly Planning", recordingStartedAt: .now.addingTimeInterval(-30)),
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
        func pickerSelectionMovesAndClamps() {
            let first = CodexChatMeetingReference(id: .v7(), name: "First", recordingStartedAt: .now)
            let second = CodexChatMeetingReference(id: .v7(), name: "Second", recordingStartedAt: .now)
            let references = [first, second]

            #expect(CodexChatMeetingPickerSelection.moving(currentID: nil, in: references, by: 1) == first.id)
            #expect(CodexChatMeetingPickerSelection.moving(currentID: first.id, in: references, by: -1) == first.id)
            #expect(CodexChatMeetingPickerSelection.moving(currentID: first.id, in: references, by: 1) == second.id)
            #expect(CodexChatMeetingPickerSelection.moving(currentID: second.id, in: references, by: 1) == second.id)
            #expect(CodexChatMeetingPickerSelection.moving(currentID: first.id, in: [], by: 1) == nil)
        }
    }
#endif
