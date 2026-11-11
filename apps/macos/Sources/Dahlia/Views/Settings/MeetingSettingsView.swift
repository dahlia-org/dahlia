import SwiftUI

/// How the open account records and joins meetings: transcription, live subtitles, screenshots, and meeting links.
/// The values belong to the account on this Mac (`AppSettings.switchMeetingSettings`). The tabs look like the Agents page's.
struct MeetingSettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case transcription
        case liveSubtitles
        case screenshots
        case meetingLinks

        var id: Self { self }

        var label: String {
            switch self {
            case .transcription: L10n.transcription
            case .liveSubtitles: L10n.liveSubtitles
            case .screenshots: L10n.screenshots
            case .meetingLinks: L10n.meetingLinks
            }
        }
    }

    @Environment(MainWindowNavigation.self) private var navigation

    var body: some View {
        @Bindable var navigation = navigation
        VStack(spacing: 0) {
            // In a grouped form's header, the tabs share the column of the settings title and the sections below.
            Form {
                Section {
                    EmptyView()
                } header: {
                    UnderlineTabBar(tabs: Tab.allCases, selection: $navigation.meetingSettingsTab, label: \.label, accessibilityLabel: L10n.meetings)
                }
            }
            .formStyle(.grouped)
            .font(.dahliaBody)
            .fixedSize(horizontal: false, vertical: true)

            switch navigation.meetingSettingsTab {
            case .transcription: TranscriptionSettingsView()
            case .liveSubtitles: LiveSubtitleSettingsView()
            case .screenshots: ScreenshotSettingsView()
            case .meetingLinks: MeetingLinkSettingsView()
            }
        }
    }
}
