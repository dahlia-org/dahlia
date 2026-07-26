import DahliaRuntimeSupport
import Foundation
import GRDB

enum CustomerIntelligencePersistence {
    private struct CanonicalParticipantSelection {
        let participants: [(String, CalendarParticipant)]
        let observedParticipantCount: Int
        let skippedNonPersonCount: Int
        let skippedInvalidEmailCount: Int
        let excludedCurrentUserIdentityCount: Int
        let deduplicatedParticipantCount: Int

        func metrics(ingestedContactCount: Int) -> CustomerIntelligenceIngestionMetrics {
            CustomerIntelligenceIngestionMetrics(
                observedParticipantCount: observedParticipantCount,
                ingestedContactCount: ingestedContactCount,
                skippedNonPersonCount: skippedNonPersonCount,
                skippedInvalidEmailCount: skippedInvalidEmailCount,
                excludedCurrentUserIdentityCount: excludedCurrentUserIdentityCount,
                deduplicatedParticipantCount: deduplicatedParticipantCount
            )
        }
    }

    static func upsertContact(
        vaultId: UUID,
        email rawEmail: String,
        displayName rawDisplayName: String?,
        now: Date,
        in db: Database
    ) throws -> ContactRecord {
        guard let email = CustomerIdentityNormalizer.email(rawEmail) else {
            throw CustomerIntelligenceError.invalidEmail
        }
        guard try VaultRecord.fetchOne(db, key: vaultId) != nil else {
            throw CustomerIntelligenceError.vaultNotFound
        }

        return try upsertCanonicalContact(
            vaultId: vaultId,
            email: email,
            displayName: rawDisplayName,
            now: now,
            in: db
        )
    }

    private static func upsertCanonicalContact(
        vaultId: UUID,
        email: String,
        displayName rawDisplayName: String?,
        now: Date,
        in db: Database
    ) throws -> ContactRecord {
        let displayName = CustomerIdentityNormalizer.displayName(rawDisplayName)
        if var existing = try ContactRecord
            .filter(Column("vaultId") == vaultId && Column("email") == email)
            .fetchOne(db) {
            if existing.displayName == nil, let displayName {
                existing.displayName = displayName
                existing.updatedAt = max(existing.updatedAt, now)
                try existing.update(db)
            }
            return existing
        }

        let contact = ContactRecord(
            id: .v7(),
            vaultId: vaultId,
            email: email,
            displayName: displayName,
            createdAt: now,
            updatedAt: now
        )
        try contact.insert(db)
        return contact
    }

    static func organization(
        forDomain rawDomainName: String,
        vaultId: UUID,
        observedAt: Date,
        automaticallyCreate: Bool,
        in db: Database
    ) throws -> OrganizationRecord? {
        guard let domainName = CustomerIdentityNormalizer.domainName(rawDomainName) else {
            throw CustomerIntelligenceError.invalidDomain
        }
        if var domain = try OrganizationDomainRecord
            .filter(Column("vaultId") == vaultId && Column("domainName") == domainName)
            .fetchOne(db) {
            let firstObservedAt = min(domain.firstObservedAt, observedAt)
            let lastObservedAt = max(domain.lastObservedAt, observedAt)
            if firstObservedAt != domain.firstObservedAt || lastObservedAt != domain.lastObservedAt {
                domain.firstObservedAt = firstObservedAt
                domain.lastObservedAt = lastObservedAt
                try domain.update(db)
            }
            return try OrganizationRecord.fetchOne(db, key: domain.organizationId)
        }
        guard automaticallyCreate else { return nil }

        let organization = OrganizationRecord(
            id: .v7(),
            vaultId: vaultId,
            parentOrganizationId: nil,
            nodeKind: .organization,
            name: domainName,
            createdAt: observedAt,
            updatedAt: observedAt
        )
        try organization.insert(db)
        try OrganizationDomainRecord(
            vaultId: vaultId,
            domainName: domainName,
            organizationId: organization.id,
            isPrimary: false,
            firstObservedAt: observedAt,
            lastObservedAt: observedAt
        ).insert(db)
        return organization
    }

