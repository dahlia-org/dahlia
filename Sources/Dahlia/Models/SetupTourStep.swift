enum SetupTourStep: Int, CaseIterable, Identifiable {
    case vault
    case workingLanguages
    case permissions
    case modelProvider
    case calendar
    case completion

    var id: Self { self }

    var title: String {
        switch self {
        case .vault: L10n.vault
        case .workingLanguages: L10n.workingLanguages
        case .permissions: L10n.permissions
        case .modelProvider: L10n.modelProvider
        case .calendar: L10n.calendarSetupTitle
        case .completion: L10n.setupComplete
        }
    }

    var description: String {
        switch self {
        case .vault: L10n.vaultSetupDescription
        case .workingLanguages: L10n.workingLanguagesSetupDescription
        case .permissions: L10n.audioPermissionSetupDescription
        case .modelProvider: L10n.modelProviderSetupDescription
        case .calendar: L10n.calendarSetupDescription
        case .completion: L10n.setupCompletionDescription
        }
    }
}
