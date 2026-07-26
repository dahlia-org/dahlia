import Foundation

enum CustomerIntelligenceError: LocalizedError, Equatable {
    case invalidEmail
    case invalidDomain
    case invalidName
    case invalidDefinition
    case invalidJSON
    case vaultNotFound
    case contactNotFound
    case organizationNotFound
    case projectNotFound
    case insightNotFound
    case glossaryTermNotFound
    case invalidOrganizationParent
    case organizationCycle
    case organizationHierarchyTooDeep
    case domainAlreadyAssigned
    case unsupportedProjectResource

    var errorDescription: String? {
        switch self {
        case .invalidEmail:
            "The contact email address is invalid."
        case .invalidDomain:
            "The organization domain is invalid."
        case .invalidName:
            "The name is invalid."
        case .invalidDefinition:
            "The glossary definition is invalid."
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
        case .glossaryTermNotFound:
            "The glossary term was not found."
        case .invalidOrganizationParent:
            "The organization parent is invalid."
        case .organizationCycle:
            "The organization hierarchy cannot contain a cycle."
        case .organizationHierarchyTooDeep:
            "The organization hierarchy exceeds the maximum depth."
        case .domainAlreadyAssigned:
            "The domain is already assigned to another organization."
        case .unsupportedProjectResource:
            "Projects can reference only organizations and contacts."
        }
    }
}
