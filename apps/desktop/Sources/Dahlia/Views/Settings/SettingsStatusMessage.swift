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

#Preview("Connected") {
    SettingsStatusMessage(
        text: "接続を確認しました",
        systemImage: "checkmark.circle.fill",
        tint: .green
    )
    .padding()
    .frame(width: 360)
}

#Preview("Error details") {
    @Previewable @State var showsDetail = true

    VStack(alignment: .leading, spacing: 12) {
        SettingsStatusMessage(
            text: "接続できませんでした",
            detail: showsDetail ? "サーバーへの接続がタイムアウトしました。設定を確認して再試行してください。" : nil,
            systemImage: "exclamationmark.triangle.fill",
            tint: .orange
        )
        Toggle("詳細を表示", isOn: $showsDetail)
    }
    .padding()
    .frame(width: 360)
}
