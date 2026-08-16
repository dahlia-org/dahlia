import DahliaRuntimeSupport
import GRDB
import SwiftUI

struct CustomerIntelligenceProjectsView: View {
    let initialProjectID: UUID?
    let reloadToken: Int
    @Binding var showsInspector: Bool
    let sidebarViewModel: SidebarViewModel
    let onSelectProject: (UUID?) -> Void
    let onOpenResource: (CustomerIntelligenceWorkspaceData.ResourceLink) -> Void
    let onOpenMeeting: (UUID) -> Void
    let onOpenProjectManager: () -> Void

    @State private var model: CustomerIntelligenceProjectsViewModel
    @State private var selectedProjectID: UUID?
    @State private var editedProject: ProjectRecord?
    @State private var sortOrder = [
        KeyPathComparator(\CustomerIntelligenceWorkspaceData.ProjectSummary.sortPath),
    ]
    @ObservedObject private var settings = AppSettings.shared

    init(
        dbQueue: DatabaseQueue,
        vaultID: UUID,
        scope: CustomerIntelligenceScope,
        initialProjectID: UUID?,
        reloadToken: Int,
        showsInspector: Binding<Bool>,
        sidebarViewModel: SidebarViewModel,
        onSelectProject: @escaping (UUID?) -> Void,
        onOpenResource: @escaping (CustomerIntelligenceWorkspaceData.ResourceLink) -> Void,
        onOpenMeeting: @escaping (UUID) -> Void,
        onOpenProjectManager: @escaping () -> Void
    ) {
        self.initialProjectID = initialProjectID
        self.reloadToken = reloadToken
        _showsInspector = showsInspector
        self.sidebarViewModel = sidebarViewModel
        self.onSelectProject = onSelectProject
        self.onOpenResource = onOpenResource
        self.onOpenMeeting = onOpenMeeting
        self.onOpenProjectManager = onOpenProjectManager
        _model = State(initialValue: CustomerIntelligenceProjectsViewModel(
            dbQueue: dbQueue,
            vaultID: vaultID,
            scope: scope
        ))
        _selectedProjectID = State(initialValue: initialProjectID)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                DahliaInlineSearchField(
                    placeholder: L10n.customerIntelligenceSearchProjects,
                    text: $model.searchText
                )
                Spacer(minLength: 0)
            }
            .padding()

