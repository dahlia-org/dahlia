import SwiftUI

struct BatchTranscriptionInfoBanner: View {
    let message: String
    let systemImage: String
    let showsProgress: Bool
    let actionTitle: String?
    let isActionEnabled: Bool
    let onAction: () -> Void

    var body: some View {
        HStack {
            Label(message, systemImage: systemImage)
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
            if let actionTitle {
                Button(actionTitle, action: onAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isActionEnabled)
            }
        }
        .padding()
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, DahliaDesign.detailHorizontalPadding)
        .padding(.vertical, 4)
    }
}
