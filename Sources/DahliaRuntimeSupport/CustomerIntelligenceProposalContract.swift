import Foundation

public enum CustomerIntelligenceResourceKind: String, Codable, CaseIterable, Sendable {
    case organization
    case contact
    case project
    case meeting
    case topic
}

public enum CustomerIntelligenceProposalLimits {
    public static let maximumBatchCount = 100
    public static let maximumCollectionCount = 100
    public static let maximumLocalKeyUTF8Count = 128
    public static let maximumTextUTF8Count = 4096
    public static let maximumExpectationValueUTF8Count = 1_048_576
    public static let maximumEncodedPayloadBytes = 1_572_864
    public static let maximumEncodedBatchBytes = 3_145_728

    public static func contains(_ input: CustomerIntelligenceProposalInput) -> Bool {
        guard containsLocalKey(input.localKey),
              input.dependsOn.count <= maximumCollectionCount,
              Set(input.dependsOn).count == input.dependsOn.count,
              input.dependsOn.allSatisfy(containsLocalKey),
              input.evidence.count <= maximumCollectionCount,
              Set(input.evidence.map {
                  "\($0.resourceType.rawValue):\($0.resourceID.uuidString.lowercased())"
              }).count == input.evidence.count,
              input.evidence.allSatisfy({ containsText($0.note) }),
              contains(input.payload),
              containsOnlyOperationFields(input)
        else {
            return false
        }
        return encodedPayloadSize(input.payload).map { $0 <= maximumEncodedPayloadBytes } == true
            && encodedInputSize(input).map { $0 <= maximumEncodedPayloadBytes } == true
    }

    public static func containsBatch(_ inputs: [CustomerIntelligenceProposalInput]) -> Bool {
        guard (1 ... maximumBatchCount).contains(inputs.count),
              inputs.allSatisfy(contains)
        else {
            return false
        }
        return inputs.reduce(into: 0) { total, input in
            total += encodedInputSize(input) ?? maximumEncodedBatchBytes + 1
        } <= maximumEncodedBatchBytes
    }

    public static func containsTopicReferences(
        _ references: [CustomerIntelligenceTopicReferenceInput]
    ) -> Bool {
        guard references.count <= maximumCollectionCount else { return false }
        let identities = references.map {
            "\($0.resourceType.rawValue):"
                + ($0.resourceID?.uuidString.lowercased() ?? "local:\($0.resourceLocalKey ?? "")")
        }
        return Set(identities).count == identities.count && references.allSatisfy { reference in
            reference.resourceType != .topic
                && (reference.resourceID == nil) != (reference.resourceLocalKey == nil)
                && reference.resourceLocalKey.map(containsLocalKey) ?? true
                && containsText(reference.note)
                && (reference.resourceType == .meeting
                    ? reference.note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    : reference.note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)
        }
    }

    private static func contains(_ payload: CustomerIntelligenceProposalPayload) -> Bool {
        let localKeys = [
            payload.parentOrganizationLocalKey,
            payload.organizationLocalKey,
            payload.contactLocalKey,
        ].compactMap(\.self)
        let textValues = [
            payload.nodeKind,
            payload.name,
            payload.email,
            payload.roleLabel,
            payload.title,
            payload.currentState,
        ]
        guard localKeys.allSatisfy(containsLocalKey),
              textValues.allSatisfy(containsText),
              payload.expectations.count <= maximumCollectionCount,
              payload.expectations.allSatisfy({
                  containsText($0.field)
                      && ($0.value?.utf8.count ?? 0) <= maximumExpectationValueUTF8Count
              }),
              payload.references.map(containsTopicReferences) ?? true,
              !hasBoth(payload.parentOrganizationID, payload.parentOrganizationLocalKey),
              !hasBoth(payload.organizationID, payload.organizationLocalKey),
              !hasBoth(payload.contactID, payload.contactLocalKey)
        else {
            return false
        }
        return true
    }

    private static func containsLocalKey(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && value.utf8.count <= maximumLocalKeyUTF8Count
    }

    private static func containsText(_ value: String?) -> Bool {
        (value?.utf8.count ?? 0) <= maximumTextUTF8Count
    }

    private static func hasBoth(_ id: UUID?, _ localKey: String?) -> Bool {
        id != nil && localKey != nil
    }