            Divider()
            projectTable
        }
        .inspector(isPresented: $showsInspector) {
            projectInspector
                .inspectorColumnWidth(min: 340, ideal: 420, max: 580)
        }
        .task(id: reloadToken) {
            selectedProjectID = initialProjectID ?? selectedProjectID
            await model.load(selectedID: selectedProjectID)
            reconcileSelection()
        }
        .onChange(of: initialProjectID) { _, id in
            selectedProjectID = id
        }
        .onChange(of: selectedProjectID) { _, id in
            onSelectProject(id)
            Task { await model.select(id) }
        }
        .sheet(item: $editedProject) { project in
            CustomerIntelligenceProjectEditorSheet(
                project: project,
                effectiveProjectType: model.detail?.summary.effectiveType ?? project.projectType ?? .undefined,
                projects: sidebarViewModel.flatProjects,
                sidebarViewModel: sidebarViewModel,
                model: model
            )
        }
        .customerIntelligenceErrorAlert(
            title: L10n.customerIntelligenceProjectsError,
            message: $model.errorMessage
        )
    }

    private var projectTable: some View {
        Table(
            model.filteredProjects.sorted(using: sortOrder),
            selection: $selectedProjectID,
            sortOrder: $sortOrder
        ) {
            TableColumn(L10n.customerIntelligenceProjectPath, value: \.sortPath) { summary in
                Text(summary.project.path)
                    .lineLimit(1)
            }
            TableColumn(L10n.projectType, value: \.sortType) { summary in
                Text(projectTypeTitle(summary.effectiveType))
            }
            .width(min: 90, ideal: 110)
            TableColumn(L10n.organizations, value: \.sortOrganizations) { summary in
                Text(summary.organizationNames.joined(separator: ", "))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            TableColumn(L10n.people, value: \.sortContacts) { summary in
                Text(summary.contactNames.joined(separator: ", "))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            TableColumn(L10n.meetings, value: \.meetingCount) { summary in
                Text(summary.meetingCount, format: .number)
                    .monospacedDigit()
            }
            .width(70)
            TableColumn(L10n.customerIntelligenceRecentActivity, value: \.sortLatestMeetingDate) { summary in
                if let date = summary.latestMeetingDate {
                    Text(date, format: .dateTime.year().month().day())
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .width(min: 110, ideal: 130)
        }
        .customerIntelligenceTableStyle()
        .environment(\.defaultMinListRowHeight, tableRowHeight)
        .overlay {
            if model.filteredProjects.isEmpty, !model.isLoading {
                if model.searchText.nilIfBlank != nil {
                    ContentUnavailableView.search
                } else {
                    ContentUnavailableView(
                        L10n.customerIntelligenceNoProjects,
                        systemImage: "folder",
                        description: Text(L10n.customerIntelligenceNoProjectsDescription)
                    )
                }
            } else if model.isLoading, model.projects.isEmpty {
                ProgressView()
            }
        }
    }

    @ViewBuilder
    private var projectInspector: some View {
        if let detail = model.detail {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    CustomerIntelligenceInspectorHeader(
                        title: detail.summary.project.name,
                        subtitle: detail.summary.project.path,
                        systemImage: "folder",
                        badge: projectTypeTitle(detail.summary.effectiveType),
                        onEdit: { editedProject = detail.summary.project }
                    )

                    CustomerIntelligenceInspectorSection(title: L10n.projectDescription) {
                        Text(detail.summary.project.description.nilIfBlank
                            ?? L10n.customerIntelligenceNoDescription)
                            .foregroundStyle(
                                detail.summary.project.description.nilIfBlank == nil
                                    ? .secondary
                                    : .primary
                            )
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !detail.references.isEmpty {
                        CustomerIntelligenceInspectorSection(title: L10n.customerIntelligenceRelatedResources) {
                            ForEach(detail.references) { link in
                                CustomerIntelligenceLinkRow(
                                    title: link.title,
                                    subtitle: link.role,
                                    systemImage: icon(for: link.kind),
                                    action: { onOpenResource(link) }
                                )
                            }
                        }
                    }

                    if !detail.meetings.isEmpty {
                        CustomerIntelligenceInspectorSection(title: L10n.meetings) {
                            ForEach(detail.meetings, id: \.id) { meeting in
                                CustomerIntelligenceLinkRow(
                                    title: meeting.name,
                                    subtitle: meeting.effectiveRecordingStartedAt.formatted(date: .abbreviated, time: .omitted),
                                    systemImage: "calendar",
                                    action: { onOpenMeeting(meeting.id) }
                                )
                            }
                        }
                    }

                    Divider()
                    Button(L10n.customerIntelligenceManageInProjects, systemImage: "arrow.up.forward.app") {
                        onOpenProjectManager()
                    }
                }
                .padding()
            }
        } else {
            ContentUnavailableView(
                L10n.customerIntelligenceSelectProject,
                systemImage: "folder"
            )
        }
    }

    private var tableRowHeight: Double {
        settings.customerIntelligenceTableDensityRawValue == CustomerIntelligenceTableDensity.compact.rawValue
            ? 24 : 34
    }

    private func reconcileSelection() {
        if let selectedProjectID, model.projects.contains(where: { $0.id == selectedProjectID }) {
            return
        }
        selectedProjectID = nil
    }

    private func projectTypeTitle(_ type: ProjectType) -> String {
        switch type {
        case .customer: L10n.projectTypeCustomer
        case .internal: L10n.projectTypeInternal
        case .personal: L10n.projectTypePersonal
        case .undefined: L10n.projectTypeUndefined
        }
    }

    private func icon(for kind: CustomerIntelligenceResourceKind) -> String {
        switch kind {
        case .organization: "building.2"
        case .contact: "person.crop.circle"
        case .project: "folder"
        case .meeting: "calendar"
        case .topic: "text.bubble"
        }
    }
}

private struct CustomerIntelligenceProjectEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let project: ProjectRecord
    let effectiveProjectType: ProjectType
    let projects: [FlatProjectRow]
    let sidebarViewModel: SidebarViewModel
    let model: CustomerIntelligenceProjectsViewModel

    @State private var name: String
    @State private var parentProjectID: UUID?
    @State private var projectType: ProjectType
    @State private var description: String
    @State private var errorMessage: String?

    init(
        project: ProjectRecord,
        effectiveProjectType: ProjectType,
        projects: [FlatProjectRow],
        sidebarViewModel: SidebarViewModel,
        model: CustomerIntelligenceProjectsViewModel
    ) {
        self.project = project
        self.effectiveProjectType = effectiveProjectType
        self.projects = projects
        self.sidebarViewModel = sidebarViewModel
        self.model = model
        _name = State(initialValue: project.name)
        _parentProjectID = State(initialValue: project.parentProjectId)
        _projectType = State(initialValue: effectiveProjectType)
        _description = State(initialValue: project.description)
    }

    var body: some View {
        VStack(spacing: 0) {
            DahliaSheetHeader(title: L10n.customerIntelligenceEditProject)

            Divider()

            Form {
                if let displayedError = errorMessage {
                    Section {
                        Label(displayedError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        Button(L10n.reload) {
                            Task {
                                await model.load(selectedID: project.id)
                                if let fresh = model.detail?.summary.project {
                                    name = fresh.name
                                    parentProjectID = fresh.parentProjectId
                                    projectType = fresh.projectType ?? .undefined
                                    description = fresh.description
                                    errorMessage = nil
                                }
                            }
                        }
                    }
                }

                Section(L10n.customerIntelligenceProjectDetails) {
                    TextField(L10n.projectName, text: $name)
                    Picker(L10n.parentProject, selection: $parentProjectID) {
                        Text(L10n.none).tag(UUID?.none)
                        ForEach(parentCandidates) { candidate in
                            Text(candidate.name).tag(Optional(candidate.id))
                        }
                    }
                    if parentProjectID == nil {
                        Picker(L10n.projectType, selection: $projectType) {
                            ForEach(ProjectType.allCases, id: \.self) { type in
                                Text(projectTypeTitle(type)).tag(type)
                            }
                        }
                    }
                    TextField(L10n.projectDescription, text: $description, axis: .vertical)
                        .lineLimit(5 ... 10)
                }
            }
            .formStyle(.grouped)

            Divider()

            DahliaSheetActionBar {
                Button(L10n.cancel, action: dismiss.callAsFunction)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.save) {
                    model.setSaving(true)
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.nilIfBlank == nil || model.isSaving)
            }
        }
        .frame(minWidth: 560, minHeight: 520)
        .dahliaSimpleWindowStyle()
    }

    private var parentCandidates: [FlatProjectRow] {
        FlatProjectRow.validParentCandidates(for: project, in: projects)
    }

    private func save() async {
        defer { model.setSaving(false) }

        guard let current = await sidebarViewModel.updateProject(
            id: project.id,
            name: name,
            parentProjectId: parentProjectID,
            projectType: projectType,
            description: description,
            expectedRevision: project.revision
        ) else {
            errorMessage = sidebarViewModel.lastError ?? L10n.customerIntelligenceSaveFailed
            return
        }

        await model.didMutate(selecting: current.id)
        dismiss()
    }

    private func projectTypeTitle(_ type: ProjectType) -> String {
        switch type {
        case .customer: L10n.projectTypeCustomer
        case .internal: L10n.projectTypeInternal
        case .personal: L10n.projectTypePersonal
        case .undefined: L10n.projectTypeUndefined
        }
    }
}
