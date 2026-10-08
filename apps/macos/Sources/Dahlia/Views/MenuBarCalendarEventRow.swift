import SwiftUI

struct MenuBarCalendarEventRow: View {
    let event: CalendarEvent
    let now: Date
    let canJoinAndRecord: Bool
    let canJoin: Bool
    let canShowInCalendar: Bool
    let isAutoRecordingEnabled: Bool
    let onJoinAndRecord: () -> Void
    let onJoin: () -> Void
    let onShowInCalendar: () -> Void
    let onSetAutoRecording: (Bool) -> Void

    var body: some View {
        Group {
            if canJoin {
                Menu(content: menuContent, label: menuLabel, primaryAction: canJoinAndRecord ? onJoinAndRecord : onJoin)
            } else {
                Menu(content: menuContent, label: menuLabel)
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private func menuContent() -> some View {
        detailLabel(detailTimeText, systemImage: "clock")

        if let location = event.location {
            detailLabel(location, systemImage: "mappin.and.ellipse")
        }

        ForEach(event.meetingRoomNames, id: \.self) { roomName in
            detailLabel(roomName, systemImage: "door.left.hand.closed")
        }

        if let descriptionText = Self.descriptionText(event.description) {
            // メニュー項目のタイトルは改行を潰すため、複数行を表示できるサブタイトルに入れる。
            Button {} label: {
                Label(L10n.menuBarEventDetails, systemImage: "text.alignleft")
                Text(descriptionText)
            }
            .disabled(true)
        }

        Divider()

        if !event.isAllDay {
            Toggle(L10n.calendarAutoRecording, systemImage: "timer", isOn: autoRecordingBinding)

            Divider()
        }

        Button(L10n.menuBarJoinMeetingWithRecording, systemImage: "record.circle", action: onJoinAndRecord)
            .disabled(!canJoinAndRecord)

        Button(L10n.menuBarJoinMeeting, systemImage: "video.fill", action: onJoin)
            .disabled(!canJoin)

        Divider()

        Button(L10n.menuBarShowEventInCalendar, systemImage: "calendar", action: onShowInCalendar)
            .disabled(!canShowInCalendar)
    }

    private func menuLabel() -> some View {
        Label {
            HStack {
                Text(menuTitle)

                if isAutoRecordingEnabled {
                    Image(systemName: "timer")
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(event.isAttending ? DahliaDesign.primaryTextColor : DahliaDesign.secondaryTextColor)
        } icon: {
            MenuBarCalendarParticipationIndicator(isAttending: event.isAttending)
        }
    }

    private func detailLabel(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .disabled(true)
    }

    private var isOngoing: Bool {
        !event.isAllDay && event.startDate <= now && event.endDate > now
    }

    private var menuTitle: String {
        let progress = isOngoing ? " · \(L10n.menuBarInProgress)" : ""
        return "\(timeText)  \(event.resolvedMeetingTitle)\(progress)"
    }

    private var accessibilityLabel: String {
        let participation = event.isAttending ? ", \(L10n.calendarAttending)" : ""
        let autoRecording = isAutoRecordingEnabled ? ", \(L10n.calendarAutoRecordingScheduled)" : ""
        return "\(event.resolvedMeetingTitle), \(timeText), \(event.calendarName)\(participation)\(autoRecording)"
    }

    private var autoRecordingBinding: Binding<Bool> {
        Binding(
            get: { isAutoRecordingEnabled },
            set: { isEnabled in onSetAutoRecording(isEnabled) }
        )
    }

    private var detailTimeText: String {
        guard !event.isAllDay else { return L10n.calendarAllDay }
        let isSameDay = Calendar.autoupdatingCurrent.isDate(event.startDate, inSameDayAs: event.endDate)
        return (event.startDate ..< event.endDate).formatted(date: isSameDay ? .omitted : .abbreviated, time: .shortened)
    }

    /// メニューは長い行を折り返さず幅を広げるため、表示幅で改行し行数も制限する。
    static func descriptionText(_ description: String, maxWidth: Int = 56, maxLines: Int = 12) -> String? {
        var source = String(description.prefix(4000))
        // 上限で切れたタグの断片を表示しない。
        if description.count > source.count, let tagStart = source.lastIndex(of: "<"), !source[tagStart...].contains(">") {
            source.removeSubrange(tagStart...)
        }
        // `<` の直後が英字のものだけをタグとみなし、プレーンテキストの `a < b` は残す。
        let plainText = source
            .replacingOccurrences(of: "<br\\s*/?>|</(p|div|li|tr|h[1-6])>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "</?[a-z][^>]*>", with: " ", options: [.regularExpression, .caseInsensitive])
            .replacing("&nbsp;", with: " ")
            .replacing("&lt;", with: "<")
            .replacing("&gt;", with: ">")
            .replacing("&quot;", with: "\"")
            .replacing("&#39;", with: "'")
            .replacing("&amp;", with: "&")
        let lines = plainText
            .split(whereSeparator: \.isNewline)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .flatMap { wrapped($0, maxWidth: maxWidth) }
        guard !lines.isEmpty else { return nil }
        let text = lines.prefix(maxLines).joined(separator: "\n")
        return lines.count > maxLines ? text + "…" : text
    }

    private static func wrapped(_ line: String, maxWidth: Int) -> [String] {
        var result: [String] = []
        var current = ""
        var currentWidth = 0
        for word in line.split(separator: " ") {
            let wordWidth = word.reduce(0) { $0 + displayWidth($1) }
            if !current.isEmpty, currentWidth + 1 + wordWidth <= maxWidth {
                current += " \(word)"
                currentWidth += 1 + wordWidth
                continue
            }
            if !current.isEmpty {
                result.append(current)
            }
            current = ""
            currentWidth = 0
            for character in word {
                let width = displayWidth(character)
                if currentWidth + width > maxWidth {
                    result.append(current)
                    current = ""
                    currentWidth = 0
                }
                current.append(character)
                currentWidth += width
            }
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    // ponytail: CJK・かな・全角・絵文字を幅 2 とみなす近似。表示崩れが目立つならフォント計測に置き換える。
    private static func displayWidth(_ character: Character) -> Int {
        (character.unicodeScalars.first?.value ?? 0) >= 0x2E80 ? 2 : 1
    }

    private var timeText: String {
        if event.isAllDay {
            L10n.calendarAllDay
        } else {
            event.startDate.formatted(date: .omitted, time: .shortened)
        }
    }
}