    private static func containsOnlyOperationFields(_ input: CustomerIntelligenceProposalInput) -> Bool {
        let payload = input.payload
        let targetIsNil = payload.targetID == nil
        let parentIsNil = payload.parentOrganizationID == nil && payload.parentOrganizationLocalKey == nil
        let organizationIsNil = payload.organizationID == nil && payload.organizationLocalKey == nil
        let contactIsNil = payload.contactID == nil && payload.contactLocalKey == nil
        let nodeIsNil = payload.nodeKind == nil
        let nameIsNil = payload.name == nil
        let emailIsNil = payload.email == nil
        let roleIsNil = payload.roleLabel == nil
        let titleIsNil = payload.title == nil
        let stateIsNil = payload.currentState == nil
        let referencesAreNil = payload.references == nil

        return switch input.operationType {
        case .createOrganization:
            organizationIsNil && contactIsNil && emailIsNil && roleIsNil
                && titleIsNil && stateIsNil && referencesAreNil
        case .renameOrganization:
            parentIsNil && organizationIsNil && contactIsNil && nodeIsNil
                && emailIsNil && roleIsNil && titleIsNil && stateIsNil && referencesAreNil
        case .moveOrganization:
            organizationIsNil && contactIsNil && nodeIsNil && nameIsNil
                && emailIsNil && roleIsNil && titleIsNil && stateIsNil && referencesAreNil
        case .createProvisionalContact, .renameProvisionalContact:
            parentIsNil && organizationIsNil && contactIsNil && nodeIsNil
                && emailIsNil && roleIsNil && titleIsNil && stateIsNil && referencesAreNil
        case .resolveProvisionalContact:
            parentIsNil && organizationIsNil && contactIsNil && nodeIsNil
                && nameIsNil && roleIsNil && titleIsNil && stateIsNil && referencesAreNil
        case .setMembership:
            targetIsNil && parentIsNil && nodeIsNil && nameIsNil && emailIsNil
                && titleIsNil && stateIsNil && referencesAreNil
        case .removeMembership:
            targetIsNil && parentIsNil && nodeIsNil && nameIsNil && emailIsNil && roleIsNil
                && titleIsNil && stateIsNil && referencesAreNil
        case .createTopic:
            parentIsNil && organizationIsNil && contactIsNil && nodeIsNil
                && nameIsNil && emailIsNil && roleIsNil
        case .updateTopic:
            parentIsNil && organizationIsNil && contactIsNil && nodeIsNil
                && nameIsNil && emailIsNil && roleIsNil && referencesAreNil
        case .setTopicReferences:
            parentIsNil && organizationIsNil && contactIsNil && nodeIsNil
                && nameIsNil && emailIsNil && roleIsNil && titleIsNil && stateIsNil
        }
    }

    private static func encodedPayloadSize(_ payload: CustomerIntelligenceProposalPayload) -> Int? {
        try? JSONEncoder().encode(payload).count
    }

    private static func encodedInputSize(_ input: CustomerIntelligenceProposalInput) -> Int? {
        try? JSONEncoder().encode(input).count
    }
}

public enum CustomerIntelligenceTopicReferenceExpectation {
    public struct Item: Codable, Equatable, Sendable {
        public let resourceType: String
        public let resourceID: UUID
        public let note: String?

        public init(resourceType: String, resourceID: UUID, note: String?) {
            self.resourceType = resourceType
            self.resourceID = resourceID
            self.note = note
        }
    }

    public static func encode(_ items: [Item]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(items)
        guard let value = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                items,
                .init(codingPath: [], debugDescription: "JSONEncoder produced non-UTF-8 data")
            )
        }
        return value
    }
}

public enum CustomerIntelligenceProposalOperationType: String, Codable, CaseIterable, Sendable {
    case createOrganization = "create_organization"
    case renameOrganization = "rename_organization"
    case moveOrganization = "move_organization"
    case createProvisionalContact = "create_provisional_contact"
    case renameProvisionalContact = "rename_provisional_contact"
    case resolveProvisionalContact = "resolve_provisional_contact"
    case setMembership = "set_membership"
    case removeMembership = "remove_membership"
    case createTopic = "create_topic"
    case updateTopic = "update_topic"
    case setTopicReferences = "set_topic_references"

