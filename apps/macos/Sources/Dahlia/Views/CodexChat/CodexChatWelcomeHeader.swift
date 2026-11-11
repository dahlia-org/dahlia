import AppKit
import SwiftUI

struct CodexChatWelcomeHeader: View {
    let showsIcon: Bool

    var body: some View {
        VStack(spacing: 18) {
            if showsIcon {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
            }

            Text(L10n.chatWelcomeTitle)
                .font(.dahliaTitle.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(DahliaDesign.primaryTextColor)
                .accessibilityAddTraits(.isHeader)
        }
    }
}
