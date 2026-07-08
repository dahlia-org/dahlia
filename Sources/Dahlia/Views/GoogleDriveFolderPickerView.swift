import SwiftUI

struct GoogleDriveFolderPickerView: View {
    private enum PickerTab: String, CaseIterable, Identifiable {
        case myDrive
        case sharedDrives

        var id: String { rawValue }

        var title: String {
            switch self {
            case .myDrive:
                L10n.googleDriveMyDrive
            case .sharedDrives:
                L10n.googleDriveSharedDrives
            }
        }
    }

    private struct BrowserNode: Equatable, Identifiable {
        let id: String
        let name: String
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var driveStore = GoogleDriveStore.shared

    @State private var selectedTab: PickerTab = .myDrive
    @State private var searchText = ""
    @State private var searchQuery = ""
    @State private var isSearchFieldFocused = false
    @State private var myDrivePath: [BrowserNode] = [.init(id: "root", name: L10n.googleDriveMyDrive)]
    @State private var sharedDrivePath: [BrowserNode] = []

    let onSelect: (GoogleDriveFolderItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            NonAutofocusingSearchField(
                text: $searchText,
                isFocused: $isSearchFieldFocused,
                placeholder: L10n.googleDriveSearchPlaceholder
            ) {
                executeSearch()
            }
            .frame(height: 22)

            VStack(alignment: .leading, spacing: 16) {
                if !isSearching {
                    tabPicker
                }

                if !isSearching, shouldShowBreadcrumbs {
                    breadcrumbBar
                }

                contentView

                if let lastErrorMessage = driveStore.lastErrorMessage {
                    SettingsStatusMessage(
                        text: lastErrorMessage,
                        systemImage: "exclamationmark.triangle",
                        tint: .orange
                    )
                }

                HStack {
                    Spacer()

                    Button(L10n.close) {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)

                    if !isSearching {
                        Button(L10n.selectFolder) {
                            selectCurrentFolder()
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(currentSelectionFolder == nil)
                    }
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture().onEnded {
                    dismissSearchFocus()
                }
            )
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 460)
        .task {
            await driveStore.restoreSessionIfNeeded()
            await reloadCurrentView()
        }
        .onChange(of: selectedTab) { _, _ in
            clearSearch()
            Task {
                await reloadCurrentView()
            }
        }
        .onChange(of: searchText) { _, newValue in
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !searchQuery.isEmpty {
                clearSearch()
                Task {
                    await reloadCurrentView()
                }
            }
        }
    }

    private var tabPicker: some View {
        Picker("", selection: $selectedTab) {
            ForEach(PickerTab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    @ViewBuilder
    private var contentView: some View {
        if driveStore.isBusy, driveStore.folders.isEmpty {
            ProgressView(L10n.googleDriveLoadingFolders)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if driveStore.folders.isEmpty {
            ContentUnavailableView {
                Label(L10n.googleDriveNoFolders, systemImage: "folder")
            } description: {
                Text(isSearching ? L10n.googleDriveFolderPickerDescription : L10n.googleDriveNoFoldersInLocation)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(driveStore.folders) { folder in
                Button {
                    open(folder)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "folder")
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(folder.name)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(folder.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
            }
            .listStyle(.inset)
        }
    }

    private var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(currentBreadcrumbNodes.enumerated()), id: \.offset) { index, node in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Button(node.name) {
                        navigateTo(index: index)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(index == currentBreadcrumbNodes.count - 1 ? .primary : .secondary)
                    .font(.system(size: 13, weight: index == currentBreadcrumbNodes.count - 1 ? .semibold : .regular))
                }
            }
        }
    }

    private func open(_ folder: GoogleDriveFolderItem) {
        if isSearching {
            openSearchResult(folder)
            return
        }

        switch selectedTab {
        case .myDrive:
            myDrivePath.append(.init(id: folder.id, name: folder.name))
        case .sharedDrives:
            if folder.kind == .sharedDrive {
                sharedDrivePath = [.init(id: folder.id, name: folder.name)]
            } else {
                sharedDrivePath.append(.init(id: folder.id, name: folder.name))
            }
        }
        Task {
            await reloadCurrentView()
        }
    }

    private func openSearchResult(_ folder: GoogleDriveFolderItem) {
        let targetTab: PickerTab

        if let driveId = folder.driveId, !driveId.isEmpty {
            targetTab = .sharedDrives
            let driveName = folder.driveName ?? L10n.googleDriveSharedDrives
            sharedDrivePath = [.init(id: driveId, name: driveName)]
            if folder.kind != .sharedDrive || folder.id != driveId {
                sharedDrivePath.append(.init(id: folder.id, name: folder.name))
            }
        } else {
            targetTab = .myDrive
            myDrivePath = [
                .init(id: "root", name: L10n.googleDriveMyDrive),
                .init(id: folder.id, name: folder.name),
            ]
        }

        clearSearch()

        if selectedTab == targetTab {
            Task {
                await reloadCurrentView()
            }
        } else {
            selectedTab = targetTab
        }
    }

    private func navigateTo(index: Int) {
        guard index < currentBreadcrumbNodes.count else { return }
        switch selectedTab {
        case .myDrive:
            myDrivePath = Array(myDrivePath.prefix(index + 1))
        case .sharedDrives:
            if index == 0 {
                sharedDrivePath = []
            } else {
                sharedDrivePath = Array(sharedDrivePath.prefix(index))
            }
        }
        Task {
            await reloadCurrentView()
        }
    }

    private func selectCurrentFolder() {
        guard let folder = currentSelectionFolder else { return }
        onSelect(folder)
        dismiss()
    }

    private func reloadCurrentView() async {
        guard !isSearching else {
            await driveStore.searchFolders(query: searchQuery)
            return
        }

        switch selectedTab {
        case .myDrive:
            let currentFolderID = myDrivePath.last?.id == "root" ? nil : myDrivePath.last?.id
            await driveStore.browseFolders(parentFolderId: currentFolderID)
        case .sharedDrives:
            if sharedDrivePath.isEmpty {
                await driveStore.browseSharedDrives()
            } else {
                let driveId = sharedDrivePath.first?.id
                let currentFolderID = sharedDrivePath.last?.id
                await driveStore.browseFolders(parentFolderId: currentFolderID, driveId: driveId)
            }
        }
    }

    private var currentBreadcrumbNodes: [BrowserNode] {
        switch selectedTab {
        case .myDrive:
            myDrivePath
        case .sharedDrives:
            [BrowserNode(id: "shared-drives-root", name: L10n.googleDriveSharedDrives)] + sharedDrivePath
        }
    }

    private var shouldShowBreadcrumbs: Bool {
        currentBreadcrumbNodes.count > 1
    }

    private var currentSelectionFolder: GoogleDriveFolderItem? {
        guard let currentNode = currentSelectionNode else { return nil }
        return GoogleDriveFolderItem(
            id: currentNode.id,
            name: currentNode.name,
            detail: currentNode.name
        )
    }

    private var currentSelectionNode: BrowserNode? {
        switch selectedTab {
        case .myDrive:
            myDrivePath.last
        case .sharedDrives:
            sharedDrivePath.last
        }
    }

    private func executeSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchQuery = trimmed
        dismissSearchFocus()
        Task {
            await reloadCurrentView()
        }
    }

    private func clearSearch() {
        searchQuery = ""
        searchText = ""
        dismissSearchFocus()
    }

    private func dismissSearchFocus() {
        isSearchFieldFocused = false
    }
}
