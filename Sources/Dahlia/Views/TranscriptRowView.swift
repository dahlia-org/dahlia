import SwiftUI

/// 議事録の1セグメントを表示する行ビュー。
struct TranscriptRowView: View, Equatable {
    let segment: TranscriptSegment
    let timestamp: String
    let showsTranslatedText: Bool
    let allowsTextSelection: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // タイムスタンプ
            Text(timestamp)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 56, alignment: .leading)

            // 話者ラベル
            if let speaker = segment.speakerLabel {
                Text(speakerDisplayName(for: speaker))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(speakerColor(for: speaker), in: Capsule())
                    .frame(width: 60, alignment: .center)
            }

            // テキスト
            VStack(alignment: .leading, spacing: 4) {
                Text(segment.displayText)
                    .font(.body)
                    .foregroundStyle(segment.isConfirmed ? .primary : .secondary)

                if let translatedText = segment.visibleTranslatedText(isEnabled: showsTranslatedText) {
                    Text(translatedText)
                        .font(.body)
                        .foregroundStyle(.blue)
                }
            }
            // 録音中は AppKit の選択範囲管理を作らず、連続更新・スクロール時の
            // MainActor 負荷を録音停止後へ先送りする。
            .modifier(ConditionalTextSelectionModifier(isEnabled: allowsTextSelection))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }

    private func speakerDisplayName(for label: String) -> String {
        switch label {
        case "mic": L10n.mic
        case "system": L10n.system
        default: label
        }
    }

    private func speakerColor(for label: String) -> Color {
        switch label {
        case "mic":
            return .blue
        case "system":
            return .orange
        default:
            let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .brown]
            let suffix = label.replacingOccurrences(of: "話者", with: "")
            let index: Int = switch suffix {
            case "A": 0
            case "B": 1
            case "C": 2
            case "D": 3
            case "E": 4
            case "F": 5
            case "G": 6
            case "H": 7
            default: (Int(suffix) ?? 1) - 1
            }
            return colors[index % colors.count]
        }
    }
}
