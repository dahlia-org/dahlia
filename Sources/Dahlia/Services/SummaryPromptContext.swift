import Foundation

struct SummaryPromptContext {
    let meetingId: UUID
    let recordedAt: Date
    let calendarEvent: CalendarEventRecord?
    let projectName: String?
    let projectDescription: String?
    let previousMeetings: [SummaryPreviousMeetingMetadata]

    init(
        meetingId: UUID,
        recordedAt: Date,
        calendarEvent: CalendarEventRecord?,
        projectName: String?,
        projectDescription: String?,
        previousMeetings: [SummaryPreviousMeetingMetadata] = []
    ) {
        self.meetingId = meetingId
        self.recordedAt = recordedAt
        self.calendarEvent = calendarEvent
        self.projectName = projectName
        self.projectDescription = projectDescription
        self.previousMeetings = previousMeetings
    }

    var xml: String {
        var sections = [meetingXML]
        if let calendarEvent {
            sections.append(calendarEventXML(calendarEvent))
        }
        if let projectXML {
            sections.append(projectXML)
        }
        if !previousMeetings.isEmpty {
            sections.append(previousMeetingsXML)
        }
        return "<context>\n" + sections.joined(separator: "\n\n") + "\n</context>"
    }

    private var meetingXML: String {
        """
          <meeting>
            <id>\(meetingId.uuidString)</id>
            <recorded_at>\(Self.iso8601(recordedAt))</recorded_at>
          </meeting>
        """
    }

    private func calendarEventXML(_ event: CalendarEventRecord) -> String {
        """
          <calendar_event>
            <ical_uid>\(Self.xmlEscaped(event.icalUid))</ical_uid>
            <title>\(Self.xmlEscaped(event.title))</title>
            <description>\(Self.xmlEscaped(event.description))</description>
            <start>\(Self.iso8601(event.start))</start>
            <end>\(Self.iso8601(event.end))</end>
          </calendar_event>
        """
    }

    private var projectXML: String? {
        guard let name = projectName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return nil
        }
        let description = projectDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return """
          <project>
            <name>\(Self.xmlEscaped(name))</name>
            <description>\(Self.xmlEscaped(description))</description>
          </project>
        """
    }

    private var previousMeetingsXML: String {
        let meetings = previousMeetings
            .map(previousMeetingXML)
            .joined(separator: "\n")
        return "  <previous_meetings>\n\(meetings)\n  </previous_meetings>"
    }

    private func previousMeetingXML(_ meeting: SummaryPreviousMeetingMetadata) -> String {
        var lines = [
            "    <previous_meeting>",
            "      <meeting_id>\(meeting.meetingId.uuidString)</meeting_id>",
            "      <name>\(Self.xmlEscaped(meeting.name))</name>",
            "      <recorded_at>\(Self.iso8601(meeting.recordedAt))</recorded_at>",
        ]
        if let calendarStart = meeting.calendarStart {
            lines.append("      <start>\(Self.iso8601(calendarStart))</start>")
        }
        if let calendarEnd = meeting.calendarEnd {
            lines.append("      <end>\(Self.iso8601(calendarEnd))</end>")
        }
        lines.append("    </previous_meeting>")
        return lines.joined(separator: "\n")
    }

    private static func xmlEscaped(_ value: String) -> String {
        value
            .replacing("&", with: "&amp;")
            .replacing("<", with: "&lt;")
            .replacing(">", with: "&gt;")
            .replacing("\"", with: "&quot;")
            .replacing("'", with: "&apos;")
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
