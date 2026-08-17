import SwiftUI

struct MeetingSidebarRow: View {
    let item: MeetingSidebarItem
    var contentLeadingPadding: CGFloat = 0
    let showsDateInTimestamp: Bool
    let searchText: String
    let isSelected: Bool
    var usesNativeSelectionHighlight = true
    let isActiveRecording: Bool
    let isEditing: Bool
    @Binding var editingName: String
    @FocusState.Binding var isFocused: Bool
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            if isEditing {
                TextField(L10n.title, text: $editingName)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onSubmit(onCommitRename)
                    .onExitCommand(perform: onCancelRename)
            } else {
                MeetingTitleMarquee(
                    isHovered: isHovered,
                    title: highlightedText(item.displayTitle)
                )
                .font(DahliaDesign.sidebarFont)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if isActiveRecording {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            } else {
                MeetingTimestampBadge(text: timestampText)
            }
        }
        .padding(.leading, contentLeadingPadding)
        .font(DahliaDesign.sidebarFont)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, DahliaDesign.sidebarRowVerticalPadding)
        .padding(.horizontal, 5)
        .dahliaSidebarHoverHighlight(
            isHovered: isHovered && !isSelected,
            isSelected: isSelected && !usesNativeSelectionHighlight
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .accessibilityLabel(accessibilityLabel)
    }

    private var timestampText: String {
        if showsDateInTimestamp {
            return item.effectiveRecordingStartedAt.formatted(
                Date.VerbatimFormatStyle(
                    format: "\(month: .defaultDigits)/\(day: .defaultDigits)",
                    locale: Locale(identifier: "en_US_POSIX"),
                    timeZone: .current,
                    calendar: .current
                )
            )
        }
        return item.effectiveRecordingStartedAt.formatted(date: .omitted, time: .shortened)
    }

    private func matchContextPrefix(_ kind: MeetingSearchMatchContext.Kind) -> String {
        switch kind {
        case .description:
            L10n.descriptionMatch
        case .calendar:
            L10n.calendarMatch
        case .tag:
            L10n.tagMatch
        case .project:
            L10n.projectMatch
        case .title:
            ""
        }
    }

    private func highlightedText(_ text: String) -> Text {
        guard !searchText.isEmpty,
              let range = text.range(
                  of: searchText,
                  options: [.caseInsensitive, .diacriticInsensitive],
                  locale: .current
              ) else {
            return Text(text)
        }
        let prefix = Text(verbatim: String(text[..<range.lowerBound]))
        let match = Text(verbatim: String(text[range])).bold().foregroundStyle(Color.accentColor)
        let suffix = Text(verbatim: String(text[range.upperBound...]))
        return Text("\(prefix)\(match)\(suffix)")
    }

    private var accessibilityLabel: String {
        var components = [item.displayTitle]
        if isActiveRecording {
            components.append(L10n.recordingNow)
        } else {
            components.append(timestampText)
        }
        if let calendarEventTitle = item.calendarEventTitle {
            components.append(L10n.calendarEventOrigin(calendarEventTitle.nilIfBlank ?? L10n.newMeeting))
        }
        if !searchText.isEmpty,
           let matchContext = item.searchMatchContext,
           matchContext.kind != .title {
            components.append("\(matchContextPrefix(matchContext.kind)) \(matchContext.text)")
        }
        return components.joined(separator: ", ")
    }
}

private struct MeetingTimestampBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .accessibilityHidden(true)
    }
}
