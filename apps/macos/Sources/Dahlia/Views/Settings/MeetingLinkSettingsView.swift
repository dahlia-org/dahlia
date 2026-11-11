import SwiftUI

/// The apps that open meeting links from the calendar, notifications, and meetings, for the whole app.
struct MeetingLinkSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var catalog = MeetingLinkApplicationCatalog.empty
    @State private var isLoading = true

    var body: some View {
        Form {
            Section {
                MeetingLinkTargetPicker(
                    title: L10n.allMeetingLinks,
                    selection: $settings.defaultMeetingLinkOpenTargetRawValue,
                    applications: catalog.globalApplications,
                    allowsGlobalInheritance: false,
                    isLoading: isLoading
                )

                if isLoading {
                    ProgressView(L10n.loadingMeetingLinkApplications)
                        .controlSize(.small)
                }
            } header: {
                Text(L10n.meetingLinkApplications)
                    .font(.dahliaSectionHeader)
            } footer: {
                Text(L10n.meetingLinkApplicationsDescription)
            }

            Section {
                MeetingLinkTargetPicker(
                    title: MeetingLinkService.googleMeet.displayName,
                    selection: $settings.googleMeetMeetingLinkOpenTargetRawValue,
                    applications: catalog.applications(for: .googleMeet),
                    allowsGlobalInheritance: true,
                    isLoading: isLoading
                )
                MeetingLinkTargetPicker(
                    title: MeetingLinkService.zoom.displayName,
                    selection: $settings.zoomMeetingLinkOpenTargetRawValue,
                    applications: catalog.applications(for: .zoom),
                    allowsGlobalInheritance: true,
                    isLoading: isLoading
                )
                MeetingLinkTargetPicker(
                    title: MeetingLinkService.teams.displayName,
                    selection: $settings.teamsMeetingLinkOpenTargetRawValue,
                    applications: catalog.applications(for: .teams),
                    allowsGlobalInheritance: true,
                    isLoading: isLoading
                )
                MeetingLinkTargetPicker(
                    title: MeetingLinkService.slack.displayName,
                    selection: $settings.slackMeetingLinkOpenTargetRawValue,
                    applications: catalog.applications(for: .slack),
                    allowsGlobalInheritance: true,
                    isLoading: isLoading
                )
            } header: {
                Text(L10n.meetingLinkServiceOverrides)
                    .font(.dahliaSectionHeader)
            } footer: {
                Text(L10n.meetingLinkServiceOverridesDescription)
            }
        }
        .formStyle(.grouped)
        .font(.dahliaBody)
        .task {
            settings.normalizeMeetingLinkOpenTargets()
            catalog = await MeetingLinkApplicationCatalog.load()
            isLoading = false
        }
    }
}