    public var allowedExpectationFields: Set<String> {
        switch self {
        case .createOrganization, .createProvisionalContact, .createTopic:
            []
        case .renameOrganization:
            ["name"]
        case .moveOrganization:
            ["parent_organization_id"]
        case .renameProvisionalContact, .resolveProvisionalContact:
            ["display_name", "email"]
        case .setMembership, .removeMembership:
            ["role_label"]
        case .updateTopic:
            ["title", "current_state"]
        case .setTopicReferences:
            ["references"]
        }
    }

    public func requiredExpectationFields(
        for payload: CustomerIntelligenceProposalPayload
    ) -> Set<String> {
        switch self {
        case .createOrganization, .createProvisionalContact, .createTopic:
            []
        case .renameOrganization:
            ["name"]
        case .moveOrganization:
            ["parent_organization_id"]
        case .renameProvisionalContact:
            ["display_name"]
        case .resolveProvisionalContact:
            ["email"]
        case .setMembership, .removeMembership:
            ["role_label"]
        case .updateTopic:
            Set([
                payload.title == nil ? nil : "title",
                payload.currentState == nil ? nil : "current_state",
            ].compactMap(\.self))
        case .setTopicReferences:
            ["references"]
        }
    }
}

public struct CustomerIntelligenceFieldExpectation: Codable, Equatable, Sendable {
    public let field: String
    public let value: String?

    public init(field: String, value: String?) {
        self.field = field
        self.value = value
    }
}

public struct CustomerIntelligenceTopicReferenceInput: Codable, Equatable, Sendable {
    public let resourceType: CustomerIntelligenceResourceKind
    public var resourceID: UUID?
    public var resourceLocalKey: String?
    public let note: String?

    public init(
        resourceType: CustomerIntelligenceResourceKind,
        resourceID: UUID? = nil,
        resourceLocalKey: String? = nil,
        note: String? = nil
    ) {
        self.resourceType = resourceType
        self.resourceID = resourceID
        self.resourceLocalKey = resourceLocalKey
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case resourceType = "resource_type"
        case resourceID = "resource_id"
        case resourceLocalKey = "resource_local_key"
        case note
    }
}

/// A compact, typed operation payload shared by the app and its MCP helper.
///
/// Optional fields are interpreted only by `operationType`; this keeps the persisted
/// operation stable while the server performs operation-specific validation.
public struct CustomerIntelligenceProposalPayload: Codable, Equatable, Sendable {
    public var targetID: UUID?
    public var parentOrganizationID: UUID?
    public var organizationID: UUID?
    public var contactID: UUID?
    public var parentOrganizationLocalKey: String?
    public var organizationLocalKey: String?
    public var contactLocalKey: String?
    public var nodeKind: String?
    public var name: String?
    public var email: String?
    public var roleLabel: String?
    public var title: String?
    public var currentState: String?
    public var references: [CustomerIntelligenceTopicReferenceInput]?
    public var expectations: [CustomerIntelligenceFieldExpectation]

    public init(
        targetID: UUID? = nil,
        parentOrganizationID: UUID? = nil,
        organizationID: UUID? = nil,
        contactID: UUID? = nil,
        parentOrganizationLocalKey: String? = nil,
        organizationLocalKey: String? = nil,
        contactLocalKey: String? = nil,
        nodeKind: String? = nil,
        name: String? = nil,
        email: String? = nil,
        roleLabel: String? = nil,
        title: String? = nil,
        currentState: String? = nil,
        references: [CustomerIntelligenceTopicReferenceInput]? = nil,
        expectations: [CustomerIntelligenceFieldExpectation] = []
    ) {
        self.targetID = targetID
        self.parentOrganizationID = parentOrganizationID
        self.organizationID = organizationID
        self.contactID = contactID
        self.parentOrganizationLocalKey = parentOrganizationLocalKey
        self.organizationLocalKey = organizationLocalKey
        self.contactLocalKey = contactLocalKey
        self.nodeKind = nodeKind
        self.name = name
        self.email = email
        self.roleLabel = roleLabel
        self.title = title
        self.currentState = currentState
        self.references = references
        self.expectations = expectations
    }

