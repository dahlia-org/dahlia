import Foundation

struct CodexChatMeetingReference: Identifiable, Equatable {
    let id: UUID
    let name: String
    let createdAt: Date

    init(id: UUID, name: String, createdAt: Date) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }

    init(meeting: MeetingOverviewItem) {
        id = meeting.meetingId
        name = meeting.meetingName.nilIfBlank ?? L10n.newMeeting
        createdAt = meeting.createdAt
    }

    static func suggestions(
        from references: [Self],
        excluding selectedIDs: [UUID],
        query: String
    ) -> [Self] {
        let excluded = Set(selectedIDs)
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return references
            .filter { reference in
                !excluded.contains(reference.id)
                    && (trimmedQuery.isEmpty || reference.name.localizedStandardContains(trimmedQuery))
            }
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.createdAt > rhs.createdAt
            }
    }

    static func serializedText(referenceIDs: [UUID], draft: String) -> String {
        let references = referenceIDs.map { "meeting:\($0.uuidString.lowercased())" }
        let components = references + [draft.nilIfBlank].compactMap(\.self)
        return components.joined(separator: " ")
    }

    static func meetingIDs(in text: String) -> [UUID] {
        tokens(in: text).compactMap(meetingID(from:))
    }

    static func previewContent(in text: String) -> (referenceIDs: [UUID], instruction: String) {
        var referenceIDs: [UUID] = []
        var instruction = ""
        var index = text.startIndex
        var removedReference = false
        var lastWordWasReference = false

        while index < text.endIndex {
            let separatorEnd = text[index...].firstIndex(where: { !$0.isWhitespace }) ?? text.endIndex
            let separator = text[index ..< separatorEnd]
            guard separatorEnd < text.endIndex else {
                if !lastWordWasReference {
                    instruction.append(contentsOf: separator)
                }
                break
            }

            let wordEnd = text[separatorEnd...].firstIndex(where: \Character.isWhitespace) ?? text.endIndex
            let word = String(text[separatorEnd ..< wordEnd])
            if let meetingID = meetingID(from: word) {
                referenceIDs.append(meetingID)
                removedReference = true
                lastWordWasReference = true
            } else {
                if !instruction.isEmpty || !removedReference {
                    instruction.append(contentsOf: separator)
                } else if separator.count > 1 {
                    instruction.append(contentsOf: separator.dropFirst())
                }
                instruction.append(word)
                lastWordWasReference = false
            }
            index = wordEnd
        }

        return (referenceIDs, instruction)
    }

    static func displayText(
        for text: String,
        namesByID: [UUID: String],
        unavailableName: String = L10n.meetingUnavailable
    ) -> String {
        guard text.range(of: meetingTokenPrefix, options: .caseInsensitive) != nil else { return text }
        var result = ""
        var searchStart = text.startIndex

        while let prefixRange = text.range(
            of: meetingTokenPrefix,
            options: .caseInsensitive,
            range: searchStart ..< text.endIndex
        ) {
            result.append(contentsOf: text[searchStart ..< prefixRange.lowerBound])
            guard let uuidEnd = text.index(
                prefixRange.upperBound,
                offsetBy: uuidStringLength,
                limitedBy: text.endIndex
            ),
                let meetingID = UUID(
                    uuidString: String(text[prefixRange.upperBound ..< uuidEnd])
                )
            else {
                result.append(contentsOf: text[prefixRange.lowerBound ..< prefixRange.upperBound])
                searchStart = prefixRange.upperBound
                continue
            }

            result.append(namesByID[meetingID] ?? unavailableName)
            searchStart = uuidEnd
        }
        result.append(contentsOf: text[searchStart...])
        return result
    }

    static func trailingMentionQuery(in text: String) -> String? {
        guard text.last?.isWhitespace == false else { return nil }
        let wordStart = text.lastIndex(where: \.isWhitespace)
            .map { text.index(after: $0) }
            ?? text.startIndex
        let lastWord = text[wordStart...]
        guard lastWord.first == "@" else { return nil }
        return String(lastWord.dropFirst())
    }

    static func removingTrailingMentionQuery(from text: String) -> String {
        guard let query = trailingMentionQuery(in: text) else { return text }
        let mentionLength = query.count + 1
        return String(text.dropLast(mentionLength))
    }

    static func draftAfterSelectingReference(_ text: String, consumesTrailingMention: Bool) -> String {
        consumesTrailingMention ? removingTrailingMentionQuery(from: text) : text
    }

    private static func tokens(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func meetingID(from token: String) -> UUID? {
        guard token.hasPrefix(meetingTokenPrefix), token.count > meetingTokenPrefix.count else { return nil }
        return UUID(uuidString: String(token.dropFirst(meetingTokenPrefix.count)))
    }

    private static let meetingTokenPrefix = "meeting:"
    private static let uuidStringLength = 36
}
