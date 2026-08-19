import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct ProjectCalendarMonthTests {
        @Test
        func monthMovementDoesNotSkipShorterMonths() throws {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(secondsFromGMT: 9 * 3600))
            let january31 = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 31)))
            let march31 = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 31)))

            let next = ProjectCalendarMonth.date(byAddingMonths: 1, to: january31, calendar: calendar)
            let previous = ProjectCalendarMonth.date(byAddingMonths: -1, to: march31, calendar: calendar)

            #expect(calendar.dateComponents([.year, .month, .day], from: next) == DateComponents(year: 2026, month: 2, day: 1))
            #expect(calendar.dateComponents([.year, .month, .day], from: previous) == DateComponents(year: 2026, month: 2, day: 1))
        }

        @Test
        func buildsCompleteWeeksAndGroupsMeetingsByLocalDay() throws {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(secondsFromGMT: 9 * 3600))
            calendar.firstWeekday = 2
            let month = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 15)))
            let firstMeeting = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 9)))
            let secondMeeting = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 18)))

            let days = ProjectCalendarMonth.days(
                containing: month,
                meetings: [meeting(at: firstMeeting), meeting(at: secondMeeting)],
                calendar: calendar
            )

            #expect(days.count == 42)
            #expect(days.first?.isInMonth == false)
            #expect(days.last?.isInMonth == false)
            let augustThird = try #require(days.first { calendar.component(.day, from: $0.date) == 3 && $0.isInMonth })
            #expect(augustThird.meetings.map(\.effectiveRecordingStartedAt) == [firstMeeting, secondMeeting])
            #expect(augustThird.visibleMeetings.count == 2)
            #expect(augustThird.hiddenMeetingCount == 0)

            let overflow = ProjectCalendarDay(
                date: firstMeeting,
                isInMonth: true,
                meetings: (0 ..< 5).map { _ in meeting(at: firstMeeting) }
            )
            #expect(overflow.visibleMeetings.count == 3)
            #expect(overflow.hiddenMeetingCount == 2)
        }

        private func meeting(at date: Date) -> MeetingSidebarItem {
            MeetingSidebarItem(
                meetingId: .v7(),
                vaultId: .v7(),
                projectId: .v7(),
                projectName: "Project",
                meetingName: "Meeting",
                status: .ready,
                duration: nil,
                createdAt: date,
                recordingStartedAt: date,
                calendarEventTitle: nil
            )
        }
    }
#endif
