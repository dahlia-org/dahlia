import Foundation

struct MeetingSearchCriteria: Equatable, Hashable, Sendable {
    var text: String
    var projectIDs: Set<UUID>
    var tagIDs: Set<Int64>
    var startDate: Date?
    var endDate: Date?

    init(
        text: String = "",
        projectIDs: Set<UUID> = [],
        tagIDs: Set<Int64> = [],
        startDate: Date? = nil,
        endDate: Date? = nil
    ) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.projectIDs = projectIDs
        self.tagIDs = tagIDs
        self.startDate = startDate
        self.endDate = endDate
    }

    var isEmpty: Bool {
        text.isEmpty && projectIDs.isEmpty && tagIDs.isEmpty && startDate == nil && endDate == nil
    }

    var identity: String {
        let components = [
            text,
            projectIDs.map(\.uuidString).sorted().joined(separator: ","),
            tagIDs.sorted().map(String.init).joined(separator: ","),
            startDate.map { String($0.timeIntervalSince1970) } ?? "",
            endDate.map { String($0.timeIntervalSince1970) } ?? "",
        ]
        return components
            .map { "\($0.utf8.count):\($0)" }
            .joined()
    }
}

struct MeetingSearchToken: Identifiable, Equatable, Hashable, Sendable {
    static let dateRangeIdentifier = "date-range"

    enum Value: Equatable, Hashable, Sendable {
        case project(id: UUID, name: String)
        case tag(id: Int64, name: String, colorHex: String)
        case dateRange(startDate: Date?, endDate: Date?)
    }

    let value: Value

    var id: String {
        switch value {
        case let .project(id, _):
            Self.projectIdentifier(id)
        case let .tag(id, _, _):
            Self.tagIdentifier(id)
        case .dateRange:
            Self.dateRangeIdentifier
        }
    }

    static func projectIdentifier(_ id: UUID) -> String {
        "project:\(id.uuidString)"
    }

    static func tagIdentifier(_ id: Int64) -> String {
        "tag:\(id)"
    }

    static func inclusiveDateRange(
        startDate: Date,
        endDate: Date,
        calendar: Calendar = .current
    ) -> Self {
        let normalizedStart = calendar.startOfDay(for: startDate)
        let normalizedEnd = calendar.startOfDay(for: endDate)
        return Self(value: .dateRange(
            startDate: normalizedStart,
            endDate: calendar.date(byAdding: .day, value: 1, to: normalizedEnd)
        ))
    }
}

struct MeetingSearchMatchContext: Equatable, Hashable, Sendable {
    enum Kind: Equatable, Hashable, Sendable {
        case title
        case description
        case summary
        case calendar
        case tag
        case project
    }

    let kind: Kind
    let text: String
    let colorHex: String?

    init(
        kind: Kind,
        text: String,
        colorHex: String? = nil
    ) {
        self.kind = kind
        self.text = text
        self.colorHex = colorHex
    }
}

struct MeetingSearchParseResult: Equatable {
    let text: String
    let tokens: [MeetingSearchToken]
}

enum MeetingSearchQueryParser {
    /// Bounds parsing and suggestion-mode scans performed while the search field is edited.
    static let maximumInputLength = 1024

    private static let qualifierExpression = try? NSRegularExpression(
        pattern: #"(?i)(?:^|\s)((project|tag|after|before):(?:\{[^}\n]+\}|"[^"\n]+"|[^\s]+))(?=\s|$)"#
    )

