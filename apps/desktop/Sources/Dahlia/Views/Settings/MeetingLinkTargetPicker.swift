import SwiftUI

struct MeetingLinkTargetPicker: View {
    let title: String
    @Binding var selection: String
    let applications: [MeetingLinkApplication]
    let allowsGlobalInheritance: Bool
    let isLoading: Bool

    var body: some View {
        DahliaMenuPicker(
            title: title,
            selection: $selection,
            options: options,
            label: optionLabel
        )
    }

    private var options: [String] {
        var values = allowsGlobalInheritance ? [MeetingLinkOpenTarget.inheritGlobal.rawValue] : []
        values.append(MeetingLinkOpenTarget.systemDefault.rawValue)
        values.append(contentsOf: applications.map {
            MeetingLinkOpenTarget.application(bundleIdentifier: $0.bundleIdentifier).rawValue
        })
        if selectedBundleIdentifier != nil {
            values.append(selection)
        }
        return values
    }

    private func optionLabel(_ value: String) -> String {
        guard let target = MeetingLinkOpenTarget(rawValue: value) else { return value }
        switch target {
        case .inheritGlobal:
            return L10n.useAllMeetingLinksSetting
        case .systemDefault:
            return L10n.defaultWebBrowser
        case let .application(bundleIdentifier):
            return applications.first(where: { $0.bundleIdentifier == bundleIdentifier })?.displayName
                ?? (isLoading ? bundleIdentifier : L10n.selectedApplicationUnavailable(bundleIdentifier))
        }
    }

    private var selectedBundleIdentifier: String? {
        guard case let .application(bundleIdentifier) = MeetingLinkOpenTarget(rawValue: selection),
              !applications.contains(where: { $0.bundleIdentifier == bundleIdentifier })
        else { return nil }
        return bundleIdentifier
    }
}
