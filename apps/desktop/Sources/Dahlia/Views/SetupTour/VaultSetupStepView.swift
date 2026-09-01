import SwiftUI
import UniformTypeIdentifiers

struct VaultSetupStepView: View {
    var model: SetupTourModel
    var vaultManagementModel: VaultManagementModel

    @State private var isShowingFolderPicker = false
    @State private var isCreatingVault = false
    @State private var isBackHovered = false
    @State private var vaultName: String

    init(model: SetupTourModel, vaultManagementModel: VaultManagementModel) {
        self.model = model
        self.vaultManagementModel = vaultManagementModel
        _vaultName = State(initialValue: vaultManagementModel.vaults.isEmpty ? "Dahlia" : "")
    }

    var body: some View {
        VStack(spacing: 20) {
            if isCreatingVault {
                VStack(alignment: .leading, spacing: 18) {
                    Button {
                        isCreatingVault = false
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

                    Text(L10n.createNewVault)
                        .font(.title2)
                        .bold()

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 24) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.vaultName)
                                    .font(.headline)
                                Text(L10n.vaultNameDescription)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            TextField(L10n.vaultName, text: $vaultName)
                                .textFieldStyle(.roundedBorder)
                                .controlSize(.large)
                                .frame(width: 220)
                                .onSubmit(createVaultSelection)
                        }

                        if let newVaultURL {
                            Text(newVaultURL.path(percentEncoded: false))
                                .font(.footnote.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
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

                    Button(action: createVaultSelection) {
                        Text(L10n.create)
                            .frame(minWidth: 112, minHeight: 28)
                    }
                    .buttonStyle(.dahlia(.primary))
                    .controlSize(.large)
                    .disabled(newVaultURL == nil)
                    .frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.createNewVault)
                                .font(.headline)
                            Text(L10n.createNewVaultDescription)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            isCreatingVault = true
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
                            Text(L10n.openFolderAsVault)
                                .font(.headline)
                            Text(L10n.openFolderAsVaultDescription)
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
        .fileDialogDefaultDirectory(VaultManagementModel.defaultVaultURL)
    }

    private func handleFolderImport(_ result: Result<[URL], any Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            model.selectVaultURL(url)
            model.confirmVaultSelection()
        case let .failure(error):
            guard (error as? CocoaError)?.code != .userCancelled else { return }
            vaultManagementModel.presentFolderSelectionError(error)
        }
    }

    private var newVaultURL: URL? {
        SetupTourModel.newVaultURL(named: vaultName)
    }

    private func createVaultSelection() {
        guard let newVaultURL else { return }
        model.selectVaultURL(newVaultURL)
        model.confirmVaultSelection()
        isCreatingVault = false
    }
}
