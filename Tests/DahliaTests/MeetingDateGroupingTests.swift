import Foundation
@testable import Dahlia

#if canImport(Testing)
import Testing

struct MeetingDateGroupingTests {
    @Test
    func groupsTodayYesterdayAndOlderDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_704_153_600)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let older = calendar.date(byAdding: .day, value: -4, to: now)!

        let groups = MeetingDateGrouping.groups(
            from: [
                meeting(name: "Older", createdAt: older),
                meeting(name: "Today", createdAt: now),
                meeting(name: "Yesterday", createdAt: yesterday),
            ],
            calendar: calendar,
            now: now
        )

        #expect(groups.map(\.title).prefix(2) == [L10n.today, L10n.yesterday])
        #expect(groups.map(\.meetings.first?.meetingName) == ["Today", "Yesterday", "Older"])
    }

    @Test
    func meetingsInsideGroupAreNewestFirst() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let base = Date(timeIntervalSince1970: 1_704_153_600)

        let groups = MeetingDateGrouping.groups(
            from: [
                meeting(name: "Early", createdAt: base),
                meeting(name: "Late", createdAt: base.addingTimeInterval(3_600)),
            ],
            calendar: calendar,
            now: base
        )

        #expect(groups.first?.meetings.map(\.meetingName) == ["Late", "Early"])
    }
}
#endif

private func meeting(name: String, createdAt: Date) -> MeetingOverviewItem {
    MeetingOverviewItem(
        meetingId: UUID.v7(),
        vaultId: UUID.v7(),
        projectId: nil,
        projectName: nil,
        meetingName: name,
        status: .ready,
        duration: nil,
        createdAt: createdAt,
        hasSummary: false,
        segmentCount: 0,
        latestSegmentText: nil,
        tags: []
    )
}
