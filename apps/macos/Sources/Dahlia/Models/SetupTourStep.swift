/// Raw values are persisted between launches; 0 was the removed workspace step and restores as `account`.
enum SetupTourStep: Int, CaseIterable, Identifiable {
    case workingLanguages = 1
    case permissions = 2
    case modelProvider = 3
    case calendar = 4
    case completion = 5
    case account = 6
    case pi = 7

    static let allCases: [Self] = [
        .account,
        .pi,
        .modelProvider,
        .workingLanguages,
        .permissions,
        .calendar,
        .completion,
    ]

    var id: Self { self }

    var title: String {
        switch self {
        case .account: L10n.account
        case .pi: L10n.installPi
        case .workingLanguages: L10n.workingLanguages
        case .permissions: L10n.permissions
        case .modelProvider: L10n.modelProvider
        case .calendar: L10n.calendarSetupTitle
        case .completion: L10n.setupComplete
        }
    }

    var description: String {
        switch self {
        case .account: L10n.accountSetupDescription
        case .pi: L10n.piSetupDescription
        case .workingLanguages: L10n.workingLanguagesSetupDescription
        case .permissions: L10n.audioPermissionSetupDescription
        case .modelProvider: L10n.modelProviderSetupDescription
        case .calendar: L10n.calendarSetupDescription
        case .completion: L10n.setupCompletionDescription
        }
    }
}
