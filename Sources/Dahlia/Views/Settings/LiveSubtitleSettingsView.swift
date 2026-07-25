import SwiftUI

struct LiveSubtitleSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.liveSubtitleOverlayEnabled) {
                    Text(L10n.liveSubtitles)
                    Text(L10n.liveSubtitleOverlayToggleDescription)
                }
                .toggleStyle(.switch)
            } footer: {
                Text(L10n.liveSubtitleOverlayDescription)
            }

            Section {
                Toggle(isOn: $settings.includesMicrophoneInLiveSubtitles) {
                    Text(L10n.includeMicrophone)
                    Text(L10n.liveSubtitleMicrophoneDescription)
                }
                .toggleStyle(.switch)
                .disabled(!settings.liveSubtitleOverlayEnabled)

                Picker(selection: $settings.liveSubtitleOverlaySegmentCount) {
                    ForEach(1 ..< 6, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                } label: {
                    Text(L10n.liveSubtitleOverlaySegmentCount)
                    Text(L10n.liveSubtitleOverlaySegmentCountDescription)
                }
                .pickerStyle(.menu)
                .disabled(!settings.liveSubtitleOverlayEnabled)
            } header: {
                Text(L10n.liveSubtitleOverlay)
            } footer: {
                if !settings.liveSubtitleOverlayEnabled {
                    Text(L10n.enableLiveSubtitlesToConfigure)
                }
            }
        }
        .formStyle(.grouped)
    }
}
