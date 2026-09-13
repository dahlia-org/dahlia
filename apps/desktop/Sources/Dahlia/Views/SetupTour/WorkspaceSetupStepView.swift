import DahliaRuntimeSupport
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceSetupStepView: View {
    var model: SetupTourModel
    var workspaceManagementModel: WorkspaceManagementModel

    @State private var isShowingFolderPicker = false
    @State private var isCreatingWorkspace = false
    @State private var isBackHovered = false
    @State private var workspaceName: String

    init(model: SetupTourModel, workspaceManagementModel: WorkspaceManagementModel) {
        self.model = model
        self.workspaceManagementModel = workspaceManagementModel
        _workspaceName = State(initialValue: workspaceManagementModel.workspaces.isEmpty ? "Dahlia" : "")
    }

    var body: some View {
        VStack(spacing: 20) {
            if isCreatingWorkspace {
                VStack(alignment: .leading, spacing: 18) {
                    Button {
                        isCreatingWorkspace = false
                    } label: {
                        Label(L10n.back, systemImage: "chevron.left")
                            .padding(.horizontal, 10)
                            .frame(minHeight: 36)
                            .background(
                                isBackHovered ? DahliaDesign.contentHighlightColor : .clear,
                                in: .rect(cornerRadius: DahliaDesign.Highlight.regularCornerRadius)
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { isBackHovered = $0 }

                    Text(L10n.createNewWorkspace)
                        .font(.title2)
                        .bold()

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 24) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.workspaceName)
                                    .font(.headline)
                                Text(L10n.workspaceNameDescription)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            TextField(L10n.workspaceName, text: $workspaceName)
                                .textFieldStyle(.roundedBorder)
                                .controlSize(.large)
                                .frame(width: 220)
                                .onSubmit(createWorkspaceSelection)
                        }

                    }
                    .padding(22)
                    .background(
                        Color.secondary.opacity(0.05),
                        in: .rect(cornerRadius: DahliaDesign.Card.regularCornerRadius)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: DahliaDesign.Card.regularCornerRadius)
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                    }

                    Button(action: createWorkspaceSelection) {
                        Text(L10n.create)
                            .frame(minWidth: 112, minHeight: 28)
                    }
                    .buttonStyle(.dahlia(.primary))
                    .controlSize(.large)
                    .disabled(normalizedWorkspaceName == nil)
                    .frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(workspaceManagementModel.workspaces.filter { $0.accountConnectionId == model.selectedAccountConnectionID }) { workspace in
                        HStack {
                            Label(workspace.name, systemImage: "archivebox")
                            Spacer()
                            Button(model.selectedExistingWorkspaceID == workspace.id ? L10n.selected : L10n.select) {
                                model.selectExistingWorkspace(workspace)
                            }
                            .buttonStyle(.dahlia())
                            .disabled(model.selectedExistingWorkspaceID == workspace.id)
                        }
                        .padding(22)
                        Divider()
                    }
                    HStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.createNewWorkspace)
                                .font(.headline)
                            Text(L10n.createNewWorkspaceDescription)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            isCreatingWorkspace = true
                        } label: {
                            Text(L10n.create)
                                .frame(minWidth: 112, minHeight: 28)
                        }
                        .buttonStyle(.dahlia(.primary))
                        .controlSize(.large)
                    }
                    .padding(22)

                    Divider()

                    HStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.openFolderAsWorkspace)
                                .font(.headline)
                            Text(L10n.openFolderAsWorkspaceDescription)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            isShowingFolderPicker = true
                        } label: {
                            Text(L10n.open)
                                .frame(minWidth: 112, minHeight: 28)
                        }
                        .buttonStyle(.dahlia())
                        .controlSize(.large)
                    }
                    .padding(22)
                }
                .background(
                    Color.secondary.opacity(0.05),
                    in: .rect(cornerRadius: DahliaDesign.Card.regularCornerRadius)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: DahliaDesign.Card.regularCornerRadius)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                }
            }
        }
        .frame(maxWidth: 640)
        .fileImporter(
            isPresented: $isShowingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: handleFolderImport
        )
        .fileDialogDefaultDirectory(WorkspaceManagementModel.defaultWorkspaceURL)
    }

    private func handleFolderImport(_ result: Result<[URL], any Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            model.selectWorkspaceURL(url)
            model.confirmWorkspaceSelection()
        case let .failure(error):
            guard (error as? CocoaError)?.code != .userCancelled else { return }
            workspaceManagementModel.presentFolderSelectionError(error)
        }
    }

    private var normalizedWorkspaceName: String? {
        DahliaProjectName.normalizedName(workspaceName)
    }

    private func createWorkspaceSelection() {
        guard let normalizedWorkspaceName else { return }
        model.selectPathlessWorkspace(named: normalizedWorkspaceName)
        isCreatingWorkspace = false
    }
}
