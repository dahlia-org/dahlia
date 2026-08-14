import SwiftUI

struct MeetingLinkTargetPicker: View {
    let title: String
    @Binding var selection: String
    let applications: [MeetingLinkApplication]
    let allowsGlobalInheritance: Bool
    let isLoading: Bool

    var body: some View {
        LabeledContent(title) {
            Picker(title, selection: $selection) {
                if allowsGlobalInheritance {
                    Text(L10n.useAllMeetingLinksSetting)
                        .tag(MeetingLinkOpenTarget.inheritGlobal.rawValue)
                }

                Text(L10n.defaultWebBrowser)
                    .tag(MeetingLinkOpenTarget.systemDefault.rawValue)

                ForEach(applications) { application in
                    Text(application.displayName)
                        .tag(MeetingLinkOpenTarget.application(bundleIdentifier: application.bundleIdentifier).rawValue)
                }

                if let selectedBundleIdentifier {
                    Text(isLoading
                        ? selectedBundleIdentifier
                        : L10n.selectedApplicationUnavailable(selectedBundleIdentifier))
                        .tag(selection)
                }
            }
            .labelsHidden()
        }
    }

    private var selectedBundleIdentifier: String? {
        guard case let .application(bundleIdentifier) = MeetingLinkOpenTarget(rawValue: selection),
              !applications.contains(where: { $0.bundleIdentifier == bundleIdentifier })
        else { return nil }
        return bundleIdentifier
    }
}
