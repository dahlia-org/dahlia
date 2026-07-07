import Foundation

enum CalendarMeetingURLExtractor {
    private static let urlRegex = try! NSRegularExpression(pattern: #"https?://[^\s<>"']+"#)
    private static let knownMeetingDomains = [
        "meet.google.com",
        "zoom.us",
        "teams.microsoft.com",
        "webex.com",
        "bluejeans.com",
        "whereby.com",
        "gotomeeting.com",
        "chime.aws",
    ]

    static func meetingURL(url: URL?, textFields: [String?]) -> URL? {
        if let url, isKnownMeetingURL(url) {
            return url
        }

        for text in textFields {
            guard let text else { continue }
            for candidate in urls(in: text) where isKnownMeetingURL(candidate) {
                return candidate
            }
        }

        return nil
    }

    private static func urls(in text: String) -> [URL] {
        let range = NSRange(text.startIndex..., in: text)
        return urlRegex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            let rawURL = String(text[matchRange])
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}"))
            return URL(string: rawURL)
        }
    }

    private static func isKnownMeetingURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return knownMeetingDomains.contains { domain in
            host == domain || host.hasSuffix(".\(domain)")
        }
    }
}
