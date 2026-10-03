import SwiftUI

struct CodexChatAttachmentValidationView: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "info.circle")
            .font(.body)
            .foregroundStyle(DahliaDesign.secondaryTextColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }
}
