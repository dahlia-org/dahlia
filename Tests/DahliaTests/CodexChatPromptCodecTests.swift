import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct CodexChatPromptCodecTests {
        @Test
        func meetingContextRoundTripsWithEscapedCalendarMetadata() throws {
            let meetingID = try #require(UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF"))
            let start = Date(timeIntervalSince1970: 1_704_067_200.125)
            let end = start.addingTimeInterval(3600)
            let context = CodexChatContext.meeting(
                id: meetingID,
                name: "Planning & <Review> \"Q1\" 'Owners'",
                calendarEvent: CodexChatCalendarEventContext(
                    icalUID: "event&1@example.com",
                    title: "Roadmap <Review>",
                    description: "First & second\r\n<agenda>",
                    start: start,
                    end: end
                )
            )

            let textBlocks = CodexChatPromptCodec.encodeTextBlocks(text: "What changed?", context: context)
            let prompt = CodexChatPromptCodec.encode(text: "What changed?", context: context)

            #expect(prompt == """
            <context>
              You are viewing a meeting in the Dahlia App.
              Type: Meeting
              <meeting_id>01234567-89AB-CDEF-0123-456789ABCDEF</meeting_id>
              <meeting_name>Planning &amp; &lt;Review&gt; &quot;Q1&quot; &apos;Owners&apos;</meeting_name>

              <calendar_event>
                <ical_uid>event&amp;1@example.com</ical_uid>
                <title>Roadmap &lt;Review&gt;</title>
                <description>First &amp; second&#13;&#10;&lt;agenda&gt;</description>
                <start>2024-01-01T00:00:00.125Z</start>
                <end>2024-01-01T01:00:00.125Z</end>
              </calendar_event>
            </context>

            What changed?
            """)
            #expect(!prompt.contains("<summary>"))
            #expect(textBlocks.count == 2)
            #expect(textBlocks[0] + "\n\n" + textBlocks[1] == prompt)
            #expect(textBlocks[1] == "What changed?")

            let decoded = CodexChatPromptCodec.decode(prompt)
            #expect(decoded.text == "What changed?")
            #expect(decoded.context == context)
            let decodedBlocks = CodexChatPromptCodec.decodeTextBlocks(textBlocks)
            #expect(decodedBlocks.text == "What changed?")
            #expect(decodedBlocks.context == context)
            let flattenedMessage = CodexChatPromptCodec.decodeTextBlocks([textBlocks.joined()])
            #expect(flattenedMessage.text == "What changed?")
            #expect(flattenedMessage.context == context)
            #expect(CodexChatPromptCodec.visibleUserText(from: textBlocks.joined()) == "What changed?")
        }

        @Test
        func noncanonicalContextLikeMessagesRemainVisible() {
            let lowercaseUUID = """
            <context>
              You are viewing a meeting in the Dahlia App.
              Type: Meeting
              <meeting_id>aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee</meeting_id>
              <meeting_name>Meeting</meeting_name>
            </context>

            Keep this visible
            """
            let noncanonicalDate = """
            <context>
              You are viewing an unsaved meeting draft in the Dahlia App.
              Type: MeetingDraft
              <meeting_name>Draft</meeting_name>

              <calendar_event>
                <title>Event</title>
                <description></description>
                <start>2024-01-01T09:00:00.000+09:00</start>
                <end>2024-01-01T10:00:00.000+09:00</end>
              </calendar_event>
            </context>

            Also keep this visible
            """

            for prompt in [lowercaseUUID, noncanonicalDate] {
                let decoded = CodexChatPromptCodec.decode(prompt)
                #expect(decoded.text == prompt)
                #expect(decoded.context == nil)
            }
        }

        @Test
        func meetingWithoutCalendarOmitsCalendarBlock() throws {
            let meetingID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
            let prompt = CodexChatPromptCodec.encode(
                text: "Question",
                context: .meeting(id: meetingID, name: "", calendarEvent: nil)
            )

            #expect(prompt == """
            <context>
              You are viewing a meeting in the Dahlia App.
              Type: Meeting
              <meeting_id>AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE</meeting_id>
              <meeting_name></meeting_name>
            </context>

            Question
            """)
            #expect(CodexChatPromptCodec.decode(prompt).text == "Question")
        }

        @Test
        func draftOmitsMeetingIDAndUnavailableICalUID() {
            let start = Date(timeIntervalSince1970: 1_704_067_200)
            let context = CodexChatContext.meetingDraft(
                id: UUID.v7(),
                name: "Draft",
                calendarEvent: CodexChatCalendarEventContext(
                    icalUID: nil,
                    title: "Calendar draft",
                    description: "",
                    start: start,
                    end: start.addingTimeInterval(1800)
                )
            )

            let prompt = CodexChatPromptCodec.encode(text: "Prepare me", context: context)
            let decoded = CodexChatPromptCodec.decode(prompt)

            #expect(prompt.contains("Type: MeetingDraft"))
            #expect(!prompt.contains("<meeting_id>"))
            #expect(!prompt.contains("<ical_uid>"))
            #expect(decoded.text == "Prepare me")
            guard case let .meetingDraft(id, name, calendarEvent) = decoded.context else {
                Issue.record("Expected MeetingDraft context")
                return
            }
            #expect(id == nil)
            #expect(name == "Draft")
            #expect(calendarEvent?.icalUID == nil)
        }

        @Test
        func legacyAndMalformedMessagesRemainVisible() {
            let legacy = "A regular message"
            let malformed = """
            <context>
              Type: Meeting
              <meeting_id>not-a-uuid</meeting_id>
            </context>

            Keep all of this
            """

            #expect(CodexChatPromptCodec.decode(legacy).text == legacy)
            #expect(CodexChatPromptCodec.decode(legacy).context == nil)
            #expect(CodexChatPromptCodec.decode(malformed).text == malformed)
            #expect(CodexChatPromptCodec.decode(malformed).context == nil)

            let malformedBlocks = ["<context>not Dahlia context</context>", "Keep this visible"]
            let decodedBlocks = CodexChatPromptCodec.decodeTextBlocks(malformedBlocks)
            #expect(decodedBlocks.text == malformedBlocks.joined(separator: "\n"))
            #expect(decodedBlocks.context == nil)

            let unrelatedBlocks = ["First visible", "Second hidden", "Third hidden"]
            #expect(CodexChatPromptCodec.decodeTextBlocks(unrelatedBlocks).text == unrelatedBlocks.joined(separator: "\n"))
            #expect(CodexChatPromptCodec.visibleUserText(from: malformedBlocks.joined()) == malformedBlocks.joined())
        }
    }
#endif
