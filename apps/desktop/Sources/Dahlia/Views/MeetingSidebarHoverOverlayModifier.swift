import SwiftUI

private struct MeetingSidebarHoverOverlayModifier: ViewModifier {
    let isVisible: Bool
    let workspaceID: UUID?
    let canEditProject: Bool
    let onOpenProject: (UUID) -> Void
    let onEditProject: (UUID) -> Void
    let onToggleProjectPin: (UUID) -> Void

    @State private var controller: MeetingSidebarHoverController
    @State private var containerOrigin: CGPoint = .zero
    @State private var windowBounds: CGRect = .zero

    init(
        sidebarViewModel: SidebarViewModel,
        isVisible: Bool,
        onOpenProject: @escaping (UUID) -> Void,
        onEditProject: @escaping (UUID) -> Void,
        onToggleProjectPin: @escaping (UUID) -> Void
    ) {
        self.isVisible = isVisible
        self.onOpenProject = onOpenProject
        self.onEditProject = onEditProject
        self.onToggleProjectPin = onToggleProjectPin
        workspaceID = sidebarViewModel.currentWorkspace?.id
        canEditProject = sidebarViewModel.canEditCurrentWorkspace
        _controller = State(initialValue: MeetingSidebarHoverController { [weak sidebarViewModel] meetingID, workspaceID in
            await sidebarViewModel?.meetingDescription(id: meetingID, workspaceId: workspaceID)
        })
    }

    func body(content: Content) -> some View {
        content
            .environment(controller)
            .onGeometryChange(for: CGPoint.self) { geometry in
                geometry.frame(in: .global).origin
            } action: { origin in
                containerOrigin = origin
            }
            .onGeometryChange(for: CGRect.self) { geometry in
                geometry.frame(in: .local)
            } action: { bounds in
                windowBounds = bounds
            }
            .overlay {
                if isVisible {
                    MeetingSidebarHoverOverlay(
                        controller: controller,
                        containerOrigin: containerOrigin,
                        windowBounds: windowBounds,
                        canEditProject: canEditProject,
                        onOpenProject: onOpenProject,
                        onEditProject: onEditProject,
                        onToggleProjectPin: onToggleProjectPin
                    )
                }
            }
            .onChange(of: isVisible) { _, isVisible in
                if !isVisible {
                    controller.dismissAll()
                }
            }
            .onChange(of: workspaceID) {
                controller.dismissAll()
            }
    }
}

extension View {
    func meetingSidebarHoverOverlay(
        sidebarViewModel: SidebarViewModel,
        isVisible: Bool,
        onOpenProject: @escaping (UUID) -> Void,
        onEditProject: @escaping (UUID) -> Void,
        onToggleProjectPin: @escaping (UUID) -> Void
    ) -> some View {
        modifier(MeetingSidebarHoverOverlayModifier(
            sidebarViewModel: sidebarViewModel,
            isVisible: isVisible,
            onOpenProject: onOpenProject,
            onEditProject: onEditProject,
            onToggleProjectPin: onToggleProjectPin
        ))
    }
}
