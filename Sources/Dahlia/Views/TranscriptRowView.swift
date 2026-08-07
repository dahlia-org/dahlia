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

            speakerLabels
                .frame(width: 120, alignment: .leading)

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

    private var speakerLabels: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(primarySpeakerName)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .foregroundStyle(primarySpeakerColor)
                .background(primarySpeakerColor.opacity(0.16), in: Capsule())
                .overlay {
                    Capsule().stroke(primarySpeakerColor.opacity(0.6))
                }
                .help(primarySpeakerName)

            if let sourceLabel {
                Label(sourceLabel.name, systemImage: sourceLabel.systemImage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var primarySpeakerName: String {
        guard let identity = segment.speakerIdentity else { return L10n.unknownSpeaker }
        if let assignedContactName = identity.assignedContactName {
            return assignedContactName
        }
        if let referenceContactName = identity.referenceContactName {
            return L10n.referenceSpeakerCandidate(referenceContactName)
        }
        return L10n.meetingSpeaker(identity.ordinal)
    }

    private var primarySpeakerColor: Color {
        guard let identity = segment.speakerIdentity else { return .secondary }
        let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .brown]
        return colors[identity.stableColorIndex]
    }

    private var sourceLabel: (name: String, systemImage: String)? {
        switch segment.speakerLabel {
        case "mic":
            (L10n.mic, "mic.fill")
        case "system":
            (L10n.system, "desktopcomputer")
        default:
            nil
        }
    }
}
