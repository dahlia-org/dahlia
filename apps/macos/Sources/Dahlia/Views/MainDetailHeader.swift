import SwiftUI

struct MainDetailHeader<NavigationContent: View>: View {
    var reservesChatControl = true
    let leadingInset: CGFloat
    var notesEditorModel: DocumentEditorModel?
    var onShowNotesHistory: () -> Void = {}
    @ViewBuilder let navigationContent: NavigationContent

    var body: some View {
        DahliaWindowHeader {
            navigationContent
            if let notesEditorModel {
                DocumentEditorStatusView(model: notesEditorModel)
            }
            if notesEditorModel?.meetingID != nil {
                DahliaWindowHeaderIconButton(
                    label: L10n.documentRecoveryTitle,
                    systemImage: "clock.arrow.circlepath",
                    action: onShowNotesHistory
                )
            }
            if reservesChatControl {
                Color.clear
                    .frame(width: DahliaDesign.windowHeaderControlSize)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, leadingInset)
    }
}
