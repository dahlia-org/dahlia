import SwiftUI

struct MeetingLinkSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var catalog = MeetingLinkApplicationCatalog.empty
    @State private var isLoading = true

    var body: some View {
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
        } footer: {
            Text(L10n.meetingLinkServiceOverridesDescription)
        }
        .task {
            settings.normalizeMeetingLinkOpenTargets()
            catalog = await MeetingLinkApplicationCatalog.load()
            isLoading = false
        }
    }
}
