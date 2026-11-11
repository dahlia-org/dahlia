import SwiftUI

struct MainSidebarUpcomingEventRow: View {
    let event: CalendarEvent
    let now: Date
    let isSelected: Bool
    let canStartRecording: Bool
    let isAutoRecordingEnabled: Bool
    let onSelect: () -> Void
    let onJoin: () -> Void
    let onOpenMeetingLink: () -> Void
    let onSetAutoRecording: (Bool) -> Void

    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverEnabled
    @Environment(\.openURL) private var openURL
    @Environment(DahliaWindowHeaderHelpController.self) private var helpController
    @State private var isHovered = false
    @State private var isJoinHovered = false
    @State private var isOptionsHovered = false
    @State private var optionsHelpID = UUID()
    @State private var optionsFrame: CGRect = .zero
    @FocusState private var focusedControl: Control?

    private enum Control: Hashable {
        case event, join, options
    }

    private var showsActions: Bool { isHovered || focusedControl != nil || isVoiceOverEnabled }

    var body: some View {
        ZStack {
            // Leave Join and options in front of a full-row native selection control.
            Button(action: onSelect) {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .focused($focusedControl, equals: .event)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Group {
                        if isAutoRecordingEnabled {
                            Image(systemName: "timer")
                        } else {
                            RoundedRectangle(cornerRadius: 2)
                                .frame(width: 8, height: 8)
                        }
                    }
                    .foregroundStyle(event.calendarColorHex.map(Color.init(hex:)) ?? Color.accentColor)
                    .frame(width: 12)
                    .accessibilityHidden(true)

                    Text(event.title)
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(.rect)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

                ZStack(alignment: .trailing) {
                    Text(timeText)
                        .font(.dahliaSecondary)
                        .monospacedDigit()
                        .foregroundStyle(DahliaDesign.sidebarSecondaryTextColor)
                        .lineLimit(1)
                        .opacity(showsActions ? 0 : 1)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)

                    HStack(spacing: 4) {
                        if event.conferenceURI != nil {
                            Button(action: onJoin) {
                                Text(L10n.join)
                                    .padding(.horizontal, 6)
                                    .frame(height: 24)
                                    .foregroundStyle(isJoinHovered && canStartRecording
                                        ? DahliaDesign.sidebarPrimaryTextColor
                                        : DahliaDesign.sidebarSecondaryTextColor)
                                    .background(
                                        isJoinHovered && canStartRecording ? DahliaDesign.sidebarHighlightColor : .clear,
                                        in: .rect(cornerRadius: DahliaDesign.Highlight.compactCornerRadius)
                                    )
                                    .contentShape(.rect(cornerRadius: DahliaDesign.Highlight.compactCornerRadius))
                            }
                            .buttonStyle(.plain)
                            .focused($focusedControl, equals: .join)
                            .disabled(!canStartRecording)
                            .onHover { isJoinHovered = $0 }
                            .help(L10n.joinAndStartRecording)
                            .accessibilityLabel(L10n.joinAndStartRecording)
                        }

                        Menu {
                            CalendarEventMenuContent(
                                event: event,
                                canJoinAndRecord: event.conferenceURI != nil && canStartRecording,
                                canJoin: event.conferenceURI != nil,
                                canShowInCalendar: event.url != nil,
                                isAutoRecordingEnabled: isAutoRecordingEnabled,
                                onJoinAndRecord: onJoin,
                                onJoin: onOpenMeetingLink,
                                onShowInCalendar: { if let url = event.url { openURL(url) } },
                                onSetAutoRecording: onSetAutoRecording
                            )
                        } label: {
                            Label(L10n.calendarEventOptions, systemImage: "ellipsis")
                                .labelStyle(.iconOnly)
                                .frame(width: 24, height: 24)
                                .foregroundStyle(isOptionsHovered ? DahliaDesign.sidebarPrimaryTextColor : DahliaDesign.sidebarSecondaryTextColor)
                                .background(
                                    isOptionsHovered ? DahliaDesign.sidebarHighlightColor : .clear,
                                    in: .rect(cornerRadius: DahliaDesign.Highlight.compactCornerRadius)
                                )
                                .contentShape(.rect(cornerRadius: DahliaDesign.Highlight.compactCornerRadius))
                        }
                        .focused($focusedControl, equals: .options)
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { optionsFrame = $0 }
                        .onHover(perform: updateOptionsHover)
                        .onDisappear { helpController.hoverEnded(for: optionsHelpID) }
                        .accessibilityHint(L10n.menuBarEventDetails)
                    }
                    .opacity(showsActions ? 1 : 0)
                    .allowsHitTesting(showsActions)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .modifier(SidebarNavigationRowModifier(isSelected: isSelected))
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
    }

    private func updateOptionsHover(_ isHovered: Bool) {
        isOptionsHovered = isHovered
        if isHovered {
            helpController.hoverBegan(
                for: optionsHelpID,
                label: L10n.menuBarEventDetails,
                shortcut: nil,
                buttonFrame: optionsFrame
            )
        } else {
            helpController.hoverEnded(for: optionsHelpID)
        }
    }

    private var accessibilityLabel: String {
        let autoRecording = isAutoRecordingEnabled ? ", \(L10n.calendarAutoRecordingScheduled)" : ""
        return "\(event.resolvedMeetingTitle), \(timeText)\(autoRecording)"
    }

    /// The day, relative to `now`, for any event not today, then the time ("All day" for all-day events).
    private var timeText: String {
        let calendar = Calendar.autoupdatingCurrent
        let start = event.startDate.formatted(date: .omitted, time: .shortened)
        // An event still in progress from an earlier day counts as today's, not as a past date.
        let day = max(event.startDate, calendar.startOfDay(for: now))
        let isToday = calendar.isDate(day, inSameDayAs: now)
        let time = if event.isAllDay {
            L10n.calendarAllDay
        } else if isToday {
            "\(start)–\(event.endDate.formatted(date: .omitted, time: .shortened))"
        } else {
            start
        }
        if isToday { return time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(day, inSameDayAs: tomorrow) {
            return "\(L10n.tomorrow) \(time)"
        }
        return "\(day.formatted(.dateTime.month(.defaultDigits).day())) \(time)"
    }
}
