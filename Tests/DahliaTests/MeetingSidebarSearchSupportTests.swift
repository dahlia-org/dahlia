import AppKit
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct MeetingSidebarSearchSupportTests {
        @Test
        func dismissesSearchOnlyForClicksOutsideTheActiveSearchFieldWindow() {
            let contentView = NSView()
            let searchField = NSSearchField()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                styleMask: [],
                backing: .buffered,
                defer: false
            )
            let otherWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                styleMask: [],
                backing: .buffered,
                defer: false
            )
            window.contentView = contentView
            searchField.frame = NSRect(x: 20, y: 230, width: 200, height: 30)
            contentView.addSubview(searchField)

            #expect(!MeetingSidebarSearchModifier.shouldDismissSearch(
                eventWindow: window,
                searchField: searchField,
                clickLocationInWindow: NSPoint(x: 30, y: 240)
            ))
            #expect(MeetingSidebarSearchModifier.shouldDismissSearch(
                eventWindow: window,
                searchField: searchField,
                clickLocationInWindow: NSPoint(x: 300, y: 100)
            ))
            #expect(!MeetingSidebarSearchModifier.shouldDismissSearch(
                eventWindow: otherWindow,
                searchField: searchField,
                clickLocationInWindow: NSPoint(x: 300, y: 100)
            ))
        }

        @Test
        func recentPeriodUsesOnlyAnInclusiveStartBoundary() throws {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
            let now = try #require(calendar.date(from: DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: 2026,
                month: 7,
                day: 29,
                hour: 12
            )))

            let token = MeetingSidebarSearchModifier.recentPeriodToken(
                days: 7,
                now: now,
                calendar: calendar
            )

            guard case let .dateRange(startDate, endDate) = token.value else {
                Issue.record("Expected a date range token")
                return
            }
            #expect(try calendar.dateComponents([.year, .month, .day], from: #require(startDate)) == DateComponents(
                year: 2026,
                month: 7,
                day: 23
            ))
            #expect(endDate == nil)
        }

        @Test
        func findsTheRightmostIncompleteQualifier() throws {
            let input = "project:Missing tag:Pla"
            let qualifier = try #require(
                MeetingSidebarSearchModifier.TrailingSearchQualifier.find(in: input)
            )

            #expect(qualifier.key == "tag")
            #expect(qualifier.query == "Pla")
            #expect(String(input[qualifier.range]) == "tag:Pla")
            #expect(
                MeetingSidebarSearchModifier.TrailingSearchQualifier.find(
                    in: "project:Missing free text"
                ) == nil
            )

            let quotedQualifier = try #require(
                MeetingSidebarSearchModifier.TrailingSearchQualifier.find(
                    in: #"tag:"Customer project:Alpha""#
                )
            )
            #expect(quotedQualifier.key == "tag")
            #expect(quotedQualifier.query == "Customer project:Alpha")

            let freeTextQuote = try #require(
                MeetingSidebarSearchModifier.TrailingSearchQualifier.find(
                    in: #"notes "draft project:Acme"#
                )
            )
            #expect(freeTextQuote.key == "project")
            #expect(freeTextQuote.query == "Acme")

            let freeTextBrace = try #require(
                MeetingSidebarSearchModifier.TrailingSearchQualifier.find(
                    in: "notes {draft project:Acme"
                )
            )
            #expect(freeTextBrace.key == "project")
            #expect(freeTextBrace.query == "Acme")
        }

        @Test
        func preservesCommittedUnresolvedQualifierWhenAddingAnotherFilter() {
            let input = "project:Missing"

            #expect(
                MeetingSidebarSearchModifier.TrailingSearchQualifier.removingUncommittedQualifier(
                    from: input,
                    committedText: input
                ) == input
            )
            #expect(
                MeetingSidebarSearchModifier.TrailingSearchQualifier.removingUncommittedQualifier(
                    from: input,
                    committedText: nil
                ).isEmpty
            )
        }

        @Test
        func onlyResolvesSubmittedTerminalQualifierAfterCatalogLoad() {
            #expect(!MeetingSidebarSearchModifier.shouldResolveTerminalQualifierAfterCatalogLoad(
                pendingText: nil,
                currentText: "project:Acme"
            ))
            #expect(MeetingSidebarSearchModifier.shouldResolveTerminalQualifierAfterCatalogLoad(
                pendingText: "project:Acme",
                currentText: "project:Acme"
            ))
            #expect(!MeetingSidebarSearchModifier.shouldResolveTerminalQualifierAfterCatalogLoad(
                pendingText: "project:Acme",
                currentText: "project:Acme Research"
            ))
        }

        @Test
        func consumesOnlyTheTextChangeImmediatelyAfterAPasteCommand() {
            var tracker = MeetingSidebarSearchModifier.PasteCommandTracker()

            let initialChange = tracker.consumeNextTextChange()
            tracker.recordPasteCommand()
            let pastedChange = tracker.consumeNextTextChange()
            let followingChange = tracker.consumeNextTextChange()
            tracker.recordPasteCommand()
            tracker.cancel()
            let cancelledChange = tracker.consumeNextTextChange()

            #expect(!initialChange)
            #expect(pastedChange)
            #expect(!followingChange)
            #expect(!cancelledChange)
        }

        @Test
        func recognizesStandardMenuPasteActions() {
            #expect(MeetingSidebarSearchModifier.isPasteAction(NSSelectorFromString("paste:")))
            #expect(MeetingSidebarSearchModifier.isPasteAction(NSSelectorFromString("pasteAsPlainText:")))
            #expect(!MeetingSidebarSearchModifier.isPasteAction(NSSelectorFromString("copy:")))
        }

        @Test
        func keepsUnresolvedQualifierSuggestionsUntilAnotherCategoryIsChosen() {
            let input = #"project:"Missing""#

            #expect(MeetingSidebarSearchModifier.shouldUseTrailingQualifierMode(
                overrideText: nil,
                currentText: input
            ))
            #expect(!MeetingSidebarSearchModifier.shouldUseTrailingQualifierMode(
                overrideText: input,
                currentText: input
            ))
        }

        @Test
        func fixedProjectScopeCannotBeExpandedBySearchTokens() {
            let scopeProjectID = UUID()
            let unrelatedProjectID = UUID()
            let criteria = MeetingSearchCriteria(projectIDs: [unrelatedProjectID])

            let scoped = MeetingSidebarSearchModifier.applyingProjectScope(scopeProjectID, to: criteria)

            #expect(scoped.projectIDs == [scopeProjectID])
            #expect(MeetingSidebarSearchModifier.projectScopeIncludes(
                meetingProjectID: scopeProjectID,
                scopeProjectID: scopeProjectID
            ))
            #expect(!MeetingSidebarSearchModifier.projectScopeIncludes(
                meetingProjectID: unrelatedProjectID,
                scopeProjectID: scopeProjectID
            ))
        }
    }
#endif
