import SwiftUI

/// 保管庫の登録・選択・登録解除を行う画面。
struct VaultPickerView: View {
    private enum SidebarMetrics {
        static let minimumWidth: CGFloat = 220
        static let defaultWidth: CGFloat = 280
        static let maximumWidth: CGFloat = 360
    }

    let appDatabase: AppDatabaseManager?
    var model: VaultManagementModel
    let canSwitchVault: Bool
    @ObservedObject var captionViewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel
    @Bindable var mainWindowNavigation: MainWindowNavigation
    var updateController: AppUpdateController
    let onVaultSelected: (VaultRecord) -> Void

    @ObservedObject private var settings = AppSettings.shared
    @State private var selectedVaultId: UUID?
    @State private var isShowingFolderPicker = false
    @State private var vaultSidebarWidth = SidebarMetrics.defaultWidth

    private var selectedVault: VaultRecord? {
        guard let selectedVaultId else { return nil }
        return model.vaults.first(where: { $0.id == selectedVaultId })
    }

    var body: some View {
        let isShowingSettings = mainWindowNavigation.isShowingSettings
        let sidebarWidth = isShowingSettings ? mainWindowNavigation.sidebarWidth : vaultSidebarWidth
        let minimumSidebarWidth = isShowingSettings ? MainSidebarLayout.minimumWidth : SidebarMetrics.minimumWidth
        let maximumSidebarWidth = isShowingSettings ? MainSidebarLayout.maximumWidth : SidebarMetrics.maximumWidth

        HSplitView {
            MainWindowPaneContent(
                isMainContentVisible: true,
                isShowingSettings: isShowingSettings,
                settingsBackground: .sidebar
            ) {
                VaultSidebarView(
                    vaults: model.vaults,
                    selectedVaultId: $selectedVaultId,
                    currentVaultId: settings.currentVault?.id,
                    updateController: updateController,
                    onAdd: showFolderPicker,
                    onRemove: removeVault
                )
                .disabled(model.isRemovingVault)
            } settingsContent: {
                SettingsSidebarView(
                    selection: $mainWindowNavigation.settingsCategory,
                    onReturnToApp: mainWindowNavigation.dismissSettings
                )
            }
            .padding(.top, isShowingSettings ? DahliaDesign.windowHeaderHeight : 0)
            .mainSidebarPane(
                width: sidebarWidth,
                minimumWidth: minimumSidebarWidth,
                maximumWidth: maximumSidebarWidth,
                widthSourceID: isShowingSettings ? 1 : 0,
                onWidthChange: updateSidebarWidth
            )

            MainWindowPaneContent(isMainContentVisible: true, isShowingSettings: isShowingSettings) {
                VStack(spacing: 0) {
                    DahliaWindowHeader {
                        Text(selectedVault?.name ?? L10n.vaultDetails)
                            .font(.headline)
                            .lineLimit(1)

                        Spacer(minLength: 12)
                    }

                    Group {
                        if model.isRemovingVault {
                            ProgressView(L10n.removingVault)
                        } else if model.isLoading, model.vaults.isEmpty {
                            ProgressView(L10n.loadingVaults)
                        } else {
                            VaultDetailView(
                                vault: selectedVault,
                                hasRegisteredVaults: !model.vaults.isEmpty,
                                isCurrentVault: selectedVault?.id == settings.currentVault?.id,
                                canSwitchVault: canSwitchVault,
                                onOpen: openSelectedVault,
                                onAdd: showFolderPicker
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .disabled(model.isRemovingVault)
            } settingsContent: {
                SettingsDetailView(
                    selection: mainWindowNavigation.settingsCategory,
                    captionViewModel: captionViewModel,
                    sidebarViewModel: sidebarViewModel,
                    appDatabase: appDatabase,
                    vaultManagementModel: model
                )
            }
            .padding(.top, isShowingSettings ? DahliaDesign.windowHeaderHeight : 0)
            .mainDetailPane()
        }
        .overlay(alignment: .top) {
            if isShowingSettings {
                DahliaWindowHeader(reservesWindowControls: true, backgroundColor: .clear) {
                    Spacer()
                }
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .task(id: appDatabase != nil) {
            await model.configure(appDatabase: appDatabase)
            reconcileSelection()
        }
        .fileImporter(
            isPresented: $isShowingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: handleFolderImport
        )
        .fileDialogDefaultDirectory(VaultManagementModel.defaultVaultURL)
    }

    private func showFolderPicker() {
        isShowingFolderPicker = true
    }

    private func updateSidebarWidth(_ width: CGFloat) {
        if mainWindowNavigation.isShowingSettings {
            mainWindowNavigation.updateSidebarWidth(width)
        } else {
            vaultSidebarWidth = min(max(width, SidebarMetrics.minimumWidth), SidebarMetrics.maximumWidth)
        }
    }

    private func handleFolderImport(_ result: Result<[URL], any Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            let isAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if isAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            Task {
                guard let vault = await model.registerVault(at: url) else { return }
                selectedVaultId = vault.id
                openVault(vault)
            }
        case let .failure(error):
            guard (error as? CocoaError)?.code != .userCancelled else { return }
            model.presentFolderSelectionError(error)
        }
    }

    private func reconcileSelection() {
        let preferredIds = [selectedVaultId, settings.currentVault?.id].compactMap(\.self)
        selectedVaultId = preferredIds.first(where: { id in
            model.vaults.contains(where: { $0.id == id })
        }) ?? model.vaults.first?.id
    }

    private func removeVault(_ vault: VaultRecord) {
        Task {
            if await model.removeVault(vault, currentVaultId: settings.currentVault?.id), selectedVaultId == vault.id {
                selectedVaultId = model.vaults.first?.id
            }
        }
    }

    private func openSelectedVault() {
        guard let selectedVault else { return }
        openVault(selectedVault)
    }

    private func openVault(_ vault: VaultRecord) {
        guard canSwitchVault else { return }
        onVaultSelected(vault)
    }
}
