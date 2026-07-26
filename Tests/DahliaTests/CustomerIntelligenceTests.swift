import Foundation
import GRDB
@testable import Dahlia
@testable import DahliaRuntimeSupport

#if canImport(Testing)
    import Testing

    @MainActor
    struct CustomerIntelligenceTests {
        @Test
        // swiftlint:disable:next function_body_length
        func migrationAddsVaultScopedCanonicalSchemaWithoutProcessingColumnNames() throws {
            let queue = try DatabaseQueue()
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v24_projectWorkspaceHierarchy")
            let vault = customerIntelligenceVault(name: "Before v25")
            let project = ProjectRecord(
                id: .v7(),
                vaultId: vault.id,
                parentProjectId: nil,
                name: "Existing customer",
                createdAt: .now,
                projectType: .customer
            )
            let meeting = MeetingRecord(
                id: .v7(),
                vaultId: vault.id,
                projectId: project.id,
                name: "Existing meeting",
                status: .ready,
                createdAt: .now,
                updatedAt: .now
            )
            try queue.write { db in
                try vault.insert(db)
                try project.insert(db)
                try meeting.insert(db)
            }

            try AppDatabaseManager.migrator.migrate(queue, upTo: "v25_customerIntelligence")

            let result = try queue.read { db in
                let contactColumns = try Set(String.fetchAll(
                    db,
                    sql: "SELECT name FROM pragma_table_info('contacts')"
                ))
                let organizationColumns = try Set(String.fetchAll(
                    db,
                    sql: "SELECT name FROM pragma_table_info('organizations')"
                ))
                let domainColumns = try Set(String.fetchAll(
                    db,
                    sql: "SELECT name FROM pragma_table_info('organization_domains')"
                ))
                let vaultCount = try VaultRecord.filter(key: vault.id).fetchCount(db)
                let migratedMeeting = try MeetingRecord.fetchOne(db, key: meeting.id)
                let foreignKeyFailures = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
                return (
                    contactColumns,
                    organizationColumns,
                    domainColumns,
                    vaultCount,
                    migratedMeeting,
                    foreignKeyFailures
                )
            }

            #expect(result.0 == ["id", "vaultId", "email", "displayName", "createdAt", "updatedAt"])
            #expect(!result.0.contains("normalizedEmail"))
            #expect(!result.0.contains("displayNameSource"))
            #expect(!result.0.contains("firstSeenAt"))
            #expect(!result.0.contains("lastSeenAt"))
            #expect(!result.1.contains("nameKey"))
            #expect(!result.1.contains("nameOrigin"))
            #expect(result.2.contains("domainName"))
            #expect(!result.2.contains("normalizedDomain"))
            #expect(result.3 == 1)
            #expect(result.4?.projectId == project.id)
            #expect(result.4?.name == meeting.name)
            #expect(result.5.isEmpty)
        }

        @Test
        func contactsUseCanonicalEmailOnlyWithinEachVault() throws {
            let fixture = try CustomerIntelligenceFixture()
            let first = try fixture.repository.upsertContact(
                vaultId: fixture.vault.id,
                email: " Alice@Example.COM ",
                displayName: nil
            )
            let completed = try fixture.repository.upsertContact(
                vaultId: fixture.vault.id,
                email: "alice@example.com",
                displayName: "Alice"
            )
            let unchanged = try fixture.repository.upsertContact(
                vaultId: fixture.vault.id,
                email: "ALICE@EXAMPLE.COM",
                displayName: "Different Name"
            )
            let otherVault = try fixture.repository.upsertContact(
                vaultId: fixture.otherVault.id,
                email: "alice@example.com",
                displayName: "Other Alice"
            )

            #expect(first.id == completed.id)
            #expect(completed.email == "alice@example.com")
            #expect(completed.displayName == "Alice")
            #expect(unchanged.displayName == "Alice")
            #expect(otherVault.id != first.id)
            #expect(throws: CustomerIntelligenceError.invalidEmail) {
                try fixture.repository.upsertContact(
                    vaultId: fixture.vault.id,
                    email: "利用者@例え.テスト",
                    displayName: nil
                )
            }
        }

        @Test
        func commonPublicMailboxDomainsDoNotCreateOrganizationsAutomatically() {
            for domainName in [
                "gmail.com",
                "fastmail.com",
                "hotmail.co.jp",
                "outlook.jp",
                "qq.com",
                "yahoo.co.uk",
                "yandex.ru",
                "zoho.com",
            ] {
                #expect(!CustomerIdentityNormalizer.isAutomaticOrganizationDomain(domainName))
            }
            #expect(CustomerIdentityNormalizer.isAutomaticOrganizationDomain("customer.example"))
        }

        @Test
        // swiftlint:disable:next function_body_length
        func organizationsSupportMultipleDomainsNestedUnitsAndConcurrentMemberships() throws {
            let fixture = try CustomerIntelligenceFixture()
            let organization = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Acme"
            )
            let engineering = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: organization.id,
                nodeKind: .unit,
                name: "Engineering"
            )
            let platform = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: engineering.id,
                nodeKind: .unit,
                name: "Platform"
            )
            let sales = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: organization.id,
                nodeKind: .unit,
                name: "Sales"
            )
            let contact = try fixture.repository.upsertContact(
                vaultId: fixture.vault.id,
                email: "owner@acme.com",
                displayName: "Owner"
            )
            _ = try fixture.repository.addOrganizationMembership(
                organizationId: platform.id,
                contactId: contact.id,
                roleLabel: "Lead"
            )
            _ = try fixture.repository.addOrganizationMembership(
                organizationId: sales.id,
                contactId: contact.id
            )

            let firstDomain = try fixture.repository.addOrganizationDomain(
                organizationId: organization.id,
                vaultId: fixture.vault.id,
                domainName: "ACME.COM."
            )
            let secondDomain = try fixture.repository.addOrganizationDomain(
                organizationId: organization.id,
                vaultId: fixture.vault.id,
                domainName: "acme.co.jp"
            )
            #expect(firstDomain.domainName == "acme.com")
            #expect(firstDomain.isPrimary)
            #expect(!secondDomain.isPrimary)
            #expect(throws: DatabaseError.self) {
                try fixture.manager.dbQueue.write { db in
                    try db.execute(
                        sql: """
                        UPDATE organization_domains
                        SET isPrimary = 1
                        WHERE vaultId = ? AND domainName = ?
                        """,
                        arguments: [fixture.vault.id, secondDomain.domainName]
                    )
                }
            }

            try fixture.repository.setPrimaryOrganizationDomain(
                organizationId: organization.id,
                vaultId: fixture.vault.id,
                domainName: secondDomain.domainName
            )
            try fixture.repository.removeOrganizationDomain(
                vaultId: fixture.vault.id,
                domainName: secondDomain.domainName
            )

            let domains = try fixture.repository.fetchOrganizationDomains(
                organizationId: organization.id,
                vaultId: fixture.vault.id
            )
            let memberships = try fixture.manager.dbQueue.read { db in
                try OrganizationMembershipRecord
                    .filter(Column("contactId") == contact.id)
                    .fetchAll(db)
            }
            #expect(domains.map { $0.domainName } == ["acme.com"])
            #expect(domains.first?.isPrimary == true)
            #expect(Set(memberships.map { $0.organizationId }) == Set([platform.id, sales.id]))

            #expect(throws: CustomerIntelligenceError.invalidOrganizationParent) {
                try fixture.repository.createOrganization(
                    vaultId: fixture.vault.id,
                    parentOrganizationId: nil,
                    nodeKind: .unit,
                    name: "Invalid Root"
                )
            }
            #expect(throws: CustomerIntelligenceError.invalidOrganizationParent) {
                try fixture.repository.moveOrganization(
                    id: organization.id,
                    vaultId: fixture.vault.id,
                    parentOrganizationId: platform.id
                )
            }
            #expect(throws: CustomerIntelligenceError.organizationCycle) {
                try fixture.repository.moveOrganization(
                    id: engineering.id,
                    vaultId: fixture.vault.id,
                    parentOrganizationId: platform.id
                )
            }
            #expect(throws: CustomerIntelligenceError.invalidDomain) {
                try fixture.repository.addOrganizationDomain(
                    organizationId: organization.id,
                    vaultId: fixture.vault.id,
                    domainName: "例え.テスト"
                )
            }
            #expect(throws: DatabaseError.self) {
                try fixture.manager.dbQueue.write { db in
                    try db.execute(
                        sql: "UPDATE organizations SET nodeKind = 'organization' WHERE id = ?",
                        arguments: [platform.id]
                    )
                }
            }
        }

        @Test
        func organizationHierarchyHasAThirtyTwoEdgeLimit() throws {
            let fixture = try CustomerIntelligenceFixture()
            var parent = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Root"
            )
            let movable = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: parent.id,
                nodeKind: .unit,
                name: "Movable"
            )
            _ = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: movable.id,
                nodeKind: .unit,
                name: "Movable Child"
            )
            for depth in 1 ... CustomerIntelligenceMigration.maximumOrganizationDepth {
                parent = try fixture.repository.createOrganization(
                    vaultId: fixture.vault.id,
                    parentOrganizationId: parent.id,
                    nodeKind: .unit,
                    name: "Unit \(depth)"
                )
            }

            #expect(throws: CustomerIntelligenceError.organizationHierarchyTooDeep) {
                try fixture.repository.moveOrganization(
                    id: movable.id,
                    vaultId: fixture.vault.id,
                    parentOrganizationId: parent.id
                )
            }
            #expect(throws: CustomerIntelligenceError.organizationHierarchyTooDeep) {
                try fixture.repository.createOrganization(
                    vaultId: fixture.vault.id,
                    parentOrganizationId: parent.id,
                    nodeKind: .unit,
                    name: "Too Deep"
                )
            }
        }
    }

    @MainActor
    struct CustomerIntelligenceIntegrationTests {
        @Test
        // swiftlint:disable:next function_body_length
        func polymorphicReferencesEnforceVaultAndCleanUpDeletedTargets() throws {
            let fixture = try CustomerIntelligenceFixture()
            let organization = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Acme"
            )
            let contact = try fixture.repository.upsertContact(
                vaultId: fixture.vault.id,
                email: "contact@acme.com",
                displayName: "Contact"
            )
            let otherContact = try fixture.repository.upsertContact(
                vaultId: fixture.otherVault.id,
                email: "contact@acme.com",
                displayName: "Other Contact"
            )
            let project = try fixture.repository.createProject(
                vaultId: fixture.vault.id,
                parentProjectId: nil,
                name: "Customer",
                description: "",
                projectType: .customer
            )
            let meeting = try fixture.insertMeeting()
            let insight = try fixture.repository.createInsight(
                vaultId: fixture.vault.id,
                content: "Decision makers changed",
                metadataJSON: #"{"rank":3,"reviewed_at":"2026-07-26T00:00:00Z"}"#
            )
            let glossary = try fixture.repository.createGlossaryTerm(
                vaultId: fixture.vault.id,
                term: "DRI",
                definition: "Directly responsible individual",
                aliases: ["Owner"]
            )

            for (type, id) in [
                (CustomerResourceType.organization, organization.id),
                (.contact, contact.id),
                (.project, project.id),
                (.meeting, meeting.id),
            ] {
                _ = try fixture.repository.addInsightReference(
                    insightId: insight.id,
                    resourceType: type,
                    resourceId: id,
                    role: .evidence
                )
                _ = try fixture.repository.addGlossaryTermReference(
                    glossaryTermId: glossary.id,
                    resourceType: type,
                    resourceId: id
                )
            }
            let organizationReference = try fixture.repository.addProjectResourceReference(
                projectId: project.id,
                resourceType: .organization,
                resourceId: organization.id
            )
            _ = try fixture.repository.addProjectResourceReference(
                projectId: project.id,
                resourceType: .contact,
                resourceId: contact.id
            )
            #expect(organizationReference.relationLabel.isEmpty)

            #expect(throws: DatabaseError.self) {
                try fixture.manager.dbQueue.write { db in
                    try ProjectResourceReferenceRecord(
                        id: .v7(),
                        projectId: project.id,
                        resourceType: .organization,
                        resourceId: organization.id,
                        relationLabel: "",
                        createdAt: .now,
                        updatedAt: .now
                    ).insert(db)
                }
            }
            #expect(throws: DatabaseError.self) {
                try fixture.repository.addProjectResourceReference(
                    projectId: project.id,
                    resourceType: .contact,
                    resourceId: otherContact.id
                )
            }
            #expect(throws: DatabaseError.self) {
                try fixture.repository.addOrganizationMembership(
                    organizationId: organization.id,
                    contactId: otherContact.id
                )
            }
            #expect(throws: DatabaseError.self) {
                try fixture.manager.dbQueue.write { db in
                    try MeetingParticipantRecord(
                        meetingId: meeting.id,
                        contactId: otherContact.id,
                        role: .required,
                        responseStatus: .accepted,
                        source: "test",
                        createdAt: .now,
                        updatedAt: .now
                    ).insert(db)
                }
            }
            #expect(throws: DatabaseError.self) {
                try fixture.repository.addInsightReference(
                    insightId: insight.id,
                    resourceType: .contact,
                    resourceId: otherContact.id,
                    role: .evidence
                )
            }

            try fixture.manager.dbQueue.write { db in
                _ = try OrganizationRecord.deleteOne(db, key: organization.id)
                _ = try ContactRecord.deleteOne(db, key: contact.id)
                _ = try ProjectRecord.deleteOne(db, key: project.id)
                _ = try MeetingRecord.deleteOne(db, key: meeting.id)
            }
            let counts = try fixture.manager.dbQueue.read { db in
                try (
                    InsightReferenceRecord.filter(Column("insightId") == insight.id).fetchCount(db),
                    GlossaryTermReferenceRecord
                        .filter(Column("glossaryTermId") == glossary.id)
                        .fetchCount(db),
                    ProjectResourceReferenceRecord.fetchCount(db),
                    InsightRecord.filter(key: insight.id).fetchCount(db),
                    GlossaryTermRecord.filter(key: glossary.id).fetchCount(db)
                )
            }
            #expect(counts.0 == 0)
            #expect(counts.1 == 0)
            #expect(counts.2 == 0)
            #expect(counts.3 == 1)
            #expect(counts.4 == 1)
        }
    }
#endif
