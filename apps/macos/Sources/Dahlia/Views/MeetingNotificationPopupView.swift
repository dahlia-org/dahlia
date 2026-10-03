import AppKit
import SwiftUI

struct MeetingNotificationPopupView: View {
    let popup: MeetingNotificationPopup
    let onAction: (MeetingNotificationPopup.Action) -> Void
    @State private var hoveredAction: MeetingNotificationPopup.Action?
    @State private var isCloseHovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 16) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)

                    Text(L10n.meetingNotification)
                        .font(.title)
                        .bold()
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text(popup.title)
                        .font(.largeTitle)
                        .bold()
                        .lineLimit(3)

                    if let subtitle = popup.subtitle {
                        Label(subtitle, systemImage: "calendar")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Text(popup.body)
                        .font(.title2)
                        .foregroundStyle(.secondary)

                    if let description = popup.calendarDescription {
                        Text(description)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                }

                HStack(spacing: 12) {
                    Spacer()

                    ForEach(popup.actions.filter { $0 != .close }) { action in
                        Button(action.title, systemImage: action.systemImage) {
                            onAction(action)
                        }
                        .buttonStyle(MeetingNotificationActionButtonStyle(
                            tint: action.isPrimary ? .red : .blue,
                            isHovered: hoveredAction == action
                        ))
                        .onHover { isHovered in
                            hoveredAction = isHovered ? action : nil
                        }
                    }
                }
            }
            .padding(36)

            Button(L10n.close, systemImage: MeetingNotificationPopup.Action.close.systemImage) {
                onAction(.close)
            }
            .labelStyle(.iconOnly)
            .font(.title2.bold())
            .frame(width: 44, height: 44)
            .background(Color.primary.opacity(isCloseHovered ? 0.16 : 0.08), in: Circle())
            .buttonStyle(.plain)
            .onHover { isCloseHovered = $0 }
            .padding(24)
        }
        .frame(width: MeetingNotificationPopupLayout.width)
        .frame(minHeight: MeetingNotificationPopupLayout.minimumHeight, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: MeetingNotificationPopupLayout.cornerRadius)
                .fill(.regularMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: MeetingNotificationPopupLayout.cornerRadius)
                .strokeBorder(.separator, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
}
