import Foundation

enum CustomerIntelligenceError: LocalizedError, Equatable {
    case invalidEmail
    case invalidDomain
    case invalidName
    case invalidJSON
    case vaultNotFound
    case contactNotFound
    case organizationNotFound
    case projectNotFound
    case insightNotFound
    case invalidOrganizationParent
    case organizationCycle
    case organizationHierarchyTooDeep
    case domainAlreadyAssigned
    case invalidOrganizationMerge
    case unsupportedProjectResource
    case topicNotFound
    case revisionConflict
    case invalidReference
    case provisionalContactRequired
    case provisionalContactHasParticipant

    var errorDescription: String? {
        let message = switch self {
        case .invalidEmail:
            "The contact email address is invalid."
        case .invalidDomain:
            "The organization domain is invalid."
        case .invalidName:
            "The name is invalid."
        case .invalidJSON:
            "The metadata must be a JSON object."
        case .vaultNotFound:
            "The vault was not found."
        case .contactNotFound:
            "The contact was not found."
        case .organizationNotFound:
            "The organization was not found."
        case .projectNotFound:
            "The project was not found."
        case .insightNotFound:
            "The insight was not found."
        case .invalidOrganizationParent:
            "The organization parent is invalid."
        case .organizationCycle:
            "The organization hierarchy cannot contain a cycle."
        case .organizationHierarchyTooDeep:
            "The organization hierarchy exceeds the maximum depth."
        case .domainAlreadyAssigned:
            "The domain is already assigned to another organization."
        case .invalidOrganizationMerge:
            "Only two different root organizations can be merged."
        case .unsupportedProjectResource:
            "Projects can reference only organizations and contacts."
        case .topicNotFound:
            "The conversation topic was not found."
        case .revisionConflict:
            "The record changed after it was read."
        case .invalidReference:
            "The customer intelligence reference is invalid."
        case .provisionalContactRequired:
            "Only a contact without an email address can be changed this way."
        case .provisionalContactHasParticipant:
            "This contact has calendar participation data and cannot be deleted."
        }
        return String(localized: String.LocalizationValue(message), bundle: .module)
    }
}