    static func parse(
        _ input: String,
        existingTokens: [MeetingSearchToken] = [],
        projects: [FlatProjectRow],
        tags: [TagRecord],
        calendar: Calendar = .current,
        allowsTerminalUnquotedValue: Bool
    ) -> MeetingSearchParseResult {
        guard let qualifierExpression else {
            return MeetingSearchParseResult(text: input, tokens: existingTokens)
        }
        let fullRange = NSRange(input.startIndex ..< input.endIndex, in: input)
        let matches = qualifierExpression.matches(in: input, range: fullRange)
        var parsedTokens = existingTokens
        var consumedRanges: [Range<String.Index>] = []
        var (parsedStartDate, parsedEndDate) = existingDateRange(in: existingTokens)
        var parsedDateQualifier = false

        for match in matches {
            guard let qualifier = parsedQualifier(
                match,
                in: input,
                projects: projects,
                tags: tags,
                calendar: calendar,
                allowsTerminalUnquotedValue: allowsTerminalUnquotedValue
            ) else { continue }
            switch qualifier.value {
            case let .token(token) where !parsedTokens.contains(where: { $0.id == token.id }):
                parsedTokens.append(token)
            case let .after(date):
                parsedStartDate = date
                parsedDateQualifier = true
            case let .before(date):
                parsedEndDate = date
                parsedDateQualifier = true
            default:
                break
            }
            consumedRanges.append(qualifier.range)
        }

        if parsedDateQualifier {
            parsedTokens.removeAll { $0.id == MeetingSearchToken.dateRangeIdentifier }
            parsedTokens.append(MeetingSearchToken(value: .dateRange(
                startDate: parsedStartDate,
                endDate: parsedEndDate
            )))
        }

        return MeetingSearchParseResult(
            text: removingConsumedRanges(consumedRanges, from: input),
            tokens: parsedTokens
        )
    }

    static func criteria(text: String, tokens: [MeetingSearchToken]) -> MeetingSearchCriteria {
        var projectIDs: Set<UUID> = []
        var tagIDs: Set<Int64> = []
        var startDate: Date?
        var endDate: Date?

        for token in tokens {
            switch token.value {
            case let .project(id, _):
                projectIDs.insert(id)
            case let .tag(id, _, _):
                tagIDs.insert(id)
            case let .dateRange(start, end):
                startDate = start
                endDate = end
            }
        }

        return MeetingSearchCriteria(
            text: text,
            projectIDs: projectIDs,
            tagIDs: tagIDs,
            startDate: startDate,
            endDate: endDate
        )
    }

    static func boundedInput(_ input: String) -> String {
        String(input.prefix(maximumInputLength))
    }

    private static func parsedValue(_ rawValue: String) -> ParsedQualifierValue {
        if rawValue.hasPrefix("{"), rawValue.hasSuffix("}") {
            return ParsedQualifierValue(
                text: String(rawValue.dropFirst().dropLast()),
                syntax: .identifier
            )
        }
        if rawValue.hasPrefix("\""), rawValue.hasSuffix("\"") {
            return ParsedQualifierValue(
                text: String(rawValue.dropFirst().dropLast()),
                syntax: .name
            )
        }
        return ParsedQualifierValue(text: rawValue, syntax: .automatic)
    }

    private static func existingDateRange(
        in tokens: [MeetingSearchToken]
    ) -> (startDate: Date?, endDate: Date?) {
        guard let token = tokens.first(where: { $0.id == MeetingSearchToken.dateRangeIdentifier }),
              case let .dateRange(startDate, endDate) = token.value else {
            return (nil, nil)
        }
        return (startDate, endDate)
    }

    private static func parsedQualifier(
        _ match: NSTextCheckingResult,
        in input: String,
        projects: [FlatProjectRow],
        tags: [TagRecord],
        calendar: Calendar,
        allowsTerminalUnquotedValue: Bool
    ) -> ParsedQualifier? {
        guard let tokenRange = Range(match.range(at: 1), in: input),
              let keyRange = Range(match.range(at: 2), in: input) else { return nil }
        let key = input[keyRange].lowercased()
        let rawValue = String(input[tokenRange].dropFirst(key.count + 1))
        let isTerminal = tokenRange.upperBound == input.endIndex
        let isExplicitlyClosed = rawValue.hasSuffix("}") || rawValue.hasSuffix("\"")
        guard allowsTerminalUnquotedValue || !isTerminal || isExplicitlyClosed else { return nil }

        let value = parsedValue(rawValue)
        let parsedValue: ParsedQualifier.Value? = switch key {
        case "project":
            resolveProject(value, projects: projects).map(ParsedQualifier.Value.token)
        case "tag":
            resolveTag(value, tags: tags).map(ParsedQualifier.Value.token)
        case "after":
            date(value.text, calendar: calendar).map(ParsedQualifier.Value.after)
        case "before":
            date(value.text, calendar: calendar).map(ParsedQualifier.Value.before)
        default:
            nil
        }
        return parsedValue.map { ParsedQualifier(range: tokenRange, value: $0) }
    }

