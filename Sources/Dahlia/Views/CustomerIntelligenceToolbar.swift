import SwiftUI

struct CustomerIntelligenceToolbar: ToolbarContent {
    let section: CustomerIntelligenceSection
    let scope: CustomerIntelligenceScope
    let selectedOrganizationID: UUID?
    let roots: [OrganizationWorkspaceNode]
    @Binding var showsInspector: Bool
    let canGoBack: Bool
    let canGoForward: Bool
    let onGoBack: () -> Void
    let onGoForward: () -> Void
    let onSelectScope: (CustomerIntelligenceScope) -> Void
    let onCreate: (CustomerIntelligenceCreationRequest) -> Void
    let onOrganizeWithAI: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button(L10n.back, systemImage: "chevron.backward", action: onGoBack)
                .labelStyle(.iconOnly)
                .disabled(!canGoBack)
                .help(L10n.back)
            Button(L10n.forward, systemImage: "chevron.forward", action: onGoForward)
                .labelStyle(.iconOnly)
                .disabled(!canGoForward)
                .help(L10n.forward)
        }

        ToolbarItem(placement: .principal) {
            CustomerIntelligenceScopePicker(
                scope: scope,
                roots: roots,
                onSelect: onSelectScope
            )
        }
        ToolbarItemGroup(placement: .primaryAction) {
            creationMenu

            Button(L10n.organizeWithAI, systemImage: "sparkles", action: onOrganizeWithAI)
                .disabled(scope == .all)

            Menu(L10n.customerIntelligenceViewOptions, systemImage: "textformat.size") {
                Picker(
                    L10n.customerIntelligenceTableDensity,
                    selection: Binding(
                        get: {
                            CustomerIntelligenceTableDensity(
                                rawValue: AppSettings.shared.customerIntelligenceTableDensityRawValue
                            ) ?? .standard
                        },
                        set: {
                            AppSettings.shared.customerIntelligenceTableDensityRawValue = $0.rawValue
                        }
                    )
                ) {
                    Text(L10n.customerIntelligenceStandardDensity)
                        .tag(CustomerIntelligenceTableDensity.standard)
                    Text(L10n.customerIntelligenceCompactDensity)
                        .tag(CustomerIntelligenceTableDensity.compact)
                }
            }

            Button(
                showsInspector ? L10n.customerIntelligenceHideInspector : L10n.customerIntelligenceShowInspector,
                systemImage: "sidebar.right",
                action: { showsInspector.toggle() }
            )
            .disabled(section == .overview || section == .organizations && scope == .all)
        }
    }

    @ViewBuilder
    private var creationMenu: some View {
        switch section {
        case .organizations:
            Button(
                scope == .all ? L10n.newOrganization : L10n.newDepartment,
                systemImage: "plus",
                action: {
                    onCreate(scope == .all
                        ? .organization(parentID: nil)
                        : .organization(parentID: selectedOrganizationID ?? scope.organizationID))
                }
            )
        case .contacts:
            Button(L10n.customerIntelligenceNewPerson, systemImage: "plus") {
                onCreate(.contact(organizationID: selectedOrganizationID ?? scope.organizationID))
            }
        case .projects:
            Button(L10n.newProject, systemImage: "plus") {
                onCreate(.project(organizationID: selectedOrganizationID ?? scope.organizationID))
            }
        case .topics:
            Button(L10n.customerIntelligenceNewTopic, systemImage: "plus") {
                onCreate(.topic(organizationID: selectedOrganizationID ?? scope.organizationID))
            }
        case .overview, .insights:
            Menu(L10n.create, systemImage: "plus") {
                Button(L10n.newOrganization, systemImage: "building.2") {
                    onCreate(.organization(parentID: nil))
                }
                Button(L10n.customerIntelligenceNewPerson, systemImage: "person.badge.plus") {
                    onCreate(.contact(organizationID: selectedOrganizationID ?? scope.organizationID))
                }
                Button(L10n.newProject, systemImage: "folder.badge.plus") {
                    onCreate(.project(organizationID: selectedOrganizationID ?? scope.organizationID))
                }
                Button(L10n.customerIntelligenceNewTopic, systemImage: "text.bubble") {
                    onCreate(.topic(organizationID: selectedOrganizationID ?? scope.organizationID))
                }
            }
        }
    }
}
