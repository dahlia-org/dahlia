import AppKit
import SwiftUI

@MainActor
final class MeetingSearchPasteMenuObserver: NSObject {
    private let onPaste: () -> Void

    init(onPaste: @escaping () -> Void) {
        self.onPaste = onPaste
    }

    @objc func menuWillSendAction(_ notification: Notification) {
        guard let menuItem = notification.userInfo?["MenuItem"] as? NSMenuItem,
              MeetingSidebarSearchModifier.isPasteAction(menuItem.action) else {
            return
        }
        onPaste()
    }
}

extension View {
    func meetingSidebarSearch(
        text: Binding<String>,
        tokens: Binding<[MeetingSearchToken]>,
        sidebarViewModel: SidebarViewModel,
        scopeProjectID: UUID? = nil
    ) -> some View {
        modifier(MeetingSidebarSearchModifier(
            searchText: text,
            searchTokens: tokens,
            sidebarViewModel: sidebarViewModel,
            scopeProjectID: scopeProjectID
        ))
    }
}

extension MeetingSidebarSearchModifier {
    nonisolated static func applyingProjectScope(
        _ scopeProjectID: UUID?,
        to criteria: MeetingSearchCriteria
    ) -> MeetingSearchCriteria {
        guard let scopeProjectID else { return criteria }
        var scopedCriteria = criteria
        scopedCriteria.projectIDs = [scopeProjectID]
        return scopedCriteria
    }

    nonisolated static func projectScopeIncludes(
        meetingProjectID: UUID?,
        scopeProjectID: UUID?
    ) -> Bool {
        scopeProjectID == nil || meetingProjectID == scopeProjectID
    }

    static func shouldDismissSearch(
        eventWindow: NSWindow,
        searchField: NSSearchField,
        clickLocationInWindow: NSPoint
    ) -> Bool {
        guard eventWindow === searchField.window else { return false }
        let locationInSearchField = searchField.convert(clickLocationInWindow, from: nil)
        return !searchField.bounds.contains(locationInSearchField)
    }

    nonisolated static func recentPeriodToken(
        days: Int,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> MeetingSearchToken {
        let today = calendar.startOfDay(for: now)
        let startDate = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        return MeetingSearchToken(value: .dateRange(startDate: startDate, endDate: nil))
    }

    nonisolated static func shouldUseTrailingQualifierMode(
        overrideText: String?,
        currentText: String
    ) -> Bool {
        overrideText != currentText
    }

    nonisolated static func shouldResolveTerminalQualifierAfterCatalogLoad(
        pendingText: String?,
        currentText: String
    ) -> Bool {
        pendingText == currentText
    }

    nonisolated static func isPasteAction(_ action: Selector?) -> Bool {
        guard let action else { return false }
        return switch NSStringFromSelector(action) {
        case "paste:", "pasteAsPlainText:", "pasteAsRichText:":
            true
        default:
            false
        }
    }

    enum SearchSuggestionMode {
        case overview
        case projects(String)
        case tags(String)
        case period
    }

    struct PasteCommandTracker {
        private var expectsTextChange = false

        mutating func recordPasteCommand() {
            expectsTextChange = true
        }

        mutating func cancel() {
            expectsTextChange = false
        }

        mutating func consumeNextTextChange() -> Bool {
            defer { expectsTextChange = false }
            return expectsTextChange
        }
    }

    struct TrailingSearchQualifier {
        private static let keys = ["project", "tag", "after", "before"]

        let key: String
        let range: Range<String.Index>
        let query: String

        static func find(in searchText: String) -> Self? {
            guard let qualifier = rightmostQualifier(in: searchText) else { return nil }

            let rawQuery = searchText[qualifier.range.upperBound...]
            guard isTrailingValue(rawQuery) else { return nil }
            return Self(
                key: qualifier.key,
                range: qualifier.range.lowerBound ..< searchText.endIndex,
                query: rawQuery.trimmingCharacters(in: CharacterSet(charactersIn: "\"{}"))
            )
        }

        static func removingUncommittedQualifier(
            from searchText: String,
            committedText: String?
        ) -> String {
            guard committedText != searchText, let qualifier = find(in: searchText) else {
                return searchText
            }
            var result = searchText
            result.removeSubrange(qualifier.range)
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private static func rightmostQualifier(
            in searchText: String
        ) -> (key: String, range: Range<String.Index>)? {
            var qualifier: (key: String, range: Range<String.Index>)?
            var index = searchText.startIndex

            while index < searchText.endIndex {
                let isQualifierBoundary = index == searchText.startIndex
                    || searchText[searchText.index(before: index)].isWhitespace
                guard isQualifierBoundary,
                      let match = qualifierMarker(in: searchText, at: index) else {
                    index = searchText.index(after: index)
                    continue
                }
                qualifier = match
                index = indexAfterWrappedValue(in: searchText, startingAt: match.range.upperBound)
            }
            return qualifier
        }

        private static func qualifierMarker(
            in searchText: String,
            at index: String.Index
        ) -> (key: String, range: Range<String.Index>)? {
            for key in keys {
                let marker = "\(key):"
                guard let upperBound = searchText.index(
                    index,
                    offsetBy: marker.count,
                    limitedBy: searchText.endIndex
                ) else { continue }
                let candidate = String(searchText[index ..< upperBound])
                if candidate.caseInsensitiveCompare(marker) == .orderedSame {
                    return (key, index ..< upperBound)
                }
            }
            return nil
        }

        private static func indexAfterWrappedValue(
            in searchText: String,
            startingAt valueStart: String.Index
        ) -> String.Index {
            guard valueStart < searchText.endIndex else { return valueStart }
            let terminator: Character? = switch searchText[valueStart] {
            case "\"": "\""
            case "{": "}"
            default: nil
            }
            guard let terminator else { return valueStart }
            let remainderStart = searchText.index(after: valueStart)
            guard let closingIndex = searchText[remainderStart...].firstIndex(of: terminator) else {
                return searchText.endIndex
            }
            return searchText.index(after: closingIndex)
        }

        private static func isTrailingValue(_ value: Substring) -> Bool {
            guard let first = value.first else { return true }
            let content = value.dropFirst()
            switch first {
            case "\"":
                return content.firstIndex(of: "\"") == value.index(before: value.endIndex)
                    || !content.contains("\"")
            case "{":
                return content.firstIndex(of: "}") == value.index(before: value.endIndex)
                    || !content.contains("}")
            default:
                return !value.contains(where: \.isWhitespace)
            }
        }
    }
}