    public var referencedIDs: Set<UUID> {
        var ids = Set([targetID, parentOrganizationID, organizationID, contactID].compactMap(\.self))
        ids.formUnion(references?.compactMap(\.resourceID) ?? [])
        return ids
    }

    public var referencedLocalKeys: Set<String> {
        var keys = Set([
            parentOrganizationLocalKey,
            organizationLocalKey,
            contactLocalKey,
        ].compactMap(\.self))
        keys.formUnion(references?.compactMap(\.resourceLocalKey) ?? [])
        return keys
    }

    public func expectation(for field: String) -> CustomerIntelligenceFieldExpectation? {
        expectations.first { $0.field == field }
    }

    enum CodingKeys: String, CodingKey {
        case targetID = "target_id"
        case parentOrganizationID = "parent_organization_id"
        case organizationID = "organization_id"
        case contactID = "contact_id"
        case parentOrganizationLocalKey = "parent_organization_local_key"
        case organizationLocalKey = "organization_local_key"
        case contactLocalKey = "contact_local_key"
        case nodeKind = "node_kind"
        case name
        case email
        case roleLabel = "role_label"
        case title
        case currentState = "current_state"
        case references
        case expectations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        targetID = try container.decodeIfPresent(UUID.self, forKey: .targetID)
        parentOrganizationID = try container.decodeIfPresent(UUID.self, forKey: .parentOrganizationID)
        organizationID = try container.decodeIfPresent(UUID.self, forKey: .organizationID)
        contactID = try container.decodeIfPresent(UUID.self, forKey: .contactID)
        parentOrganizationLocalKey = try container.decodeIfPresent(String.self, forKey: .parentOrganizationLocalKey)
        organizationLocalKey = try container.decodeIfPresent(String.self, forKey: .organizationLocalKey)
        contactLocalKey = try container.decodeIfPresent(String.self, forKey: .contactLocalKey)
        nodeKind = try container.decodeIfPresent(String.self, forKey: .nodeKind)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        roleLabel = try container.decodeIfPresent(String.self, forKey: .roleLabel)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        currentState = try container.decodeIfPresent(String.self, forKey: .currentState)
        references = try container.decodeIfPresent(
            [CustomerIntelligenceTopicReferenceInput].self,
            forKey: .references
        )
        expectations = try container.decodeIfPresent(
            [CustomerIntelligenceFieldExpectation].self,
            forKey: .expectations
        ) ?? []
    }
}

public struct CustomerIntelligenceProposalEvidenceInput: Codable, Equatable, Sendable {
    public let resourceType: CustomerIntelligenceResourceKind
    public let resourceID: UUID
    public let note: String?

    public init(resourceType: CustomerIntelligenceResourceKind, resourceID: UUID, note: String? = nil) {
        self.resourceType = resourceType
        self.resourceID = resourceID
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case resourceType = "resource_type"
        case resourceID = "resource_id"
        case note
    }
}

public struct CustomerIntelligenceProposalInput: Codable, Equatable, Sendable {
    public let localKey: String
    public let operationType: CustomerIntelligenceProposalOperationType
    public var payload: CustomerIntelligenceProposalPayload
    public let evidence: [CustomerIntelligenceProposalEvidenceInput]
    public let dependsOn: [String]

    public init(
        localKey: String,
        operationType: CustomerIntelligenceProposalOperationType,
        payload: CustomerIntelligenceProposalPayload,
        evidence: [CustomerIntelligenceProposalEvidenceInput] = [],
        dependsOn: [String] = []
    ) {
        self.localKey = localKey
        self.operationType = operationType
        self.payload = payload
        self.evidence = evidence
        self.dependsOn = dependsOn
    }

    enum CodingKeys: String, CodingKey {
        case localKey = "local_key"
        case operationType = "operation_type"
        case payload
        case evidence
        case dependsOn = "depends_on"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        localKey = try container.decode(String.self, forKey: .localKey)
        operationType = try container.decode(CustomerIntelligenceProposalOperationType.self, forKey: .operationType)
        payload = try container.decode(CustomerIntelligenceProposalPayload.self, forKey: .payload)
        evidence = try container.decodeIfPresent(
            [CustomerIntelligenceProposalEvidenceInput].self,
            forKey: .evidence
        ) ?? []
        dependsOn = try container.decodeIfPresent([String].self, forKey: .dependsOn) ?? []
    }
}
