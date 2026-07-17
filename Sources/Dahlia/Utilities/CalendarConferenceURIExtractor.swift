import Foundation

enum CalendarConferenceURIExtractor {
    private static let urlRegex = try? NSRegularExpression(pattern: #"https?://[^\s<>"']+"#)
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

    static func conferenceURI(url: URL?, textFields: [String?]) -> URL? {
        var candidates: [URL] = []
        if let url, isKnownMeetingURI(url) {
            candidates.append(url)
        }

        for text in textFields {
            guard let text else { continue }
            candidates.append(contentsOf: uris(in: text).filter(isKnownMeetingURI))
        }

        return candidates.first { $0.scheme?.lowercased() == "https" } ?? candidates.first
    }

    private static func uris(in text: String) -> [URL] {
        guard let urlRegex else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return urlRegex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            let rawURI = String(text[matchRange])
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}"))
            return URL(string: rawURI)
        }
    }

    private static func isKnownMeetingURI(_ uri: URL) -> Bool {
        guard let host = uri.host?.lowercased() else { return false }
        return knownMeetingDomains.contains { domain in
            host == domain || host.hasSuffix(".\(domain)")
        }
    }
}
