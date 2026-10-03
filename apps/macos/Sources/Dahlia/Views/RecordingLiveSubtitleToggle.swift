import SwiftUI

struct RecordingLiveSubtitleToggle: View {
    @Binding var isEnabled: Bool
    let selectedLanguageIdentifier: String
    let locales: [Locale]
    let onSelectLanguage: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.bubble")
                .font(.caption)
                .foregroundStyle(DahliaDesign.secondaryTextColor)
                .frame(width: 14)
                .accessibilityHidden(true)

            Text(L10n.subtitles)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(DahliaDesign.primaryTextColor)
                .frame(width: 58, alignment: .leading)
                .lineLimit(1)

            Menu {
                ForEach(locales, id: \.identifier) { locale in
                    let identifier = locale.identifier
                    Button {
                        onSelectLanguage(identifier)
                    } label: {
                        if identifier == selectedLanguageIdentifier {
                            Label(languageName(for: locale), systemImage: "checkmark")
                        } else {
                            Text(languageName(for: locale))
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(selectedLanguageName)
                        .font(.footnote)
                        .foregroundStyle(DahliaDesign.secondaryTextColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(DahliaDesign.optionalTextColor)
                }
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(L10n.liveSubtitleLanguage)
            .accessibilityValue(selectedLanguageName)
            .help(L10n.liveSubtitleLanguage)

            Toggle(L10n.liveSubtitles, isOn: $isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(L10n.liveSubtitles)
                .accessibilityValue(isEnabled ? L10n.liveSubtitlesOnStatus : L10n.liveSubtitlesOffStatus)
                .help(isEnabled ? L10n.hideLiveSubtitles : L10n.showLiveSubtitles)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DahliaDesign.Highlight.regularCornerRadius)
                .fill(Color.primary.opacity(0.06))
        )
    }

    private var selectedLanguageName: String {
        guard let locale = locales.first(where: { $0.identifier == selectedLanguageIdentifier }) else {
            return Locale.current.localizedString(forIdentifier: selectedLanguageIdentifier) ?? selectedLanguageIdentifier
        }
        return languageName(for: locale)
    }

    private func languageName(for locale: Locale) -> String {
        locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
}
