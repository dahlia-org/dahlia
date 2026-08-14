import SwiftUI

struct MainSearchOverlay: View {
    @Bindable var model: MainSearchModel
    var sidebarViewModel: SidebarViewModel
    let onOpenMeeting: (UUID) -> Void
    let onOpenProject: (UUID) -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Button(L10n.closeSearch, action: model.dismiss)
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(.rect)
                    .background(.black.opacity(0.12))
                    .accessibilityHidden(true)

                MainSearchPanel(
                    model: model,
                    sidebarViewModel: sidebarViewModel,
                    panelWidth: min(MainSearchDesign.panelWidth, max(geometry.size.width - 32, 0)),
                    onDismiss: model.dismiss,
                    onOpenMeeting: { id in
                        model.dismiss()
                        onOpenMeeting(id)
                    },
                    onOpenProject: { id in
                        model.dismiss()
                        onOpenProject(id)
                    }
                )
            }
        }
        .ignoresSafeArea()
    }
}
