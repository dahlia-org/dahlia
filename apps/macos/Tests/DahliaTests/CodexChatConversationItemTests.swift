import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct CodexChatConversationItemTests {
        @Test
        func relatedCardsStayWithTheirRequestBeforeNotificationsAndLaterTurns() {
            let question = CodexChatMessage(id: "question", role: .user, text: "Delegate")
            let reply = CodexChatMessage(id: "reply", role: .assistant, text: "Started")
            let notice = CodexChatMessage(id: "notice", role: .notice(.info), text: "Finished")
            let report = CodexChatMessage(id: "report", role: .assistant, text: "Result")
            let followUp = CodexChatMessage(id: "follow-up", role: .user, text: "Next task")
            let messages = [question, reply, notice, report, followUp]
            let threads = ["one", "two"].map {
                CodexChatThreadSummary(id: $0, title: $0, updatedAt: .now, requestMessageID: question.id)
            }
            let anchors = CodexChatConversationItem.relatedThreadAnchors(threads: threads, messages: messages, currentRunID: nil)
            #expect(CodexChatConversationItem.build(from: messages, relatedThreadsByMessageID: anchors) == [
                .message(question), .message(reply), .relatedThreads(messageID: reply.id, threads: threads),
                .message(notice), .message(report), .message(followUp),
            ])
            // Viewing another page must not pull an older card to the bottom of that page.
            #expect(CodexChatConversationItem.build(from: [followUp], relatedThreadsByMessageID: anchors) == [.message(followUp)])
        }

        @Test
        func runningCardsAppearBeforeThinkingWhileMessageIDsAreStillLocal() {
            let runID = UUID.v7()
            let question = CodexChatMessage(id: "local-question", role: .user, text: "Delegate")
            let pending = CodexChatMessage(id: "local-reply", role: .assistant, text: "", isStreaming: true)
            let thread = CodexChatThreadSummary(
                id: "child", title: "Child", updatedAt: .now, requestMessageID: "saved-question", requestRunID: runID
            )
            let anchors = CodexChatConversationItem.relatedThreadAnchors(threads: [thread], messages: [question, pending], currentRunID: runID)
            #expect(CodexChatConversationItem.build(
                from: [question, pending], showsStandaloneThinking: true, relatedThreadsByMessageID: anchors
            ) == [.message(question), .relatedThreads(messageID: question.id, threads: [thread]), .thinking])
            #expect(CodexChatConversationItem.relatedThreadAnchors(
                threads: [thread], messages: [question, pending], currentRunID: .v7()
            ).isEmpty)
        }

        @Test(arguments: [nil, UUID.v7()] as [UUID?])
        func localMessageAnchorsKeepTheRequestingRunAfterNotificationsAndLaterTurns(_ currentRunID: UUID?) {
            let runID = UUID.v7()
            let question = CodexChatMessage(id: "local-question", role: .user, text: "Delegate", runID: runID)
            let reply = CodexChatMessage(id: "local-reply", role: .assistant, text: "Started", runID: runID)
            let notice = CodexChatMessage(role: .notice(.info), text: "A result")
            let next = CodexChatMessage(role: .user, text: "Next task", runID: .v7())
            let thread = CodexChatThreadSummary(
                id: "child", title: "Child", updatedAt: .now, requestMessageID: "persisted-question", requestRunID: runID
            )
            let anchors = CodexChatConversationItem.relatedThreadAnchors(
                threads: [thread], messages: [question, reply, notice, next], currentRunID: currentRunID
            )
            #expect(anchors == [reply.id: [thread]])
        }

        @Test
        func separateRequestsKeepSeparateCards() {
            let messages = [
                CodexChatMessage(id: "first", role: .user, text: "First task"),
                CodexChatMessage(id: "first-reply", role: .assistant, text: "Started first"),
                CodexChatMessage(id: "second", role: .user, text: "Second task"),
                CodexChatMessage(id: "second-reply", role: .assistant, text: "Started second"),
            ]
            let first = CodexChatThreadSummary(id: "one", title: "One", updatedAt: .now, requestMessageID: "first")
            let second = CodexChatThreadSummary(id: "two", title: "Two", updatedAt: .now, requestMessageID: "second")
            let anchors = CodexChatConversationItem.relatedThreadAnchors(threads: [first, second], messages: messages, currentRunID: nil)
            #expect(anchors == ["first-reply": [first], "second-reply": [second]])
        }

        @Test
        func addsThinkingWhileWaitingForStreamingResponse() {
            let emptyConversation = CodexChatConversationItem.build(
                from: [],
                showsStandaloneThinking: true
            )
            let previousMessage = CodexChatMessage(
                id: "previous",
                role: .assistant,
                text: "Previous answer"
            )
            let existingConversation = CodexChatConversationItem.build(
                from: [previousMessage],
                showsStandaloneThinking: true
            )
            let emptyStreamingResponse = CodexChatMessage(
                id: "response",
                role: .assistant,
                text: "",
                isStreaming: true
            )
            let streamingConversation = CodexChatConversationItem.build(
                from: [emptyStreamingResponse],
                showsStandaloneThinking: true
            )

            #expect(emptyConversation == [.thinking])
            #expect(existingConversation == [.message(previousMessage), .thinking])
            #expect(streamingConversation == [.thinking])
        }

        @Test
        func steeredConversationPlacesSingleThinkingIndicatorAfterLatestMessage() {
            let response = CodexChatMessage(
                id: "response",
                role: .assistant,
                text: "Partial",
                isStreaming: true
            )
            let followUp = CodexChatMessage(
                id: "follow-up",
                role: .user,
                text: "Additional context"
            )

            let items = CodexChatConversationItem.build(
                from: [response, followUp],
                showsStandaloneThinking: true
            )

            #expect(items == [.message(response), .message(followUp), .thinking])
        }

        @Test
        func reasoningOnlyLatestResponseUsesInlineActivityWithoutStandaloneThinking() {
            let response = CodexChatMessage(
                id: "response",
                role: .assistant,
                text: "",
                reasoning: "Working through it",
                isStreaming: true
            )

            let items = CodexChatConversationItem.build(
                from: [response],
                showsStandaloneThinking: true
            )

            #expect(items == [.message(response, showsInlineActivity: true)])
            #expect(!items.contains(.thinking))
        }

        @Test
        func steeredReasoningResponseMovesActivityToConversationTail() {
            let response = CodexChatMessage(
                id: "response",
                role: .assistant,
                text: "",
                reasoning: "Working through it",
                isStreaming: true
            )
            let followUp = CodexChatMessage(
                id: "follow-up",
                role: .user,
                text: "Additional context"
            )

            let items = CodexChatConversationItem.build(
                from: [response, followUp],
                showsStandaloneThinking: true
            )

            #expect(items == [.message(response), .message(followUp), .thinking])
            #expect(items.count { $0 == .thinking } == 1)
        }

        @Test
        func completedResponseDoesNotRegainThinkingDuringReconciliation() {
            let message = CodexChatMessage(
                id: "answer",
                role: .assistant,
                text: "Answer"
            )

            let items = CodexChatConversationItem.build(
                from: [message],
                showsStandaloneThinking: false
            )

            #expect(items == [.message(message)])
        }

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
        func pagedConversationUsesThePreviousContextForItsFirstMessage() throws {
            let context = try CodexChatContext.meeting(
                id: #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")),
                name: "Meeting",
                calendarEvent: nil
            )
            let message = CodexChatMessage(id: "continued", role: .user, text: "Continue", context: context)

            let items = CodexChatConversationItem.build(
                from: [message],
                previousUserContext: context,
                hasPreviousUserMessage: true
            )

            #expect(items == [.message(message)])
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

        @Test
        func finishedRunCollapsesStepsAndSteerBeforeTheFinalAnswer() {
            let runID = UUID.v7()
            let start = Date(timeIntervalSince1970: 1000)
            let tool = CodexChatToolActivity(name: "read", status: .succeeded, callID: "call")
            let question = CodexChatMessage(id: "question", role: .user, text: "Fix it", runID: runID, timestamp: start)
            let step = CodexChatMessage(
                id: "step", role: .assistant, text: "Looking", reasoning: "Plan", toolActivities: [tool], runID: runID
            )
            let steer = CodexChatMessage(id: "steer", role: .user, text: "Also docs", isSteer: true, runID: runID)
            let answer = CodexChatMessage(
                id: "answer", role: .assistant, text: "Done", reasoning: "Check", runID: runID,
                timestamp: start.addingTimeInterval(36)
            )
            var answerSteps = answer
            answerSteps.text = ""
            var finalAnswer = answer
            finalAnswer.reasoning = ""

            #expect(CodexChatConversationItem.build(from: [question, step, steer, answer]) == [
                .message(question),
                .work(id: answer.id, messages: [step, steer, answerSteps], duration: 36),
                .message(finalAnswer),
            ])
            // Before history reloads, a live response is one row and its steer follows it.
            #expect(CodexChatConversationItem.build(from: [question, answer, steer]) == [
                .message(question),
                .work(id: answer.id, messages: [answerSteps, steer], duration: 36),
                .message(finalAnswer),
            ])
        }

        @Test
        func toolEndingRunsRemainExpandedIncludingRestoredToolsAndTrailingSteers() {
            let runID = UUID.v7()
            let question = CodexChatMessage(role: .user, text: "Fix it", runID: runID)
            var progress = CodexChatMessage(role: .assistant, text: "Investigating", runID: runID)
            progress.recordToolActivity(.init(name: "read", status: .succeeded))
            let steer = CodexChatMessage(role: .user, text: "Also docs", isSteer: true, runID: runID)
            #expect(CodexChatConversationItem.build(from: [question, progress, steer]) == [
                .message(question), .message(progress), .message(steer),
            ])
            let tool = CodexChatMessage(role: .assistant, text: "", toolActivities: [.init(name: "read", status: .failed)], runID: runID)
            progress.toolActivities = []
            progress.endsWithToolActivity = false
            #expect(CodexChatConversationItem.build(from: [question, progress, tool]) == [
                .message(question), .message(progress), .message(tool),
            ])
        }

        @Test
        func loadedRunStaysOnOnePageAndMissingOpeningMessageOmitsDuration() throws {
            let runID = UUID.v7()
            let start = Date(timeIntervalSince1970: 1000)
            let question = CodexChatMessage(role: .user, text: "Fix it", runID: runID, timestamp: start)
            let steps = (0 ..< 60).map { CodexChatMessage(id: "step-\($0)", role: .assistant, text: "Progress", runID: runID, timestamp: start) }
            let answer = CodexChatMessage(role: .assistant, text: "Done", runID: runID, timestamp: start.addingTimeInterval(60))
            let next = CodexChatMessage(role: .user, text: "Next", runID: UUID.v7())
            let messages = [question] + steps + [answer, next]
            #expect(CodexChatConversationWindow.pageRanges(in: messages) == [0 ..< 62, 62 ..< 63])
            let items = CodexChatConversationItem.build(from: steps + [answer])
            guard case let .work(_, _, duration) = try #require(items.first) else {
                Issue.record("Expected one work log")
                return
            }
            #expect(duration == nil)
        }

        @Test
        func runningOrUnansweredRunsStayExpanded() {
            let runID = UUID.v7()
            let question = CodexChatMessage(role: .user, text: "Fix it", runID: runID)
            let tool = CodexChatToolActivity(name: "read", status: .succeeded)
            let streaming = CodexChatMessage(
                role: .assistant, text: "Partial", isStreaming: true, toolActivities: [tool], runID: runID
            )
            let stopped = CodexChatMessage(role: .assistant, text: "", toolActivities: [tool], runID: runID)
            let plain = CodexChatMessage(role: .assistant, text: "Hello", runID: runID)

            #expect(CodexChatConversationItem.build(from: [question, streaming]) == [.message(question), .message(streaming)])
            #expect(CodexChatConversationItem.build(from: [question, stopped]) == [.message(question), .message(stopped)])
            #expect(CodexChatConversationItem.build(from: [question, plain]) == [.message(question), .message(plain)])
        }
    }
#endif
