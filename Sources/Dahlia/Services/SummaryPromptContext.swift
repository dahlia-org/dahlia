import Foundation

struct SummaryPromptContext {
    let meetingId: UUID
    let recordedAt: Date
    let calendarEvent: CalendarEventRecord?
    let projectName: String?
    let projectDescription: String?

    var xml: String {
        var sections = [meetingXML]
        if let calendarEvent {
            sections.append(calendarEventXML(calendarEvent))
        }
        if let projectXML {
            sections.append(projectXML)
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

    private static func xmlEscaped(_ value: String) -> String {
        value
            .replacing("&", with: "&amp;")
            .replacing("<", with: "&lt;")
            .replacing(">", with: "&gt;")
            .replacing("\"", with: "&quot;")
            .replacing("'", with: "&apos;")
    }

    private static func iso8601(_ date: Date) -> String {
        date.formatted(
            .iso8601
                .year()
                .month()
                .day()
                .time(includingFractionalSeconds: true)
                .timeZone(separator: .colon)
        )
    }
}
