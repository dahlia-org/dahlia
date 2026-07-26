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
    case topicNotFound
    case proposalNotFound
    case proposalConflict
    case proposalDependency
    case proposalCycle
    case invalidProposal
    case provisionalContactRequired
    case provisionalContactHasParticipant

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
        case .topicNotFound:
            "The conversation topic was not found."
        case .proposalNotFound:
            "The proposal was not found."
        case .proposalConflict:
            "The proposal conflicts with newer customer intelligence data."
        case .proposalDependency:
            "A required proposal has not been selected or applied."
        case .proposalCycle:
            "Proposal dependencies cannot contain a cycle."
        case .invalidProposal:
            "The proposal operation is invalid."
        case .provisionalContactRequired:
            "Only a provisional contact can be changed this way."
        case .provisionalContactHasParticipant:
            "This provisional contact has calendar participation data and cannot be deleted."
        }
    }
}
