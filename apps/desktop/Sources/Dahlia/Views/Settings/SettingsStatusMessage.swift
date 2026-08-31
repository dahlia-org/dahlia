import SwiftUI

/// 診断結果などの補足メッセージ。
struct SettingsStatusMessage: View {
    let text: String
    var detail: String?
    let systemImage: String
    let tint: Color

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(detail)
                }
            }
        } icon: {
            Image(systemName: systemImage)
        }
        .font(.body)
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
