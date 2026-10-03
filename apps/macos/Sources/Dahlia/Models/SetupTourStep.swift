enum SetupTourStep: Int, CaseIterable, Identifiable {
    case workspace
    case workingLanguages
    case permissions
    case modelProvider
    case calendar
    case completion
    case account = 6 // Existing raw values are persisted between launches.

    static let allCases: [Self] = [
        .account,
        .workspace,
        .workingLanguages,
        .permissions,
        .modelProvider,
        .calendar,
        .completion,
    ]

    var id: Self { self }

    var title: String {
        switch self {
        case .account: L10n.dahliaAccount
        case .workspace: L10n.workspace
        case .workingLanguages: L10n.workingLanguages
        case .permissions: L10n.permissions
        case .modelProvider: L10n.modelProvider
        case .calendar: L10n.calendarSetupTitle
        case .completion: L10n.setupComplete
        }
    }

    var description: String {
        switch self {
        case .account: L10n.dahliaSignInDescription
        case .workspace: L10n.workspaceSetupDescription
        case .workingLanguages: L10n.workingLanguagesSetupDescription
        case .permissions: L10n.audioPermissionSetupDescription
        case .modelProvider: L10n.modelProviderSetupDescription
        case .calendar: L10n.calendarSetupDescription
        case .completion: L10n.setupCompletionDescription
        }
    }
}
