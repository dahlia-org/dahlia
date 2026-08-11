import DahliaRuntimeSupport
import Foundation
import GRDB
import Observation

@MainActor
@Observable
final class CustomerIntelligenceContactsViewModel {
    enum Filter: String, CaseIterable, Identifiable {
        case all
        case unassigned
        case emailMissing

        var id: String { rawValue }
    }

    struct PendingResolution: Identifiable {
        let provisional: ContactRecord
        let existing: ContactRecord
        let displayName: String
        let email: String

        var id: UUID { provisional.id }
    }

    struct PendingDeletion: Identifiable {
        let contact: ContactRecord
        let impact: ProvisionalContactDeletionImpact

        var id: UUID { contact.id }
    }

    var searchText = ""
    var filter = Filter.all
    private(set) var contacts: [CustomerIntelligenceWorkspaceData.ContactSummary] = []
    private(set) var organizations: [OrganizationRecord] = []
    private(set) var detail: CustomerIntelligenceWorkspaceData.ContactDetail?
    private(set) var isLoading = false
    private(set) var isSaving = false
    var errorMessage: String?
    var pendingResolution: PendingResolution?
    var pendingDeletion: PendingDeletion?

    private let dbQueue: DatabaseQueue
    private let vaultID: UUID
    private let scope: CustomerIntelligenceScope
    private var loadGeneration = 0
    private var detailGeneration = 0
    private let notificationSenderID =
        CustomerIntelligenceWorkspaceViewModel.sectionMutationSenderPrefix + UUID().uuidString

    init(dbQueue: DatabaseQueue, vaultID: UUID, scope: CustomerIntelligenceScope) {
        self.dbQueue = dbQueue
        self.vaultID = vaultID
        self.scope = scope
    }

    var filteredContacts: [CustomerIntelligenceWorkspaceData.ContactSummary] {
        contacts.filter {
            let matchesFilter = switch filter {
            case .all: true
            case .unassigned: $0.membershipCount == 0
            case .emailMissing: $0.contact.email == nil
            }
            guard matchesFilter, let query = searchText.nilIfBlank else { return matchesFilter }
            return [$0.contact.displayName, $0.contact.email]
                .compactMap(\.self)
                .contains { $0.localizedStandardContains(query) }
        }
    }

    func load(selectedID: UUID? = nil) async {
        loadGeneration += 1
        detailGeneration += 1
        let generation = loadGeneration
        let requestedDetailGeneration = detailGeneration
        isLoading = true
        detail = nil
        defer {
            if generation == loadGeneration {
                isLoading = false
            }
        }
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let repository = MeetingRepository(dbQueue: self.dbQueue)
                let contacts = try repository.fetchCustomerIntelligenceContacts(
                    vaultId: self.vaultID,
                    scope: self.scope
                )
                let organizations = try repository.fetchOrganizations(vaultId: self.vaultID)
                let detail = try selectedID.flatMap {
                    try repository.fetchCustomerIntelligenceContactDetail(id: $0, vaultId: self.vaultID)
                }
                return (contacts, organizations, detail)
            }.value
            guard generation == loadGeneration else { return }
            contacts = result.0
            organizations = result.1
            if requestedDetailGeneration == detailGeneration {
                detail = result.2
            }
            errorMessage = nil
        } catch {
            guard generation == loadGeneration else { return }
            setError(error)
        }
    }

    func select(_ id: UUID?) async {
        detailGeneration += 1
        let generation = detailGeneration
        detail = nil
        guard let id else {
            return
        }
        do {
            let loadedDetail = try await Task.detached(priority: .userInitiated) {
                try MeetingRepository(dbQueue: self.dbQueue)
                    .fetchCustomerIntelligenceContactDetail(id: id, vaultId: self.vaultID)
            }.value
            guard generation == detailGeneration else { return }
            detail = loadedDetail
            errorMessage = nil
        } catch {
            guard generation == detailGeneration else { return }
            setError(error)
        }
    }
}

extension CustomerIntelligenceContactsViewModel {
    func create(displayName: String, email rawEmail: String, organizationID: UUID?) async -> UUID? {
        let displayName = displayName.nilIfBlank
        let email = rawEmail.nilIfBlank.flatMap(CustomerIdentityNormalizer.email)
        guard displayName != nil || email != nil else {
            errorMessage = L10n.customerIntelligenceContactNameRequired
            return nil
        }
        if rawEmail.nilIfBlank != nil, email == nil {
            errorMessage = L10n.customerIntelligenceInvalidEmail
            return nil
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let contact = try await Task.detached(priority: .userInitiated) {
                let repository = MeetingRepository(dbQueue: self.dbQueue)
                let contact: ContactRecord
                if let email {
                    contact = try repository.upsertContact(
                        vaultId: self.vaultID,
                        email: email,
                        displayName: displayName
                    )
                    if let organizationID {
                        _ = try repository.addOrganizationMembership(
                            organizationId: organizationID,
                            contactId: contact.id
                        )
                    }
                } else {
                    contact = try repository.createProvisionalContact(
                        vaultId: self.vaultID,
                        displayName: displayName ?? "",
                        organizationId: organizationID
                    )
                }
                return contact
            }.value
            await didMutate(selecting: contact.id)
            return contact.id
        } catch {
            setError(error)
            return nil
        }
    }

