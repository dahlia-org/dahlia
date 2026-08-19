import SwiftUI

struct MeetingSidebarRow: View {
    let item: MeetingSidebarItem
    var contentLeadingPadding: CGFloat = 0
    var projectTint: Color?
    var projectAppearance: ProjectAppearance?
    var showsProjectChip = true
    let showsDateInTimestamp: Bool
    let searchText: String
    let isSelected: Bool
    let isActiveRecording: Bool
    let isEditing: Bool
    @Binding var editingName: String
    @FocusState.Binding var isFocused: Bool
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void

    @Environment(MeetingSidebarHoverController.self) private var hoverController
    @State private var isHovered = false
    @State private var hoverRowID = UUID()
    @State private var rowFrame: CGRect = .zero
    @AppStorage(AppSettings.meetingSidebarRowStyleUserDefaultsKey)
    private var rowStyleRawValue = MeetingSidebarRowStyle.standard.rawValue

    var body: some View {
        Group {
            if rowStyle == .standard {
                standardContent
            } else {
                compactContent
            }
        }
        .padding(.leading, contentLeadingPadding)
        .font(.body)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, DahliaDesign.sidebarRowVerticalPadding)
        .padding(.horizontal, 5)
        .dahliaSidebarHoverHighlight(
            isHovered: isHovered && !isSelected,
            isSelected: isSelected,
            verticalOutset: 2
        )
        .contentShape(Rectangle())
        .onGeometryChange(for: CGRect.self) { geometry in
            geometry.frame(in: .global)
        } action: { frame in
            rowFrame = frame
            hoverController.updateRowFrame(frame, for: item.meetingId, rowID: hoverRowID)
        }
        .onHover(perform: updateHoverState)
        .onDisappear { hoverController.meetingDisappeared(for: item.meetingId, rowID: hoverRowID) }
        .accessibilityLabel(accessibilityLabel)
    }

    private func updateHoverState(_ isHovered: Bool) {
        self.isHovered = isHovered
        if isHovered {
            hoverController.hoverBegan(
                item: item,
                isActiveRecording: isActiveRecording,
                projectAppearance: projectAppearance,
                rowFrame: rowFrame,
                rowID: hoverRowID
            )
        } else {
            hoverController.hoverEnded(for: item.meetingId, rowID: hoverRowID)
        }
    }

    private var rowStyle: MeetingSidebarRowStyle {
        MeetingSidebarRowStyle.resolved(rawValue: rowStyleRawValue)
    }

    private var compactContent: some View {
        HStack(spacing: 10) {
            titleContent

            if isActiveRecording {
                recordingIndicator
            } else {
                MeetingTimestampBadge(text: timestampText)
            }
        }
    }

    private var standardContent: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                titleContent

                if isActiveRecording {
                    recordingIndicator
                }
            }

            HStack(spacing: 6) {
                Text(timestampText)
                    .font(.caption2.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(DahliaDesign.sidebarSecondaryTextColor)

                if showsProjectChip, let projectName = item.projectName?.nilIfBlank {
                    Text(projectName)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(DahliaDesign.sidebarSecondaryTextColor)
                        .lineLimit(1)
                        .dahliaChipSurface(tint: projectTint)
                }
            }
        }
    }

    private var titleContent: some View {
        Group {
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
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recordingIndicator: some View {
        Circle()
            .fill(.red)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }

    private var timestampText: String {
        if showsDateInTimestamp {
            return Self.projectTimestamp(for: item.effectiveRecordingStartedAt)
        }
        return item.effectiveRecordingStartedAt.formatted(date: .omitted, time: .shortened)
    }

    static func projectTimestamp(for date: Date, timeZone: TimeZone = .current) -> String {
        let format: Date.FormatString = """
        \(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \
        \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)
        """
        return date.formatted(
            Date.VerbatimFormatStyle(
                format: format,
                locale: Locale(identifier: "en_US_POSIX"),
                timeZone: timeZone,
                calendar: Calendar(identifier: .gregorian)
            )
        )
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
        }
        components.append(timestampText)
        if let projectName = item.projectName?.nilIfBlank {
            components.append(projectName)
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
            .font(.caption2.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(DahliaDesign.sidebarSecondaryTextColor)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .accessibilityHidden(true)
    }
}
