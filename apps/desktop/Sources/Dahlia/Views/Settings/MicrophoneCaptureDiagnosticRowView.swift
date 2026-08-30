import SwiftUI

struct MicrophoneCaptureDiagnosticRowView: View {
    let title: String
    let timestamp: String
    let details: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer()
                Text(timestamp)
                    .font(.footnote.monospaced())
                    .foregroundStyle(DahliaDesign.secondaryTextColor)
            }

            Text(details)
                .font(.footnote.monospaced())
                .foregroundStyle(DahliaDesign.secondaryTextColor)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}
