import Speech
import SwiftUI

/// 設定画面「文字起こし」タブ。認識言語の表示フィルタを管理する。
struct TranscriptionSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var supportedLocales: [Locale] = []
    @State private var isLoadingLocales = false
    @State private var localeSearchText = ""

    private static let automaticScreenshotIntervals = [15, 30, 60, 120]

    var body: some View {
        SettingsPage {
            SettingsSection(title: L10n.transcriptTranslation) {
                SettingsCard {
                    VStack(spacing: 0) {
                        SettingsToggleRow(
                            title: L10n.transcriptTranslation,
                            description: L10n.transcriptTranslationDescription,
                            isOn: $settings.transcriptTranslationEnabled
                        )

                        Divider()

                        SettingsControlRow(
                            title: L10n.translationTargetLanguage,
                            description: L10n.translationTargetLanguageDescription
                        ) {
                            Picker(L10n.translationTargetLanguage, selection: $settings.transcriptTranslationTargetLanguage) {
                                ForEach(targetLanguageOptions) { option in
                                    Text(option.displayName).tag(option.identifier)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 220, alignment: .trailing)
                        }

                        if !settings.isTranscriptTranslationEffectivelyEnabled, settings.transcriptTranslationEnabled {
                            Divider()

                            SettingsStatusMessage(
                                text: L10n.translationDisabledForMatchingLanguage,
                                systemImage: "info.circle",
                                tint: .secondary
                            )
                            .padding(20)
                        }
                    }
                }
            }

            SettingsSection(
                title: L10n.liveSubtitleOverlay,
                description: L10n.liveSubtitleOverlayDescription
            ) {
                SettingsCard {
                    VStack(spacing: 0) {
                        SettingsControlRow(
                            title: L10n.source,
                            description: L10n.liveSubtitleSourceDescription
                        ) {
                            Picker(L10n.source, selection: $settings.liveSubtitleSourceModeRawValue) {
                                ForEach(LiveSubtitleSourceMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode.rawValue)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 220, alignment: .trailing)
                        }

                        Divider()

                        SettingsControlRow(
                            title: L10n.liveSubtitleOverlaySegmentCount,
                            description: L10n.liveSubtitleOverlaySegmentCountDescription
                        ) {
                            Picker(L10n.liveSubtitleOverlaySegmentCount, selection: $settings.liveSubtitleOverlaySegmentCount) {
                                ForEach(1 ..< 6, id: \.self) { count in
                                    Text("\(count)").tag(count)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 120, alignment: .trailing)
                        }
                    }
                }
            }

            SettingsSection(
                title: L10n.screen,
                description: L10n.automaticScreenshotsDescription
            ) {
                SettingsCard {
                    VStack(spacing: 0) {
                        SettingsToggleRow(
                            title: L10n.automaticScreenshots,
                            description: L10n.automaticScreenshotsToggleDescription,
                            isOn: $settings.automaticScreenshotEnabled
                        )

                        Divider()

                        SettingsControlRow(
                            title: L10n.screenshotInterval,
                            description: L10n.screenshotIntervalDescription
                        ) {
                            Picker(L10n.screenshotInterval, selection: $settings.automaticScreenshotIntervalSeconds) {
                                ForEach(Self.automaticScreenshotIntervals, id: \.self) { interval in
                                    Text(L10n.seconds(interval)).tag(interval)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 120, alignment: .trailing)
                            .disabled(!settings.automaticScreenshotEnabled)
                        }
                    }
                }
            }

            SettingsSection(
                title: L10n.displayLanguages,
                description: L10n.displayLanguagesDescription
            ) {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 16) {
                        TextField(L10n.searchLanguages, text: $localeSearchText)
                            .textFieldStyle(.roundedBorder)

                        if isLoadingLocales {
                            ProgressView(L10n.loadingLanguages)
                        } else {
                            localeSelectionList
                            localeSelectionFooter
                        }
                    }
                    .padding(20)
                }
            }
        }
        .task {
            await loadSupportedLocales()
        }
    }

    // MARK: - Private

    @ViewBuilder
    private var localeSelectionList: some View {
        let searchedLocales = searchFilteredLocales
        if searchedLocales.isEmpty {
            Text(L10n.noMatchingLanguages)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(searchedLocales, id: \.identifier) { locale in
                        localeRow(for: locale)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 220, maxHeight: 280)
        }
    }

    private var localeSelectionFooter: some View {
        HStack(alignment: .center, spacing: 12) {
            let enabled = settings.enabledLocaleIdentifiers
            Text(
                enabled.isEmpty
                    ? L10n.allLanguagesShown
                    : L10n.languagesSelected(enabled.count)
            )
            .font(.callout)
            .foregroundStyle(.secondary)

            Spacer()

            if !enabled.isEmpty {
                Button(L10n.uncheckAll) {
                    settings.enabledLocaleIdentifiers = []
                }
            }

            if enabled.count != supportedLocales.count {
                Button(L10n.showAll) {
                    settings.enabledLocaleIdentifiers = Set(supportedLocales.map(\.identifier))
                }
            }
        }
    }

    private var targetLanguageOptions: [TranscriptTranslationLanguageOption] {
        let displayLocale = settings.appLanguage.locale
        let options = TranscriptTranslationLanguage.availableTargetLanguages(
            from: supportedLocales,
            locale: displayLocale
        )
        if options.contains(where: { $0.identifier == settings.transcriptTranslationTargetLanguage }) {
            return options
        }

        return options + [
            TranscriptTranslationLanguageOption(
                identifier: settings.transcriptTranslationTargetLanguage,
                displayName: TranscriptTranslationLanguage.displayName(
                    for: settings.transcriptTranslationTargetLanguage,
                    locale: displayLocale
                )
            ),
        ]
    }

    private var searchFilteredLocales: [Locale] {
        guard !localeSearchText.isEmpty else { return supportedLocales }
        let query = localeSearchText.lowercased()
        return supportedLocales.filter { locale in
            let name = locale.localizedString(forIdentifier: locale.identifier) ?? ""
            return name.lowercased().contains(query)
                || locale.identifier.lowercased().contains(query)
        }
    }

    private func toggleLocale(_ identifier: String) {
        var enabled = settings.enabledLocaleIdentifiers
        if enabled.isEmpty {
            enabled = Set(supportedLocales.map(\.identifier))
            enabled.remove(identifier)
        } else if enabled.contains(identifier) {
            enabled.remove(identifier)
            if enabled.isEmpty { /* そのまま空セットでOK */ }
        } else {
            enabled.insert(identifier)
        }
        settings.enabledLocaleIdentifiers = enabled
    }

    private func localeRow(for locale: Locale) -> some View {
        let identifier = locale.identifier
        let isEnabled = settings.isLocaleEnabled(identifier)
        return Button {
            toggleLocale(identifier)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isEnabled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)

                Text(locale.localizedString(forIdentifier: identifier) ?? identifier)
                    .foregroundStyle(.primary)

                Spacer(minLength: 12)

                Text(identifier)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isEnabled ? Color.accentColor.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func loadSupportedLocales() async {
        isLoadingLocales = true
        let locales = await SpeechTranscriber.supportedLocales
        supportedLocales = locales.sortedByLocalizedName()
        isLoadingLocales = false
    }
}
