import SwiftUI

struct PermissionSettingsView: View {
    @State private var model: PermissionGuideModel
    private let permissions: [AppPermission]
    private let showsDescription: Bool
    private let showsPermissionFooters: Bool
    private let prominentLabels: Bool
    @Environment(\.scenePhase) private var scenePhase

    @MainActor
    init(
        permissions: [AppPermission] = AppPermission.allCases,
        showsDescription: Bool = true,
        showsPermissionFooters: Bool = true,
        prominentLabels: Bool = false,
        model: PermissionGuideModel = PermissionGuideModel()
    ) {
        self.permissions = permissions
        self.showsDescription = showsDescription
        self.showsPermissionFooters = showsPermissionFooters
        self.prominentLabels = prominentLabels
        _model = State(initialValue: model)
    }

    var body: some View {
        Form {
            if showsDescription {
                Section {
                    Text(L10n.permissionGuideDescription)
                        .foregroundStyle(DahliaDesign.secondaryTextColor)
                }
            }

            ForEach(permissions) { permission in
                Section {
                    PermissionSettingsRow(
                        permission: permission,
                        status: model.status(for: permission),
                        isRequesting: model.requestingPermission == permission,
                        actionsDisabled: model.requestingPermission != nil,
                        prominentLabel: prominentLabels
                    ) {
                        Task {
                            await model.performPrimaryAction(for: permission)
                        }
                    }
                } footer: {
                    if showsPermissionFooters {
                        VStack(alignment: .leading, spacing: 4) {
                            if let guidance = permission.guidance(for: model.status(for: permission)) {
                                Text(guidance)
                            }
                            if let footer = permission.footer {
                                Text(footer)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            model.refresh()
        }
        .alert(L10n.systemSettingsOpenFailed, isPresented: $model.settingsOpenFailed) {} message: {
            Text(L10n.systemSettingsOpenFailedDescription)
        }
    }
}

private struct PermissionSettingsRow: View {
    let permission: AppPermission
    let status: AppPermissionStatus
    let isRequesting: Bool
    let actionsDisabled: Bool
    let prominentLabel: Bool
    let action: () -> Void

    var body: some View {
        if prominentLabel {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: permission.systemImage)
                    .font(.title)
                    .frame(width: 40)
                    .dahliaFixedSymbol()

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(permission.title)
                            .font(.title2)
                            .bold()
                        Label(status.label, systemImage: status.systemImage)
                            .foregroundStyle(statusColor)
                            .fixedSize()
                    }
                    Text(permission.description)
                        .foregroundStyle(DahliaDesign.secondaryTextColor)
                }
                .layoutPriority(1)

                Spacer(minLength: 16)

                actionButton
            }
        } else {
            LabeledContent {
                actionButton
            } label: {
                Label {
                    VStack(alignment: .leading) {
                        Text(permission.title)
                        Text(permission.description)
                            .foregroundStyle(DahliaDesign.secondaryTextColor)
                        Label(status.label, systemImage: status.systemImage)
                            .foregroundStyle(statusColor)
                    }
                } icon: {
                    Image(systemName: permission.systemImage)
                        .dahliaFixedSymbol()
                }
            }
        }
    }

    private var actionButton: some View {
        Group {
            if isRequestable {
                baseButton
                    .buttonStyle(.dahlia(.primary))
            } else {
                baseButton
                    .buttonStyle(.dahlia())
            }
        }
        .disabled(actionsDisabled)
        .accessibilityLabel(accessibilityActionLabel)
        .accessibilityHint(permission.description)
    }

    private var baseButton: some View {
        Button(action: action) {
            actionButtonLabel
                .frame(minWidth: prominentLabel ? 132 : nil, minHeight: prominentLabel ? 28 : nil)
        }
        .controlSize(prominentLabel ? .large : .regular)
    }

    @ViewBuilder
    private var actionButtonLabel: some View {
        if isRequesting {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(actionLabel)
        } else {
            Text(actionLabel)
        }
    }

    private var actionLabel: String {
        switch status {
        case .notDetermined:
            L10n.allowAccess
        case .requiresReview:
            L10n.checkAccess
        case .granted, .denied, .restricted:
            L10n.openSystemSettings
        }
    }

    private var isRequestable: Bool {
        status == .notDetermined || status == .requiresReview
    }

    private var accessibilityActionLabel: Text {
        Text("\(permission.title), \(actionLabel)")
    }

    private var statusColor: Color {
        switch status {
        case .notDetermined, .requiresReview:
            .secondary
        case .granted:
            .green
        case .denied, .restricted:
            .orange
        }
    }
}
