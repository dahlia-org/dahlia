import DahliaRuntimeSupport
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    // swiftlint:disable:next type_body_length
    struct CustomerIntelligenceWorkspaceTests {
        @Test
        func directCRUDMigrationRepairsPreviouslyOpenedPreReleaseDatabase() throws {
            let queue = try DatabaseQueue()
            try AppDatabaseManager.migrator.migrate(
                queue,
                upTo: "v28_customerIntelligenceTopicReferenceTimestamp"
            )
            let vault = customerIntelligenceVault(name: "pre-release")
            let insightID = UUID.v7()
            let organizationID = UUID.v7()
            let createdAt = Date.now.addingTimeInterval(-60)
            let updatedAt = Date.now
            try queue.write { db in
                try vault.insert(db)
                try db.execute(
                    sql: """
                    INSERT INTO organizations
                        (id, vaultId, parentOrganizationId, nodeKind, name, revision, createdAt, updatedAt)
                    VALUES (?, ?, NULL, 'organization', 'Acme', 1, ?, ?)
                    """,
                    arguments: [organizationID, vault.id, createdAt, updatedAt]
                )
            }
            try queue.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA foreign_keys = OFF")
                defer {
                    try? db.execute(sql: "PRAGMA foreign_keys = ON")
                }
                try db.execute(
                    sql: """
                    DROP TRIGGER IF EXISTS insights_prevent_vault_change;
                    CREATE TABLE insights_legacy (
                        id BLOB PRIMARY KEY NOT NULL,
                        vaultId BLOB NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
                        content TEXT NOT NULL,
                        reviewState TEXT NOT NULL,
                        metadataJSON TEXT NOT NULL DEFAULT '{}',
                        createdAt DATETIME NOT NULL,
                        updatedAt DATETIME NOT NULL
                    );
                    INSERT INTO insights_legacy
                        (id, vaultId, content, reviewState, metadataJSON, createdAt, updatedAt)
                    VALUES (?, ?, 'Accepted before upgrade', 'accepted', '{}', ?, ?);
                    DROP TABLE insights;
                    ALTER TABLE insights_legacy RENAME TO insights;
                    CREATE TABLE customer_intelligence_proposals (id BLOB PRIMARY KEY NOT NULL);
                    """,
                    arguments: [insightID, vault.id, createdAt, updatedAt]
                )
            }
            try queue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO insight_references
                        (insightId, resourceType, resourceId, referenceRole, createdAt)
                    VALUES (?, 'organization', ?, 'evidence', ?)
                    """,
                    arguments: [insightID, organizationID, createdAt]
                )
            }

            try AppDatabaseManager.migrator.migrate(queue)

            try queue.read { db in
                let columns = try Set(db.columns(in: "insights").map(\.name))
                #expect(columns.contains("isAccepted"))
                #expect(columns.contains("revision"))
                #expect(!columns.contains("reviewState"))
                let fetchedInsight = try InsightRecord.fetchOne(db, key: insightID)
                let insight = try #require(fetchedInsight)
                #expect(insight.content == "Accepted before upgrade")
                #expect(insight.isAccepted)
                #expect(insight.revision == 1)
                #expect(abs(insight.createdAt.timeIntervalSince(createdAt)) < 0.001)
                #expect(abs(insight.updatedAt.timeIntervalSince(updatedAt)) < 0.001)
                let reference = try InsightReferenceRecord.fetchOne(
                    db,
                    key: [
                        "insightId": insightID,
                        "resourceType": CustomerResourceType.organization.rawValue,
                        "resourceId": organizationID,
                        "referenceRole": InsightReferenceRole.evidence.rawValue,
                    ]
                )
                #expect(abs(try #require(reference?.createdAt).timeIntervalSince(createdAt)) < 0.001)
                #expect(try !db.tableExists("customer_intelligence_proposals"))
                #expect(try !db.tableExists("glossary_terms"))
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            }
        }

        @Test
        // swiftlint:disable:next function_body_length
        func workspaceMigrationsPreserveContactRelationshipsWithoutGlossarySchema() throws {
            let queue = try DatabaseQueue()
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v25_customerIntelligence")
            try queue.read { db in
                let glossaryTermsExist = try db.tableExists("glossary_terms")
                let glossaryReferencesExist = try db.tableExists("glossary_term_references")
                #expect(glossaryTermsExist)
                #expect(glossaryReferencesExist)
            }
            let vault = customerIntelligenceVault(name: "v25")
            let otherVault = customerIntelligenceVault(name: "v25-other")
            let contactID = UUID.v7()
            let organizationID = UUID.v7()
            let otherOrganizationID = UUID.v7()
            let project = ProjectRecord(
                id: .v7(),
                vaultId: vault.id,
                parentProjectId: nil,
                name: "Customer",
                createdAt: .now,
                projectType: .customer
            )
            let meeting = MeetingRecord(
                id: .v7(),
                vaultId: vault.id,
                projectId: project.id,
                name: "Sync",
                status: .ready,
                createdAt: .now,
                updatedAt: .now
            )
            let referenceID = UUID.v7()
            let insightID = UUID.v7()
            try queue.write { db in
                try vault.insert(db)
                try otherVault.insert(db)
                try project.insert(db)
                try meeting.insert(db)
                try db.execute(
                    sql: """
                    INSERT INTO insights
                        (id, vaultId, content, reviewState, metadataJSON, createdAt, updatedAt)
                    VALUES (?, ?, 'Decision maker', 'accepted', '{}', ?, ?)
                    """,
                    arguments: [insightID, vault.id, Date.now, Date.now]
                )
                try db.execute(
                    sql: """
                    INSERT INTO contacts (id, vaultId, email, displayName, createdAt, updatedAt)
                    VALUES (?, ?, 'owner@example.com', 'Owner', ?, ?);
                    INSERT INTO organizations
                        (id, vaultId, parentOrganizationId, nodeKind, name, createdAt, updatedAt)
                    VALUES (?, ?, NULL, 'organization', 'Acme', ?, ?);
                    INSERT INTO organizations
                        (id, vaultId, parentOrganizationId, nodeKind, name, createdAt, updatedAt)
                    VALUES (?, ?, NULL, 'organization', 'Other', ?, ?);
                    INSERT INTO organization_memberships (organizationId, contactId, roleLabel, createdAt)
                    VALUES (?, ?, 'Lead', ?);
                    INSERT INTO meeting_participants
                        (meetingId, contactId, role, responseStatus, source, createdAt, updatedAt)
                    VALUES (?, ?, 'required', 'accepted', 'calendar', ?, ?);
                    INSERT INTO project_resource_references
                        (id, projectId, resourceType, resourceId, relationLabel, createdAt, updatedAt)
                    VALUES (?, ?, 'contact', ?, '', ?, ?);
                    INSERT INTO insight_references
                        (insightId, resourceType, resourceId, referenceRole, createdAt)
                    VALUES (?, 'contact', ?, 'evidence', ?);
                    """,
                    arguments: [
                        contactID, vault.id, Date.now, Date.now,
                        organizationID, vault.id, Date.now, Date.now,
                        otherOrganizationID, otherVault.id, Date.now, Date.now,
                        organizationID, contactID, Date.now,
                        meeting.id, contactID, Date.now, Date.now,
                        referenceID, project.id, contactID, Date.now, Date.now,
                        insightID, contactID, Date.now,
                    ]
                )
            }

            try AppDatabaseManager.migrator.migrate(queue)

            try queue.read { db in
                let fetchedContact = try ContactRecord.fetchOne(db, key: contactID)
                let contact = try #require(fetchedContact)
                #expect(contact.email == "owner@example.com")
                #expect(contact.displayName == "Owner")
                #expect(contact.revision >= 1)
                #expect(try OrganizationMembershipRecord.fetchCount(db) == 1)
                #expect(try MeetingParticipantRecord.fetchCount(db) == 1)
                #expect(try ProjectResourceReferenceRecord.fetchCount(db) == 1)
                #expect(try InsightReferenceRecord.fetchCount(db) == 1)
                let migratedInsight = try InsightRecord.fetchOne(db, key: insightID)
                #expect(migratedInsight?.isAccepted == true)
                #expect(try !db.tableExists("glossary_terms"))
                #expect(try !db.tableExists("glossary_term_references"))
                let fetchedMembership = try OrganizationMembershipRecord.fetchOne(
                    db,
                    key: ["organizationId": organizationID, "contactId": contactID]
                )
                let membership = try #require(fetchedMembership)
                #expect(membership.roleLabel == "Lead")
                let fetchedParticipant = try MeetingParticipantRecord.fetchOne(
                    db,
                    key: ["meetingId": meeting.id, "contactId": contactID]
                )
                let participant = try #require(fetchedParticipant)
                #expect(participant.role == .required)
                #expect(participant.responseStatus == .accepted)
                #expect(participant.source == "calendar")
                let fetchedProjectReference = try ProjectResourceReferenceRecord.fetchOne(db, key: referenceID)
                let projectReference = try #require(fetchedProjectReference)
                #expect(projectReference.projectId == project.id)
                #expect(projectReference.resourceId == contactID)
                #expect(projectReference.relationLabel.isEmpty)
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
                let indexes = try Set(String.fetchAll(
                    db,
                    sql: "SELECT name FROM sqlite_master WHERE type = 'index'"
                ))
                #expect(indexes.contains("contacts_on_vaultId_sortKey_id"))
                #expect(indexes.contains("meeting_participants_on_contactId_meetingId"))
                for table in [
                    "customer_intelligence_proposals",
                    "customer_intelligence_proposal_evidence",
                    "customer_intelligence_proposal_dependencies",
                    "customer_intelligence_direct_mutations",
                    "customer_intelligence_mutation_imports",
                    "customer_intelligence_mutation_import_chunks",
                ] {
                    #expect(try !db.tableExists(table))
                }
            }

            #expect(throws: DatabaseError.self) {
                try queue.write { db in
                    try db.execute(
                        sql: """
                        INSERT INTO organization_memberships (organizationId, contactId, roleLabel, createdAt)
                        VALUES (?, ?, NULL, ?)
                        """,
                        arguments: [otherOrganizationID, contactID, Date.now]
                    )
                }
            }

            let otherMeeting = MeetingRecord(
                id: .v7(),
                vaultId: otherVault.id,
                projectId: nil,
                name: "Other",
                status: .ready,
                createdAt: .now,
                updatedAt: .now
            )
            #expect(throws: DatabaseError.self) {
                try queue.write { db in
                    try otherMeeting.insert(db)
                    try MeetingParticipantRecord(
                        meetingId: otherMeeting.id,
                        contactId: contactID,
                        role: .required,
                        responseStatus: .accepted,
                        source: "calendar",
                        createdAt: .now,
                        updatedAt: .now
                    ).insert(db)
                }
            }

            try queue.write { db in
                try ContactRecord(
                    id: .v7(),
                    vaultId: vault.id,
                    email: nil,
                    displayName: "Provisional One",
                    revision: 1,
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
                try ContactRecord(
                    id: .v7(),
                    vaultId: vault.id,
                    email: nil,
                    displayName: "Provisional Two",
                    revision: 1,
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
            }
            #expect(throws: DatabaseError.self) {
                try queue.write { db in
                    try ContactRecord(
                        id: .v7(),
                        vaultId: vault.id,
                        email: "owner@example.com",
                        displayName: "Duplicate",
                        revision: 1,
                        createdAt: .now,
                        updatedAt: .now
                    ).insert(db)
                }
            }

            try queue.write { db in
                _ = try ContactRecord.deleteOne(db, key: contactID)
                #expect(try ProjectResourceReferenceRecord.fetchCount(db) == 0)
                #expect(try InsightReferenceRecord.fetchCount(db) == 0)
            }
        }

        @Test
        func topicsDeriveHistoryAndReferencesIncreaseRevision() throws {
            let fixture = try CustomerIntelligenceFixture()
            let organization = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Acme"
            )
            let meeting = try fixture.insertMeeting()
            let topic = try fixture.repository.createConversationTopic(
                vaultId: fixture.vault.id,
                title: "Security review",
                currentState: "Questionnaire shared",
                references: [
                    .init(resourceType: .organization, resourceID: organization.id),
                    .init(resourceType: .meeting, resourceID: meeting.id, note: "Owner assigned"),
                ]
            )
            try fixture.repository.replaceConversationTopicReferences(
                topicId: topic.id,
                vaultId: fixture.vault.id,
                expectedRevision: topic.revision,
                references: [
                    .init(resourceType: .organization, resourceID: organization.id),
                    .init(resourceType: .meeting, resourceID: meeting.id, note: "Owner assigned"),
                ]
            )

            let fetchedDetail = try fixture.repository.fetchConversationTopic(
                id: topic.id,
                vaultId: fixture.vault.id
            )
            let detail = try #require(fetchedDetail)
            #expect(detail.0.meetingCount == 1)
            #expect(detail.0.organizationCount == 1)
            #expect(try abs(#require(detail.0.lastDiscussedAt).timeIntervalSince(meeting.createdAt)) < 0.001)
            #expect(detail.0.topic.revision > topic.revision)
            #expect(detail.1.first(where: { $0.resourceType == .meeting })?.note == "Owner assigned")
        }

        @Test
        func participantMutationsIncreaseTheOwningContactRevision() throws {
            let fixture = try CustomerIntelligenceFixture()
            let meeting = try fixture.insertMeeting()
            let contact = try fixture.repository.upsertContact(
                vaultId: fixture.vault.id,
                email: "owner@example.com",
                displayName: "Owner"
            )

            try fixture.manager.dbQueue.write { db in
                try MeetingParticipantRecord(
                    meetingId: meeting.id,
                    contactId: contact.id,
                    role: .required,
                    responseStatus: .accepted,
                    source: "calendar",
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
            }
            let fetchedAfterInsert = try fixture.repository.fetchContact(
                id: contact.id,
                vaultId: fixture.vault.id
            )
            let afterInsert = try #require(fetchedAfterInsert)
            #expect(afterInsert.revision == contact.revision + 1)

            try fixture.manager.dbQueue.write { db in
                try db.execute(
                    sql: """
                    UPDATE meeting_participants
                    SET responseStatus = 'tentative', updatedAt = ?
                    WHERE meetingId = ? AND contactId = ?
                    """,
                    arguments: [Date.now, meeting.id, contact.id]
                )
            }
            let fetchedAfterUpdate = try fixture.repository.fetchContact(
                id: contact.id,
                vaultId: fixture.vault.id
            )
            let afterUpdate = try #require(fetchedAfterUpdate)
            #expect(afterUpdate.revision == afterInsert.revision + 1)

            try fixture.manager.dbQueue.write { db in
                _ = try MeetingParticipantRecord
                    .filter(Column("meetingId") == meeting.id && Column("contactId") == contact.id)
                    .deleteAll(db)
            }
            let fetchedAfterDelete = try fixture.repository.fetchContact(
                id: contact.id,
                vaultId: fixture.vault.id
            )
            let afterDelete = try #require(fetchedAfterDelete)
            #expect(afterDelete.revision == afterUpdate.revision + 1)
        }

        @Test
        func organizationSearchExpandsAncestorsAndTopicFocusHighlightsRelatedNodes() async throws {
            let fixture = try CustomerIntelligenceFixture()
            let root = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Acme"
            )
            let child = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: root.id,
                nodeKind: .unit,
                name: "Platform"
            )
            let grandchild = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: child.id,
                nodeKind: .unit,
                name: "Security"
            )
            let topic = try fixture.repository.createConversationTopic(
                vaultId: fixture.vault.id,
                title: "Security review",
                currentState: "Owner assigned",
                references: [.init(resourceType: .organization, resourceID: grandchild.id)]
            )
            let model = OrganizationWorkspaceViewModel(
                dbQueue: fixture.manager.dbQueue,
                vaultID: fixture.vault.id
            )
            let relatedPaths = try fixture.repository.fetchConversationTopicRelatedOrganizationPaths(
                id: topic.id,
                vaultId: fixture.vault.id
            )
            #expect(!relatedPaths.isTruncated)
            #expect(relatedPaths.paths.map { $0.map(\.id) } == [[root.id, child.id, grandchild.id]])

            await model.load()
            #expect(model.loadedNodes[grandchild.id] == nil)
            #expect(model.organizationCandidates.contains { $0.id == grandchild.id })
            model.searchText = "Security"
            await model.searchAndRevealFirstMatch()
            #expect(model.selectedNodeID == grandchild.id)
            #expect(model.expandedNodeIDs.isSuperset(of: [root.id, child.id]))
            #expect(Set(model.visibleNodes.map(\.id)).count == model.visibleNodes.count)

            await model.selectTopic(topic.id)
            #expect(model.highlightedOrganizationIDs == [grandchild.id])
            await model.toggleExpansion(child.id)
            #expect(!model.visibleNodes.contains { $0.id == grandchild.id })
        }

        @Test
        func canvasLayoutIsDeterministicAndDoesNotOverlapNodes() {
            let root = UUID.v7()
            let childA = UUID.v7()
            let childB = UUID.v7()
            let inputs = [
                OrganizationCanvasLayoutInputNode(id: root, depth: 0),
                OrganizationCanvasLayoutInputNode(id: childA, depth: 1),
                OrganizationCanvasLayoutInputNode(id: childB, depth: 1),
            ]
            let first = OrganizationCanvasLayout.calculate(nodes: inputs)
            let second = OrganizationCanvasLayout.calculate(nodes: inputs)
            #expect(first == second)
            #expect(first.positions[root]?.x != first.positions[childA]?.x)
            #expect(first.positions[childA] != first.positions[childB])
        }
    }
#endif