    func save(contact: ContactRecord, displayName: String, email rawEmail: String) async -> Bool {
        guard let displayName = displayName.nilIfBlank else {
            errorMessage = L10n.customerIntelligenceContactNameRequired
            return false
        }
        if contact.isProvisional,
           rawEmail.nilIfBlank != nil,
           CustomerIdentityNormalizer.email(rawEmail) == nil {
            errorMessage = L10n.customerIntelligenceInvalidEmail
            return false
        }
        isSaving = true
        defer { isSaving = false }
        do {
            if contact.isProvisional, let email = CustomerIdentityNormalizer.email(rawEmail) {
                let existing = try await Task.detached(priority: .userInitiated) {
                    try MeetingRepository(dbQueue: self.dbQueue)
                        .fetchContact(vaultId: self.vaultID, normalizedEmail: email)
                }.value
                if let existing, existing.id != contact.id {
                    pendingResolution = PendingResolution(
                        provisional: contact,
                        existing: existing,
                        displayName: displayName,
                        email: email
                    )
                    return false
                }
                _ = try await resolve(
                    contact: contact,
                    displayName: displayName,
                    email: email,
                    existing: nil
                )
            } else {
                _ = try await Task.detached(priority: .userInitiated) {
                    try MeetingRepository(dbQueue: self.dbQueue).updateContactDisplayName(
                        id: contact.id,
                        vaultId: self.vaultID,
                        displayName: displayName,
                        expectedRevision: contact.revision
                    )
                }.value
            }
            await didMutate(selecting: contact.id)
            return true
        } catch {
            setError(error)
            return false
        }
    }

    func confirmResolution(_ pending: PendingResolution) async -> Bool {
        isSaving = true
        defer { isSaving = false }
        do {
            let resolved = try await resolve(
                contact: pending.provisional,
                displayName: pending.displayName,
                email: pending.email,
                existing: pending.existing
            )
            pendingResolution = nil
            await didMutate(selecting: resolved.id)
            return true
        } catch {
            setError(error)
            return false
        }
    }

    func setMembership(organizationID: UUID, roleLabel: String?) async -> Bool {
        guard let contactID = detail?.summary.contact.id,
              let organization = organizations.first(where: { $0.id == organizationID })
        else {
            return false
        }
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await Task.detached(priority: .userInitiated) {
                try MeetingRepository(dbQueue: self.dbQueue).addOrganizationMembership(
                    organizationId: organizationID,
                    contactId: contactID,
                    roleLabel: roleLabel,
                    expectedOrganizationRevision: organization.revision
                )
            }.value
            await didMutate(selecting: contactID)
            return true
        } catch {
            setError(error)
            return false
        }
    }

    func removeMembership(organizationID: UUID) async -> Bool {
        guard let contactID = detail?.summary.contact.id,
              let organization = organizations.first(where: { $0.id == organizationID })
        else {
            return false
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try await Task.detached(priority: .userInitiated) {
                try MeetingRepository(dbQueue: self.dbQueue).removeOrganizationMembership(
                    organizationId: organizationID,
                    contactId: contactID,
                    expectedOrganizationRevision: organization.revision
                )
            }.value
            await didMutate(selecting: contactID)
            return true
        } catch {
            setError(error)
            return false
        }
    }

    func prepareDeletion(_ contact: ContactRecord) async {
        do {
            let impact = try await Task.detached(priority: .userInitiated) {
                try MeetingRepository(dbQueue: self.dbQueue)
                    .provisionalContactDeletionImpact(id: contact.id, vaultId: self.vaultID)
            }.value
            pendingDeletion = PendingDeletion(contact: contact, impact: impact)
        } catch {
            setError(error)
        }
    }

    func confirmDeletion(_ pending: PendingDeletion) async -> Bool {
        isSaving = true
        defer { isSaving = false }
        do {
            try await Task.detached(priority: .userInitiated) {
                try MeetingRepository(dbQueue: self.dbQueue).deleteProvisionalContact(
                    id: pending.contact.id,
                    vaultId: self.vaultID,
                    expectedRevision: pending.contact.revision,
                    expectedImpact: pending.impact
                )
            }.value
            pendingDeletion = nil
            await didMutate(selecting: nil)
            return true
        } catch {
            setError(error)
            return false
        }
    }

    private func resolve(
        contact: ContactRecord,
        displayName: String,
        email: String,
        existing: ContactRecord?
    ) async throws -> ContactRecord {
        try await Task.detached(priority: .userInitiated) {
            try MeetingRepository(dbQueue: self.dbQueue).resolveProvisionalContact(
                id: contact.id,
                vaultId: self.vaultID,
                email: email,
                displayName: displayName,
                expectedRevision: contact.revision,
                expectedExistingContactID: existing?.id,
                expectedExistingRevision: existing?.revision
            )
        }.value
    }

    private func didMutate(selecting id: UUID?) async {
        DahliaWorkspaceChangeNotification.post(vaultID: vaultID, senderID: notificationSenderID)
        await load(selectedID: id)
    }

    private func setError(_ error: Error) {
        if let databaseError = error as? DatabaseError,
           databaseError.resultCode == .SQLITE_BUSY || databaseError.resultCode == .SQLITE_LOCKED {
            errorMessage = L10n.organizationWorkspaceBusy
        } else {
            errorMessage = error.localizedDescription
        }
    }
}