    private static func removingConsumedRanges(
        _ ranges: [Range<String.Index>],
        from input: String
    ) -> String {
        guard !ranges.isEmpty else { return input }
        var remainingInput = input
        for range in ranges.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            remainingInput.replaceSubrange(range, with: "")
        }
        return remainingInput
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func resolveProject(
        _ value: ParsedQualifierValue,
        projects: [FlatProjectRow]
    ) -> MeetingSearchToken? {
        if value.syntax != .name,
           let id = UUID(uuidString: value.text),
           let project = projects.first(where: { $0.id == id }) {
            return MeetingSearchToken(value: .project(id: project.id, name: project.name))
        }
        guard value.syntax != .identifier else { return nil }

        let exactPathMatches = projects.filter {
            $0.name.caseInsensitiveCompare(value.text) == .orderedSame
        }
        if exactPathMatches.count == 1, let project = exactPathMatches.first {
            return MeetingSearchToken(value: .project(id: project.id, name: project.name))
        }

        let displayNameMatches = projects.filter {
            $0.displayName.caseInsensitiveCompare(value.text) == .orderedSame
        }
        guard displayNameMatches.count == 1, let project = displayNameMatches.first else { return nil }
        return MeetingSearchToken(value: .project(id: project.id, name: project.name))
    }

    private static func resolveTag(
        _ value: ParsedQualifierValue,
        tags: [TagRecord]
    ) -> MeetingSearchToken? {
        let tag: TagRecord? = switch value.syntax {
        case .identifier:
            Int64(value.text).flatMap { id in tags.first { $0.id == id } }
        case .name:
            uniquelyNamedTag(value.text, tags: tags)
        case .automatic:
            if let id = Int64(value.text),
               let identifiedTag = tags.first(where: { $0.id == id }) {
                identifiedTag
            } else {
                uniquelyNamedTag(value.text, tags: tags)
            }
        }
        guard let tag, let id = tag.id else { return nil }
        return MeetingSearchToken(value: .tag(id: id, name: tag.name, colorHex: tag.colorHex))
    }

    private static func uniquelyNamedTag(
        _ name: String,
        tags: [TagRecord]
    ) -> TagRecord? {
        if let exactMatch = tags.first(where: { $0.name == name }) {
            return exactMatch
        }
        let insensitiveMatches = tags.filter {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }
        guard insensitiveMatches.count == 1 else { return nil }
        return insensitiveMatches[0]
    }

    private static func date(_ value: String, calendar: Calendar) -> Date? {
        let components = value.split(separator: "-")
        guard components.count == 3,
              components[0].count == 4,
              components[1].count == 2,
              components[2].count == 2,
              let year = Int(components[0]),
              let month = Int(components[1]),
              let day = Int(components[2]) else { return nil }

        var gregorianCalendar = Calendar(identifier: .gregorian)
        gregorianCalendar.timeZone = calendar.timeZone
        let dateComponents = DateComponents(
            calendar: gregorianCalendar,
            timeZone: gregorianCalendar.timeZone,
            year: year,
            month: month,
            day: day
        )
        guard let date = gregorianCalendar.date(from: dateComponents) else { return nil }

        let resolved = gregorianCalendar.dateComponents([.year, .month, .day], from: date)
        guard resolved.year == year, resolved.month == month, resolved.day == day else { return nil }
        return date
    }
}

private struct ParsedQualifierValue {
    enum Syntax {
        case identifier
        case name
        case automatic
    }

    let text: String
    let syntax: Syntax
}

private struct ParsedQualifier {
    enum Value {
        case token(MeetingSearchToken)
        case after(Date)
        case before(Date)
    }

    let range: Range<String.Index>
    let value: Value
}
