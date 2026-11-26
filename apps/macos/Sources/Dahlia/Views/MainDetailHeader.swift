import SwiftUI

struct MainDetailHeader<NavigationContent: View>: View {
    var reservesChatControl = true
    let leadingInset: CGFloat
    @ViewBuilder let navigationContent: NavigationContent

    var body: some View {
        DahliaWindowHeader {
            navigationContent
            if reservesChatControl {
                Color.clear
                    .frame(width: DahliaDesign.windowHeaderControlSize)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, leadingInset)
    }
}
