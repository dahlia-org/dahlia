import SwiftUI

struct MeetingSidebarRow: View {
    let item: MeetingSidebarItem
    let searchText: String
    let isSelected: Bool
    let isActiveRecording: Bool
    let isEditing: Bool
    @Binding var editingName: String
    @FocusState.Binding var isFocused: Bool
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void

    @State private var isHovered = false

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        HStack(spacing: 10) {
            statusIndicator

            VStack(alignment: .leading, spacing: 3) {
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

                HStack(spacing: 6) {
                    Text(startTimeText)
                        .monospacedDigit()
                        .fixedSize(horizontal: true, vertical: false)

                    Text(durationText)
                        .monospacedDigit()
                        .fixedSize(horizontal: true, vertical: false)

                    if let projectName {
                        ProjectPill(name: projectName, isSelected: isSelected)
                            .layoutPriority(-1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                if let matchContext = visibleMatchContext {
                    searchMatchRow(matchContext)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
        .padding(.horizontal, 5)
        .background {
            if isHovered {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(DahliaDesign.hoverHighlightColor)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if isActiveRecording {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
                .accessibilityLabel(L10n.recordingNow)
        } else {
            Image(systemName: item.calendarEventTitle == nil ? "waveform" : "calendar")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 12)
                .accessibilityHidden(true)
        }
    }

    private var projectName: String? {
        guard let projectName = item.projectName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !projectName.isEmpty else { return nil }
        return projectName
    }

    private var startTimeText: String {
        Self.timeFormatter.string(from: item.effectiveRecordingStartedAt)
    }

    private var durationText: String {
        guard let duration = item.duration else { return "00:00" }
        let totalSeconds = max(0, Int(duration.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var visibleMatchContext: MeetingSearchMatchContext? {
        guard !searchText.isEmpty,
              let context = item.searchMatchContext,
              context.kind != .title,
              context.kind != .project else { return nil }
        return context
    }

    private func searchMatchRow(_ context: MeetingSearchMatchContext) -> some View {
        HStack(spacing: 5) {
            if context.kind == .tag {
                Circle()
                    .fill(context.colorHex.map(Color.init(hex:)) ?? Color.secondary)
                    .frame(width: 6, height: 6)
            } else {
                Image(systemName: context.kind == .calendar ? "calendar" : "text.alignleft")
                    .frame(width: 8)
            }

            Text(matchContextPrefix(context.kind))
                .foregroundStyle(.tertiary)
            highlightedText(context.text)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
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

private struct ProjectPill: View {
    let name: String
    let isSelected: Bool

    var body: some View {
        Text(name)
            .font(.caption2.weight(.medium))
            .foregroundStyle(foregroundColor)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(backgroundColor, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(borderColor, lineWidth: 0.5)
            }
            .accessibilityLabel(name)
    }

    private var foregroundColor: Color {
        isSelected ? Color(nsColor: .controlAccentColor) : Color(nsColor: .secondaryLabelColor)
    }

    private var backgroundColor: Color {
        isSelected ? Color(nsColor: .controlBackgroundColor).opacity(0.95) : Color(nsColor: .secondaryLabelColor).opacity(0.10)
    }

    private var borderColor: Color {
        isSelected ? Color(nsColor: .controlAccentColor).opacity(0.24) : Color(nsColor: .secondaryLabelColor).opacity(0.16)
    }
}
