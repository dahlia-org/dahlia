import SwiftUI

struct DatabricksCatalogSchemaSettingsModal: View {
    let connection: DatabricksConnection
    let onClose: () -> Void
    @State private var model: DatabricksCatalogSchemaSettingsModel
    @State private var showsNewSchema = false
    @State private var creation: Task<Void, Never>?

    init(connection: DatabricksConnection, onClose: @escaping () -> Void) {
        self.connection = connection
        self.onClose = onClose
        _model = State(initialValue: DatabricksCatalogSchemaSettingsModel(connection: connection))
    }

    var body: some View {
        @Bindable var model = model
        GeometryReader { geometry in
            ZStack {
                Button(action: close) { Color.black.opacity(0.16).ignoresSafeArea() }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 16) {
                    Text(L10n.databricksCatalogSchema).font(.dahliaTitle2).accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(connection.displayName)
                        Text(connection.hostName).font(.dahliaSecondary)
                    }
                    .foregroundStyle(.secondary)
                    Text(L10n.databricksCatalogSchemaDescription)
                        .fixedSize(horizontal: false, vertical: true)

                    Form {
                        Section {
                            DahliaMenuPicker(
                                title: L10n.databricksCatalog,
                                selection: Binding(get: { model.catalog }, set: model.selectCatalog),
                                options: [""] + model.catalogs
                            ) { $0.isEmpty ? L10n.databricksSelectCatalog : $0 }
                                .disabled(model.isLoadingCatalogs || model.isCreating || model.isSaving)

                            DahliaMenuPicker(title: L10n.databricksSchema, selection: $model.schema, options: [""] + model.schemas) {
                                $0.isEmpty ? L10n.databricksSelectSchema : $0
                            }
                            .disabled(model.catalog.isEmpty || model.isLoadingSchemas || model.isCreating || model.isSaving)

                            if model.isLoadingCatalogs || model.isLoadingSchemas {
                                ProgressView().controlSize(.small)
                            } else if model.catalogs.isEmpty, model.errorMessage == nil {
                                Text(L10n.databricksNoCatalogs).foregroundStyle(.secondary)
                            } else if !model.catalog.isEmpty, model.schemas.isEmpty, model.errorMessage == nil {
                                Text(L10n.databricksNoSchemas).foregroundStyle(.secondary)
                            }

                            Button(L10n.reload) { Task { await model.loadCatalogs() } }
                                .buttonStyle(.dahlia())
                                .disabled(model.isLoadingCatalogs || model.isCreating || model.isSaving)
                        }

                        Section {
                            DisclosureGroup(L10n.databricksCreateSchema, isExpanded: $showsNewSchema) {
                                TextField(L10n.databricksSchemaName, text: $model.newSchemaName)
                                    .disabled(model.isCreating || model.isSaving)
                                Text(L10n.databricksCreateSchemaDescription(model.catalog))
                                    .font(.dahliaSecondary)
                                    .foregroundStyle(.secondary)
                                Button(L10n.create) { creation = Task { await model.createSchema() } }
                                    .buttonStyle(.dahlia())
                                    .disabled(!model.canCreate)
                                if model.isCreating { ProgressView().controlSize(.small) }
                            }
                            .disabled(model.catalog.isEmpty || model.isLoadingSchemas)
                        }
                    }
                    .formStyle(.grouped)
                    .frame(idealHeight: showsNewSchema ? 340 : 240, maxHeight: showsNewSchema ? 340 : 240)

                    if let created = model.createdSchema {
                        SettingsStatusMessage(text: L10n.databricksSchemaCreated(created), systemImage: "checkmark.circle", tint: .green)
                    }
                    if let error = model.errorMessage {
                        SettingsStatusMessage(text: error, systemImage: "exclamationmark.triangle", tint: .orange)
                    }
                    HStack {
                        Button(L10n.databricksClearCatalogSchema) {
                            Task { if await model.clear() { close() } }
                        }
                        .buttonStyle(.dahlia())
                        .disabled(!model.canClear || model.isCreating || model.isSaving)
                        Spacer()
                        Button(L10n.cancel, action: close).buttonStyle(.dahlia())
                            .keyboardShortcut(.cancelAction)
                            .disabled(model.isCreating || model.isSaving)
                        Button(L10n.save) { Task { if await model.save() { close() } } }
                            .buttonStyle(.dahlia(.primary))
                            .keyboardShortcut(.defaultAction)
                            .disabled(!model.canSave)
                    }
                }
                .font(.dahliaBody)
                .padding(24)
                .frame(width: 560)
                .dahliaModalSurface()
                .frame(maxHeight: max(0, geometry.size.height - 48))
            }
        }
        .task { await model.loadCatalogs() }
        .task(id: model.catalog) { await model.loadSchemas() }
        .onDisappear { creation?.cancel() }
    }

    private func close() {
        guard !model.isCreating, !model.isSaving else { return }
        onClose()
    }
}

extension MainWindowNavigation {
    /// Every feature edits the provider account's common namespace through this modal.
    func editDatabricksCatalogSchema(for connection: DatabricksConnection) {
        presentSettingsModal(DatabricksCatalogSchemaSettingsModal(connection: connection, onClose: dismissSettingsModal))
    }
}
