import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct MeetingSearchQueryParserTests {
        @Test
        func parsesIdentifiersNamesAndDateBoundsIntoTypedTokens() throws {
            let projectID = UUID.v7()
            let projects = [
                FlatProjectRow(
                    id: projectID,
                    name: "Acme/Platform",
                    displayName: "Platform",
                    depth: 1,
                    hasChildren: false
                ),
            ]
            let tags = [
                TagRecord(id: 42, name: "Important Customer", colorHex: "#123456", createdAt: .now),
            ]
            let calendar = utcCalendar()

            let result = MeetingSearchQueryParser.parse(
                """
                roadmap project:{\(projectID.uuidString)} tag:"Important Customer" \
                after:2026-07-01 before:2026-08-01
                """,
                projects: projects,
                tags: tags,
                calendar: calendar,
                allowsTerminalUnquotedValue: true
            )
            let criteria = MeetingSearchQueryParser.criteria(text: result.text, tokens: result.tokens)

            #expect(result.text == "roadmap")
            #expect(criteria.projectIDs == [projectID])
            #expect(criteria.tagIDs == [42])
            #expect(dateComponents(criteria.startDate, calendar: calendar) == DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: 2026,
                month: 7,
                day: 1
            ))
            #expect(dateComponents(criteria.endDate, calendar: calendar) == DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: 2026,
                month: 8,
                day: 1
            ))
        }

        @Test
        func resolvesUniqueDisplayNamesAndDeduplicatesConditions() {
            let projectID = UUID.v7()
            let project = FlatProjectRow(
                id: projectID,
                name: "Acme/Platform",
                displayName: "Platform",
                depth: 1,
                hasChildren: false
            )
            let tag = TagRecord(id: 7, name: "Planning", colorHex: "#808080", createdAt: .now)

            let result = MeetingSearchQueryParser.parse(
                "project:Platform project:\"Acme/Platform\" tag:7 tag:Planning ",
                projects: [project],
                tags: [tag],
                allowsTerminalUnquotedValue: false
            )

            #expect(result.text.isEmpty)
            #expect(result.tokens.filter { $0.id == "project:\(projectID.uuidString)" }.count == 1)
            #expect(result.tokens.filter { $0.id == "tag:7" }.count == 1)
        }

        @Test
        func preservesQuotedNumericAndUUIDNamesAsNames() {
            let identifierProjectID = UUID.v7()
            let namedProjectID = UUID.v7()
            let projects = [
                FlatProjectRow(
                    id: namedProjectID,
                    name: identifierProjectID.uuidString,
                    displayName: identifierProjectID.uuidString,
                    depth: 0,
                    hasChildren: false
                ),
                FlatProjectRow(
                    id: identifierProjectID,
                    name: "Identifier Project",
                    displayName: "Identifier Project",
                    depth: 0,
                    hasChildren: false
                ),
            ]
            let tags = [
                TagRecord(id: 7, name: "2026", colorHex: "#111111", createdAt: .now),
                TagRecord(id: 2026, name: "Identifier Tag", colorHex: "#222222", createdAt: .now),
                TagRecord(id: 8, name: "2048", colorHex: "#333333", createdAt: .now),
            ]

            let result = MeetingSearchQueryParser.parse(
                """
                project:"\(identifierProjectID.uuidString)" project:{\(identifierProjectID.uuidString)} \
                tag:"2026" tag:{2026} tag:2048
                """,
                projects: projects,
                tags: tags,
                allowsTerminalUnquotedValue: true
            )

            #expect(result.text.isEmpty)
            #expect(result.tokens.contains { $0.id == "project:\(namedProjectID.uuidString)" })
            #expect(result.tokens.contains { $0.id == "project:\(identifierProjectID.uuidString)" })
            #expect(result.tokens.contains { $0.id == "tag:7" })
            #expect(result.tokens.contains { $0.id == "tag:2026" })
            #expect(result.tokens.contains { $0.id == "tag:8" })
        }

        @Test
        func preservesIncompleteAndUnresolvedQualifiersAsSearchText() {
            let unknownProjectID = UUID.v7()
            let result = MeetingSearchQueryParser.parse(
                "project:{\(unknownProjectID.uuidString)} tag:\"Missing\" project:\"Acme",
                projects: [],
                tags: [],
                allowsTerminalUnquotedValue: true
            )

            #expect(result.tokens.isEmpty)
            #expect(result.text.contains("project:{\(unknownProjectID.uuidString)}"))
            #expect(result.text.contains("tag:\"Missing\""))
            #expect(result.text.contains("project:\"Acme"))
        }

        @Test
        func waitsForSubmitBeforeParsingTerminalUnquotedValue() {
            let project = FlatProjectRow(
                id: .v7(),
                name: "Acme",
                displayName: "Acme",
                depth: 0,
                hasChildren: false
            )

            let whileTyping = MeetingSearchQueryParser.parse(
                "project:Acme",
                projects: [project],
                tags: [],
                allowsTerminalUnquotedValue: false
            )
            let onSubmit = MeetingSearchQueryParser.parse(
                "project:Acme",
                projects: [project],
                tags: [],
                allowsTerminalUnquotedValue: true
            )

            #expect(whileTyping.tokens.isEmpty)
            #expect(whileTyping.text == "project:Acme")
            #expect(onSubmit.text.isEmpty)
            #expect(onSubmit.tokens.map(\.id) == ["project:\(project.id.uuidString)"])
        }

        @Test
        func inclusiveUIEndDateBecomesExclusiveNextDay() throws {
            let calendar = utcCalendar()
            let startDate = try #require(calendar.date(from: DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: 2026,
                month: 7,
                day: 1
            )))
            let endDate = try #require(calendar.date(from: DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: 2026,
                month: 7,
                day: 31
            )))

            let token = MeetingSearchToken.inclusiveDateRange(
                startDate: startDate,
                endDate: endDate,
                calendar: calendar
            )
            let criteria = MeetingSearchQueryParser.criteria(text: "", tokens: [token])

            #expect(dateComponents(criteria.startDate, calendar: calendar)?.day == 1)
            #expect(dateComponents(criteria.endDate, calendar: calendar)?.month == 8)
            #expect(dateComponents(criteria.endDate, calendar: calendar)?.day == 1)
        }

        @Test
        func dateSyntaxUsesGregorianYearsInTheDeviceTimeZone() throws {
            var deviceCalendar = Calendar(identifier: .buddhist)
            deviceCalendar.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))

            let result = MeetingSearchQueryParser.parse(
                "after:2026-07-01 before:2026-08-01",
                projects: [],
                tags: [],
                calendar: deviceCalendar,
                allowsTerminalUnquotedValue: true
            )
            let criteria = MeetingSearchQueryParser.criteria(text: result.text, tokens: result.tokens)
            var gregorianCalendar = Calendar(identifier: .gregorian)
            gregorianCalendar.timeZone = deviceCalendar.timeZone

            #expect(dateComponents(criteria.startDate, calendar: gregorianCalendar)?.year == 2026)
            #expect(dateComponents(criteria.startDate, calendar: gregorianCalendar)?.month == 7)
            #expect(dateComponents(criteria.startDate, calendar: gregorianCalendar)?.day == 1)
            #expect(dateComponents(criteria.endDate, calendar: gregorianCalendar)?.year == 2026)
            #expect(dateComponents(criteria.endDate, calendar: gregorianCalendar)?.month == 8)
            #expect(dateComponents(criteria.endDate, calendar: gregorianCalendar)?.day == 1)
        }

        @Test
        func rejectsDatesThatDoNotUseTheDocumentedPaddedFormat() {
            let result = MeetingSearchQueryParser.parse(
                "after:2026-7-01",
                projects: [],
                tags: [],
                allowsTerminalUnquotedValue: true
            )

            #expect(result.tokens.isEmpty)
            #expect(result.text == "after:2026-7-01")
        }

        @Test
        func boundsSearchInputBeforeParsing() {
            let input = String(
                repeating: "search",
                count: MeetingSearchQueryParser.maximumInputLength
            )
            let result = MeetingSearchQueryParser.boundedInput(input)

            #expect(result.count == MeetingSearchQueryParser.maximumInputLength)
            #expect(result == String(input.prefix(MeetingSearchQueryParser.maximumInputLength)))
        }

        private func utcCalendar() -> Calendar {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            return calendar
        }

        private func dateComponents(_ date: Date?, calendar: Calendar) -> DateComponents? {
            date.map { calendar.dateComponents([.calendar, .timeZone, .year, .month, .day], from: $0) }
        }
    }
#endif
