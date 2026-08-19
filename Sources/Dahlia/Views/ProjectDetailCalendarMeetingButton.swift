import SwiftUI

struct ProjectDetailCalendarMeetingButton: View {
    let item: MeetingSidebarItem
    let projectAppearance: ProjectAppearance?
    let onOpen: () -> Void

    @Environment(MeetingSidebarHoverController.self) private var hoverController
    @State private var hoverRowID = UUID.v7()
    @State private var rowFrame: CGRect = .zero

    var body: some View {
        Button(action: onOpen) {
            Text(item.displayTitle)
                .font(.caption2)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
        .onGeometryChange(for: CGRect.self) { geometry in
            geometry.frame(in: .global)
        } action: { frame in
            rowFrame = frame
            hoverController.updateRowFrame(frame, for: item.meetingId, rowID: hoverRowID)
        }
        .onHover(perform: updateHoverState)
        .onDisappear {
            hoverController.meetingDisappeared(for: item.meetingId, rowID: hoverRowID)
        }
    }

    private func updateHoverState(_ isHovered: Bool) {
        if isHovered {
            hoverController.hoverBegan(
                item: item,
                isActiveRecording: false,
                projectAppearance: projectAppearance,
                rowFrame: rowFrame,
                rowID: hoverRowID
            )
        } else {
            hoverController.hoverEnded(for: item.meetingId, rowID: hoverRowID)
        }
    }
}
