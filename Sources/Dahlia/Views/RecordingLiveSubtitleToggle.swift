import SwiftUI

struct RecordingLiveSubtitleToggle: View {
    @Binding var isEnabled: Bool

    var body: some View {
        Toggle(isOn: $isEnabled) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                    .accessibilityHidden(true)

                Text(L10n.subtitles)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 58, alignment: .leading)
                    .lineLimit(1)

                Text(isEnabled ? L10n.liveSubtitlesOnStatus : L10n.liveSubtitlesOffStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.06))
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(L10n.liveSubtitles)
        .accessibilityValue(isEnabled ? L10n.liveSubtitlesOnStatus : L10n.liveSubtitlesOffStatus)
        .help(isEnabled ? L10n.hideLiveSubtitles : L10n.showLiveSubtitles)
    }
}
