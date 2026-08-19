import SwiftUI

struct MeetingSidebarHoverOverlay: View {
    static let spacing: CGFloat = 9
    static let windowInset: CGFloat = 8

    let controller: MeetingSidebarHoverController
    let containerOrigin: CGPoint
    let windowBounds: CGRect
    let onEditProject: (UUID) -> Void
    let onToggleProjectPin: (UUID) -> Void

    @State private var meetingCardSize: CGSize = .zero
    @State private var projectCardSize: CGSize = .zero
    @AppStorage(AppSettings.meetingSidebarRowStyleUserDefaultsKey)
    private var rowStyleRawValue = MeetingSidebarRowStyle.standard.rawValue

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let item = controller.visibleItem {
                MeetingSidebarHoverCard(
                    item: item,
                    description: controller.visibleDescription,
                    isActiveRecording: controller.visibleIsActiveRecording,
                    projectAppearance: controller.visibleMeetingProjectAppearance
                )
                .onGeometryChange(for: CGSize.self) { geometry in
                    geometry.size
                } action: { size in
                    meetingCardSize = size
                }
                .padding(.leading, Self.spacing)
                .contentShape(.rect)
                .offset(x: meetingCardOrigin.x - Self.spacing, y: meetingCardOrigin.y)
                .opacity(meetingCardSize == .zero ? 0 : 1)
                .onHover(perform: controller.meetingCardHoverChanged)
            }

            if let project = controller.visibleProject {
                ProjectSidebarHoverCard(
                    project: project,
                    appearance: controller.visibleProjectAppearance,
                    isPinned: controller.visibleProjectIsPinned,
                    onTogglePin: {
                        controller.dismissAll()
                        onToggleProjectPin(project.projectId)
                    },
                    onEdit: {
                        controller.dismissAll()
                        onEditProject(project.projectId)
                    }
                )
                .onGeometryChange(for: CGSize.self) { geometry in
                    geometry.size
                } action: { size in
                    projectCardSize = size
                }
                .padding(.leading, Self.spacing)
                .contentShape(.rect)
                .offset(x: projectCardOrigin.x - Self.spacing, y: projectCardOrigin.y)
                .opacity(projectCardSize == .zero ? 0 : 1)
                .onHover(perform: controller.projectCardHoverChanged)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var meetingCardOrigin: CGPoint {
        Self.origin(
            rowFrame: controller.visibleRowFrame,
            cardSize: meetingCardSize,
            containerOrigin: containerOrigin,
            windowBounds: windowBounds,
            rowHighlightVerticalOutset: DahliaDesign.meetingSidebarRowHighlightVerticalOutset(for: rowStyle)
        )
    }

    private var projectCardOrigin: CGPoint {
        Self.origin(
            rowFrame: controller.visibleRowFrame,
            cardSize: projectCardSize,
            containerOrigin: containerOrigin,
            windowBounds: windowBounds,
            rowHighlightVerticalOutset: DahliaDesign.projectSidebarRowHighlightVerticalOutset
        )
    }

    static func origin(
        rowFrame: CGRect,
        cardSize: CGSize,
        containerOrigin: CGPoint,
        windowBounds: CGRect,
        rowHighlightVerticalOutset: CGFloat = DahliaDesign.meetingSidebarRowHighlightVerticalOutset(for: .standard)
    ) -> CGPoint {
        let localRowFrame = rowFrame.offsetBy(dx: -containerOrigin.x, dy: -containerOrigin.y)
        let preferredOrigin = CGPoint(
            x: localRowFrame.maxX + spacing,
            y: localRowFrame.minY - rowHighlightVerticalOutset
        )
        return CGPoint(
            x: constrained(
                preferredOrigin.x,
                length: cardSize.width,
                minimum: windowBounds.minX + windowInset,
                maximum: windowBounds.maxX - windowInset
            ),
            y: constrained(
                preferredOrigin.y,
                length: cardSize.height,
                minimum: windowBounds.minY + windowInset,
                maximum: windowBounds.maxY - windowInset
            )
        )
    }

    private static func constrained(
        _ origin: CGFloat,
        length: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat
    ) -> CGFloat {
        guard length <= maximum - minimum else {
            return minimum + (maximum - minimum - length) / 2
        }
        return min(max(origin, minimum), maximum - length)
    }

    private var rowStyle: MeetingSidebarRowStyle {
        MeetingSidebarRowStyle.resolved(rawValue: rowStyleRawValue)
    }
}
