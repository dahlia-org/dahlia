import SwiftUI

/// 診断結果などの補足メッセージ。
struct SettingsStatusMessage: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
