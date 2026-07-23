import SwiftUI

struct PermissionGuideWindowView: View {
    @AppStorage(PermissionGuidePresentationPolicy.userDefaultsKey)
    private var presentationVersion = 0

    var body: some View {
        PermissionSettingsView()
            .onAppear {
                presentationVersion = PermissionGuidePresentationPolicy.currentVersion
            }
    }
}

struct PermissionSettingsView: View {
    @State private var model: PermissionGuideModel
    @Environment(\.scenePhase) private var scenePhase

    @MainActor
    init(model: PermissionGuideModel = PermissionGuideModel()) {
        _model = State(initialValue: model)
    }

    var body: some View {
        Form {
            Section {
                Text(L10n.permissionGuideDescription)
                    .foregroundStyle(.secondary)
            }

            ForEach(AppPermission.allCases) { permission in
                Section {
                    PermissionSettingsRow(
                        permission: permission,
                        status: model.status(for: permission),
                        isRequesting: model.requestingPermission == permission,
                        actionsDisabled: model.requestingPermission != nil
                    ) {
                        Task {
                            await model.performPrimaryAction(for: permission)
                        }
                    }
                } footer: {
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
    let action: () -> Void

    var body: some View {
        LabeledContent {
            actionButton
        } label: {
            Label {
                VStack(alignment: .leading) {
                    Text(permission.title)
                    Text(permission.description)
                        .foregroundStyle(.secondary)
                    Label(status.label, systemImage: status.systemImage)
                        .foregroundStyle(statusColor)
                }
            } icon: {
                Image(systemName: permission.systemImage)
            }
        }
    }

    private var actionButton: some View {
        Group {
            if isRequestable {
                baseButton
                    .buttonStyle(.borderedProminent)
            } else {
                baseButton
                    .buttonStyle(.bordered)
            }
        }
        .disabled(actionsDisabled)
        .accessibilityLabel(accessibilityActionLabel)
        .accessibilityHint(permission.description)
    }

    private var baseButton: some View {
        Button(action: action) {
            actionButtonLabel
        }
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