    static func addMembership(
        organizationId: UUID,
        contactId: UUID,
        createdAt: Date,
        in db: Database
    ) throws {
        guard try OrganizationMembershipRecord
            .filter(Column("organizationId") == organizationId && Column("contactId") == contactId)
            .fetchOne(db) == nil
        else {
            return
        }
        try OrganizationMembershipRecord(
            organizationId: organizationId,
            contactId: contactId,
            roleLabel: nil,
            createdAt: createdAt
        ).insert(db)
    }

    static func ingest(
        participants: [CalendarParticipant],
        meetingId: UUID,
        vaultId: UUID,
        observedAt: Date,
        in db: Database
    ) throws -> CustomerIntelligenceIngestionMetrics {
        let selection = canonicalParticipants(participants)
        guard try MeetingRecord
            .filter(Column("id") == meetingId && Column("vaultId") == vaultId)
            .fetchOne(db) != nil
        else {
            return selection.metrics(ingestedContactCount: 0)
        }

        for (email, participant) in selection.participants {
            let contact = try upsertCanonicalContact(
                vaultId: vaultId,
                email: email,
                displayName: participant.displayName,
                now: observedAt,
                in: db
            )
            try upsertMeetingParticipant(
                meetingId: meetingId,
                contactId: contact.id,
                participant: participant,
                observedAt: observedAt,
                in: db
            )

            guard let domainName = CustomerIdentityNormalizer.domainName(fromEmail: email),
                  CustomerIdentityNormalizer.isAutomaticOrganizationDomain(domainName),
                  let organization = try organization(
                      forDomain: domainName,
                      vaultId: vaultId,
                      observedAt: observedAt,
                      automaticallyCreate: true,
                      in: db
                  )
            else {
                continue
            }
            try addMembership(
                organizationId: organization.id,
                contactId: contact.id,
                createdAt: observedAt,
                in: db
            )
        }
        return selection.metrics(ingestedContactCount: selection.participants.count)
    }

    private static func canonicalParticipants(
        _ participants: [CalendarParticipant]
    ) -> CanonicalParticipantSelection {
        var participantByEmail: [String: CalendarParticipant] = [:]
        var skippedNonPersonCount = 0
        var skippedInvalidEmailCount = 0
        var validPersonCount = 0

        for participant in participants {
            guard participant.kind == .person else {
                skippedNonPersonCount += 1
                continue
            }
            guard let rawEmail = participant.email,
                  let email = CustomerIdentityNormalizer.email(rawEmail)
            else {
                skippedInvalidEmailCount += 1
                continue
            }
            validPersonCount += 1
            if let existing = participantByEmail[email] {
                participantByEmail[email] = existing.mergingMissingMetadata(from: participant)
            } else {
                participantByEmail[email] = participant
            }
        }
        let excludedCurrentUserIdentityCount = participantByEmail.values.count(where: \.isCurrentUser)
        let canonicalParticipants = participantByEmail
            .filter { !$0.value.isCurrentUser }
            .sorted { $0.key < $1.key }
        return CanonicalParticipantSelection(
            participants: canonicalParticipants,
            observedParticipantCount: participants.count,
            skippedNonPersonCount: skippedNonPersonCount,
            skippedInvalidEmailCount: skippedInvalidEmailCount,
            excludedCurrentUserIdentityCount: excludedCurrentUserIdentityCount,
            deduplicatedParticipantCount: validPersonCount - participantByEmail.count
        )
    }

    private static func upsertMeetingParticipant(
        meetingId: UUID,
        contactId: UUID,
        participant: CalendarParticipant,
        observedAt: Date,
        in db: Database
    ) throws {
        if var existing = try MeetingParticipantRecord
            .filter(Column("meetingId") == meetingId && Column("contactId") == contactId)
            .fetchOne(db) {
            guard observedAt >= existing.updatedAt else { return }
            if participant.role != .unknown {
                existing.role = participant.role
            }
            if participant.responseStatus != .unknown {
                existing.responseStatus = participant.responseStatus
            }
            existing.source = participant.source
            existing.updatedAt = observedAt
            try existing.update(db)
            return
        }
        try MeetingParticipantRecord(
            meetingId: meetingId,
            contactId: contactId,
            role: participant.role,
            responseStatus: participant.responseStatus,
            source: participant.source,
            createdAt: observedAt,
            updatedAt: observedAt
        ).insert(db)
    }
}
