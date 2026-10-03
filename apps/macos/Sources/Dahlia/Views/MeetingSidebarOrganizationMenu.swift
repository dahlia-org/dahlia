import SwiftUI

struct MeetingSidebarOrganizationMenu: View {
    @Binding var displayMode: MeetingSidebarDisplayMode

    var body: some View {
        Menu {
            Picker(L10n.sidebarOrganization, selection: $displayMode) {
                Label(L10n.chronological, systemImage: "clock")
                    .tag(MeetingSidebarDisplayMode.chronological)
                Label(L10n.groupByProject, systemImage: "folder")
                    .tag(MeetingSidebarDisplayMode.byProject)
            }
            .pickerStyle(.inline)
        } label: {
            Label(L10n.sidebarOrganization, systemImage: "ellipsis")
                .labelStyle(.iconOnly)
                .dahliaFixedSymbol()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.sidebarOrganization)
    }
}
