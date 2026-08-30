import SwiftUI

struct CustomerIntelligenceHeader: View {
    let section: CustomerIntelligenceSection
    let scope: CustomerIntelligenceScope
    let selectedOrganizationID: UUID?
    let roots: [OrganizationWorkspaceNode]
    @Binding var showsInspector: Bool
    let onSelectScope: (CustomerIntelligenceScope) -> Void
    let onCreate: (CustomerIntelligenceCreationRequest) -> Void
    let onOrganizeWithAI: () -> Void

    var body: some View {
        DahliaWindowHeader {
            CustomerIntelligenceScopePicker(
                scope: scope,
                roots: roots,
                onSelect: onSelectScope
            )
            .frame(maxWidth: 360)

            Spacer(minLength: 12)

            creationMenu

            DahliaWindowHeaderIconButton(
                label: L10n.organizeWithAI,
                systemImage: "sparkles",
                action: onOrganizeWithAI
            )
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
            .menuStyle(.borderlessButton)
            .help(L10n.customerIntelligenceViewOptions)

            DahliaWindowHeaderIconButton(
                label: showsInspector
                    ? L10n.customerIntelligenceHideInspector
                    : L10n.customerIntelligenceShowInspector,
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
            DahliaWindowHeaderIconButton(
                label: scope == .all ? L10n.newOrganization : L10n.newDepartment,
                systemImage: "plus",
                action: {
                    onCreate(scope == .all
                        ? .organization(parentID: nil)
                        : .organization(parentID: creationOrganizationID))
                }
            )
        case .contacts:
            DahliaWindowHeaderIconButton(
                label: L10n.customerIntelligenceNewPerson,
                systemImage: "plus",
                action: { onCreate(.contact(organizationID: creationOrganizationID)) }
            )
        case .projects:
            DahliaWindowHeaderIconButton(
                label: L10n.newProject,
                systemImage: "plus",
                action: { onCreate(.project(organizationID: creationOrganizationID)) }
            )
        case .topics:
            DahliaWindowHeaderIconButton(
                label: L10n.customerIntelligenceNewTopic,
                systemImage: "plus",
                action: { onCreate(.topic(organizationID: creationOrganizationID)) }
            )
        case .overview, .insights:
            Menu(L10n.create, systemImage: "plus") {
                Button(L10n.newOrganization, systemImage: "building.2") {
                    onCreate(.organization(parentID: nil))
                }
                Button(L10n.customerIntelligenceNewPerson, systemImage: "person.badge.plus") {
                    onCreate(.contact(organizationID: creationOrganizationID))
                }
                Button(L10n.newProject, systemImage: "folder.badge.plus") {
                    onCreate(.project(organizationID: creationOrganizationID))
                }
                Button(L10n.customerIntelligenceNewTopic, systemImage: "text.bubble") {
                    onCreate(.topic(organizationID: creationOrganizationID))
                }
            }
            .menuStyle(.borderlessButton)
            .help(L10n.create)
        }
    }

    private var creationOrganizationID: UUID? {
        selectedOrganizationID ?? scope.organizationID
    }
}
