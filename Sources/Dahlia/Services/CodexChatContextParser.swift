import Foundation

struct CodexChatContextParser {
    private let text: String
    private var index: String.Index

    init(_ text: String) {
        self.text = text
        index = text.startIndex
    }

    var isAtEnd: Bool {
        index == text.endIndex
    }

    mutating func consume(_ expected: String) -> Bool {
        guard text[index...].hasPrefix(expected) else { return false }
        index = text.index(index, offsetBy: expected.count)
        return true
    }

    mutating func consumeElement(name: String, indentation: Int) -> String? {
        let spaces = String(repeating: " ", count: indentation)
        let opening = "\(spaces)<\(name)>"
        let closing = "</\(name)>\n"
        guard consume(opening),
              let closingRange = text[index...].range(of: closing) else { return nil }
        let encoded = String(text[index ..< closingRange.lowerBound])
        index = closingRange.upperBound
        return CodexChatPromptCodec.unescape(encoded)
    }

    mutating func consumeCalendarEvent() -> (
        isValid: Bool,
        context: CodexChatCalendarEventContext?
    ) {
        if consume("\n") {
            guard consume("  <calendar_event>\n") else { return (false, nil) }
            let icalUID: String?
            if text[index...].hasPrefix("    <ical_uid>") {
                guard let value = consumeElement(name: "ical_uid", indentation: 4) else {
                    return (false, nil)
                }
                icalUID = value.nilIfBlank
            } else {
                icalUID = nil
            }
            guard let title = consumeElement(name: "title", indentation: 4),
                  let description = consumeElement(name: "description", indentation: 4),
                  let startText = consumeElement(name: "start", indentation: 4),
                  let start = CodexChatPromptCodec.parseDate(startText),
                  let endText = consumeElement(name: "end", indentation: 4),
                  let end = CodexChatPromptCodec.parseDate(endText),
                  consume("  </calendar_event>\n")
            else { return (false, nil) }
            let context = CodexChatCalendarEventContext(
                icalUID: icalUID,
                title: title,
                description: description,
                start: start,
                end: end
            )
            return (true, context)
        }
        return (true, nil)
    }
}
