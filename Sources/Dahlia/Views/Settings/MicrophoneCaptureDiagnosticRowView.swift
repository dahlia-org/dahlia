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
                    .dahliaFont(.secondary, design: .monospaced)
                    .foregroundStyle(.secondary)
            }

            Text(details)
                .dahliaFont(.secondary, design: .monospaced)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}
