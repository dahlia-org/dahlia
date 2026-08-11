import DahliaRuntimeSupport
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CustomerIntelligenceRecencyTests {
        @Test
        // swiftlint:disable:next function_body_length
        func meetingRecencyUsesRecordingStartWithCreationFallback() throws {
            let fixture = try CustomerIntelligenceFixture()
            let project = ProjectRecord(
                id: .v7(),
                vaultId: fixture.vault.id,
                parentProjectId: nil,
                name: "Timeline",
                createdAt: .now,
                description: "",
                projectType: .customer
            )
            let contact = ContactRecord(
                id: .v7(),
                vaultId: fixture.vault.id,
                email: "owner@example.com",
                displayName: "Owner",
                revision: 1,
                createdAt: .now,
                updatedAt: .now
            )
            let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
            let recordedLater = MeetingRecord(
                id: .v7(),
                vaultId: fixture.vault.id,
                projectId: project.id,
                name: "Recorded later",
                status: .ready,
                createdAt: baseDate.addingTimeInterval(100),
                updatedAt: baseDate.addingTimeInterval(100),
                recordingStartedAt: baseDate.addingTimeInterval(300)
            )
            let creationFallback = MeetingRecord(
                id: .v7(),
                vaultId: fixture.vault.id,
                projectId: project.id,
                name: "Creation fallback",
                status: .ready,
                createdAt: baseDate.addingTimeInterval(200),
                updatedAt: baseDate.addingTimeInterval(200)
            )
            let topic = ConversationTopicRecord(
                id: .v7(),
                vaultId: fixture.vault.id,
                title: "Timeline",
                currentState: "Active",
                revision: 1,
                createdAt: baseDate,
                updatedAt: baseDate
            )
            try fixture.manager.dbQueue.write { db in
                try project.insert(db)
                try contact.insert(db)
                for meeting in [recordedLater, creationFallback] {
                    try meeting.insert(db)
                    try MeetingParticipantRecord(
                        meetingId: meeting.id,
                        contactId: contact.id,
                        role: .required,
                        responseStatus: .accepted,
                        source: "test",
                        createdAt: meeting.createdAt,
                        updatedAt: meeting.createdAt
                    ).insert(db)
                }
                try topic.insert(db)
                for meeting in [recordedLater, creationFallback] {
                    try ConversationTopicReferenceRecord(
                        topicId: topic.id,
                        resourceType: .meeting,
                        resourceId: meeting.id,
                        note: "Discussed",
                        createdAt: meeting.createdAt,
                        updatedAt: meeting.createdAt
                    ).insert(db)
                }
            }

            let fetchedContactDetail = try fixture.repository.fetchCustomerIntelligenceContactDetail(
                id: contact.id,
                vaultId: fixture.vault.id
            )
            let fetchedProjectDetail = try fixture.repository.fetchCustomerIntelligenceProjectDetail(
                id: project.id,
                vaultId: fixture.vault.id
            )
            let fetchedTopicDetail = try fixture.repository.fetchCustomerIntelligenceTopicDetail(
                id: topic.id,
                vaultId: fixture.vault.id
            )
            let overview = try fixture.repository.fetchCustomerIntelligenceOverview(
                vaultId: fixture.vault.id,
                scope: .all
            )
            let contactDetail = try #require(fetchedContactDetail)
            let projectDetail = try #require(fetchedProjectDetail)
            let topicDetail = try #require(fetchedTopicDetail)
            let expectedDate = recordedLater.effectiveRecordingStartedAt

            #expect(contactDetail.summary.lastInteractionAt == expectedDate)
            #expect(contactDetail.recentMeetings.map(\.id) == [recordedLater.id, creationFallback.id])
            #expect(projectDetail.summary.latestMeetingDate == expectedDate)
            #expect(projectDetail.meetings.map(\.id) == [recordedLater.id, creationFallback.id])
            #expect(topicDetail.overview.lastDiscussedAt == expectedDate)
            #expect(topicDetail.meetings.map(\.meeting.id) == [recordedLater.id, creationFallback.id])
            #expect(overview.recentMeetings.map(\.id) == [recordedLater.id, creationFallback.id])
        }
    }

    @MainActor
    struct CustomerIntelligencePresentationTests {
        @Test
        func customerIntelligenceProjectCreationIsAtomicWithOrganizationReference() throws {
            let fixture = try CustomerIntelligenceFixture()
            let organization = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Acme"
            )

            #expect(throws: CustomerIntelligenceError.invalidReference) {
                try fixture.repository.createCustomerIntelligenceProject(
                    vaultId: fixture.vault.id,
                    parentProjectId: nil,
                    name: "Invalid",
                    description: "",
                    projectType: .customer,
                    organizationId: .v7()
                )
            }
            #expect(try fixture.repository.fetchAllProjects(vaultId: fixture.vault.id).isEmpty)

            let project = try fixture.repository.createCustomerIntelligenceProject(
                vaultId: fixture.vault.id,
                parentProjectId: nil,
                name: "Customer",
                description: "Customer workspace",
                projectType: .customer,
                organizationId: organization.id
            )
            let references = try fixture.repository.fetchProjectResourceReferences(projectId: project.id)
            #expect(project.description == "Customer workspace")
            #expect(references.count == 1)
            #expect(references.first?.resourceType == .organization)
            #expect(references.first?.resourceId == organization.id)
        }

        @Test
        func customerIntelligenceProjectEditUpdatesFieldsInOneRevision() throws {
            let fixture = try CustomerIntelligenceFixture()
            let project = try fixture.repository.createProject(
                vaultId: fixture.vault.id,
                parentProjectId: nil,
                name: "Before",
                description: "Old",
                projectType: .customer
            )

            let updated = try fixture.repository.updateCustomerIntelligenceProject(
                id: project.id,
                vaultId: fixture.vault.id,
                parentProjectId: nil,
                name: "After",
                description: "New",
                projectType: .internal,
                vaultExportUpdates: [],
                expectedRevision: project.revision
            )

            #expect(updated.name == "After")
            #expect(updated.description == "New")
            #expect(updated.projectType == .internal)
            #expect(updated.revision == project.revision + 1)
        }

        @Test
        func projectReferenceMutationsIncrementTheProjectRevision() throws {
            let fixture = try CustomerIntelligenceFixture()
            let contact = try fixture.repository.upsertContact(
                vaultId: fixture.vault.id,
                email: "owner@example.com",
                displayName: "Owner"
            )
            let project = try fixture.repository.createProject(
                vaultId: fixture.vault.id,
                parentProjectId: nil,
                name: "Customer",
                description: "",
                projectType: .customer
            )

            let reference = try fixture.repository.addProjectResourceReference(
                projectId: project.id,
                resourceType: .contact,
                resourceId: contact.id
            )
            let fetchedAfterInsert = try fixture.repository.fetchProject(id: project.id)
            let afterInsert = try #require(fetchedAfterInsert)
            #expect(afterInsert.revision == project.revision + 1)

            let duplicate = try fixture.repository.addProjectResourceReference(
                projectId: project.id,
                resourceType: .contact,
                resourceId: contact.id
            )
            #expect(duplicate.id == reference.id)
            #expect(try fixture.repository.fetchProject(id: project.id)?.revision == afterInsert.revision)

            try fixture.repository.deleteProjectResourceReference(id: reference.id)
            #expect(try fixture.repository.fetchProject(id: project.id)?.revision == afterInsert.revision + 1)
        }

        @Test
        func directContactResolutionUpdatesNameAndKeepsIdentityForUnusedEmail() throws {
            let fixture = try CustomerIntelligenceFixture()
            let provisional = try fixture.repository.createProvisionalContact(
                vaultId: fixture.vault.id,
                displayName: "Misheard"
            )

            let resolved = try fixture.repository.resolveProvisionalContact(
                id: provisional.id,
                vaultId: fixture.vault.id,
                email: "person@example.com",
                displayName: "Correct Name",
                expectedRevision: provisional.revision,
                expectedExistingContactID: nil,
                expectedExistingRevision: nil
            )

            #expect(resolved.id == provisional.id)
            #expect(resolved.displayName == "Correct Name")
            #expect(resolved.email == "person@example.com")
            #expect(!resolved.isProvisional)
        }

        @Test
        func directContactResolutionRequiresConfirmedExistingContactAndMovesMembership() throws {
            let fixture = try CustomerIntelligenceFixture()
            let organization = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Acme"
            )
            let provisional = try fixture.repository.createProvisionalContact(
                vaultId: fixture.vault.id,
                displayName: "Source",
                organizationId: organization.id
            )
            let existing = try fixture.repository.upsertContact(
                vaultId: fixture.vault.id,
                email: "source@example.com",
                displayName: "Existing"
            )
            let project = try fixture.repository.createProject(
                vaultId: fixture.vault.id,
                parentProjectId: nil,
                name: "Customer",
                description: "",
                projectType: .customer
            )
            _ = try fixture.repository.addProjectResourceReference(
                projectId: project.id,
                resourceType: .contact,
                resourceId: existing.id,
                relationLabel: "confirmed"
            )
            _ = try fixture.repository.addProjectResourceReference(
                projectId: project.id,
                resourceType: .contact,
                resourceId: provisional.id,
                relationLabel: "provisional"
            )
            let insight = try fixture.repository.createInsight(
                vaultId: fixture.vault.id,
                content: "Sponsor"
            )
            _ = try fixture.repository.addInsightReference(
                insightId: insight.id,
                resourceType: .contact,
                resourceId: existing.id,
                role: .context
            )
            _ = try fixture.repository.addInsightReference(
                insightId: insight.id,
                resourceType: .contact,
                resourceId: provisional.id,
                role: .evidence
            )

            #expect(throws: CustomerIntelligenceError.revisionConflict) {
                try fixture.repository.resolveProvisionalContact(
                    id: provisional.id,
                    vaultId: fixture.vault.id,
                    email: "source@example.com",
                    displayName: "Source",
                    expectedRevision: provisional.revision,
                    expectedExistingContactID: nil,
                    expectedExistingRevision: nil
                )
            }

            let resolved = try fixture.repository.resolveProvisionalContact(
                id: provisional.id,
                vaultId: fixture.vault.id,
                email: "source@example.com",
                displayName: "Source",
                expectedRevision: provisional.revision,
                expectedExistingContactID: existing.id,
                expectedExistingRevision: existing.revision
            )
            let fetchedDetail = try fixture.repository.fetchCustomerIntelligenceContactDetail(
                id: existing.id,
                vaultId: fixture.vault.id
            )
            let detail = try #require(fetchedDetail)

            #expect(resolved.id == existing.id)
            #expect(detail.memberships.map(\.organization.id) == [organization.id])
            #expect(try fixture.repository.fetchContact(
                id: provisional.id,
                vaultId: fixture.vault.id
            ) == nil)
            let projectReferences = try fixture.repository.fetchProjectResourceReferences(projectId: project.id)
            #expect(Set(projectReferences.filter {
                $0.resourceType == .contact && $0.resourceId == existing.id
            }.map(\.relationLabel)) == ["confirmed", "provisional"])
            let insightReferences = try fixture.manager.dbQueue.read { db in
                try InsightReferenceRecord
                    .filter(Column("insightId") == insight.id)
                    .fetchAll(db)
            }
            #expect(Set(insightReferences.filter {
                $0.resourceType == .contact && $0.resourceId == existing.id
            }.map(\.referenceRole)) == [.context, .evidence])
        }

        @Test
        func topicPresentationCanBeScopedToAnOrganization() throws {
            let fixture = try CustomerIntelligenceFixture()
            let first = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "First"
            )
            let second = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Second"
            )
            let firstTopic = try fixture.repository.createConversationTopic(
                vaultId: fixture.vault.id,
                title: "First topic",
                currentState: "In progress",
                references: [.init(resourceType: .organization, resourceID: first.id)]
            )
            _ = try fixture.repository.createConversationTopic(
                vaultId: fixture.vault.id,
                title: "Second topic",
                currentState: "Waiting",
                references: [.init(resourceType: .organization, resourceID: second.id)]
            )

            let scoped = try fixture.repository.fetchConversationTopics(
                vaultId: fixture.vault.id,
                organizationId: first.id
            )

            #expect(scoped.map(\.id) == [firstTopic.id])
        }

        @Test
        func customerScopeUsesOnlyDirectOrganizationAndContactReferences() throws {
            let fixture = try CustomerIntelligenceFixture()
            let customer = try seedScopedCustomer(in: fixture)
            let project = try seedScopedProjects(in: fixture, contactID: customer.contactID)
            let resources = try seedScopedResources(
                in: fixture,
                organizationID: customer.departmentID,
                contactID: customer.contactID,
                meetingID: project.meetingID
            )

            let scope = CustomerIntelligenceScope.organization(customer.rootID)
            let contacts = try fixture.repository.fetchCustomerIntelligenceContacts(
                vaultId: fixture.vault.id,
                scope: scope
            )
            let projects = try fixture.repository.fetchCustomerIntelligenceProjects(
                vaultId: fixture.vault.id,
                scope: scope
            )
            let topics = try fixture.repository.fetchConversationTopics(
                vaultId: fixture.vault.id,
                scope: scope
            )
            let insights = try fixture.repository.fetchCustomerIntelligenceInsights(
                vaultId: fixture.vault.id,
                scope: scope
            )
            let overview = try fixture.repository.fetchCustomerIntelligenceOverview(
                vaultId: fixture.vault.id,
                scope: scope
            )

            #expect(contacts.map(\.id) == [customer.contactID])
            #expect(projects.map(\.id) == [project.directProjectID])
            #expect(topics.map(\.id) == [resources.directTopicID])
            #expect(insights.map(\.id) == [resources.directInsightID])
            #expect(overview.counts.contacts == 1)
            #expect(overview.counts.projects == 1)
            #expect(overview.counts.topics == 1)
            #expect(overview.counts.meetings == 1)
            #expect(overview.counts.unacceptedInsights == 1)
        }

        private func seedScopedCustomer(
            in fixture: CustomerIntelligenceFixture
        ) throws -> (rootID: UUID, departmentID: UUID, contactID: UUID) {
            let root = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Acme"
            )
            let department = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: root.id,
                nodeKind: .unit,
                name: "Platform"
            )
            let contact = try fixture.repository.upsertContact(
                vaultId: fixture.vault.id,
                email: "owner@acme.example",
                displayName: "Owner"
            )
            _ = try fixture.repository.addOrganizationMembership(
                organizationId: department.id,
                contactId: contact.id
            )
            return (root.id, department.id, contact.id)
        }

        private func seedScopedProjects(
            in fixture: CustomerIntelligenceFixture,
            contactID: UUID
        ) throws -> (directProjectID: UUID, meetingID: UUID) {
            let directProject = try fixture.repository.createProject(
                vaultId: fixture.vault.id,
                parentProjectId: nil,
                name: "Direct",
                description: "",
                projectType: .customer
            )
            _ = try fixture.repository.addProjectResourceReference(
                projectId: directProject.id,
                resourceType: .contact,
                resourceId: contactID
            )
            let meetingOnlyProject = try fixture.repository.createProject(
                vaultId: fixture.vault.id,
                parentProjectId: nil,
                name: "Meeting only",
                description: "",
                projectType: .customer
            )
            let meeting = MeetingRecord(
                id: .v7(),
                vaultId: fixture.vault.id,
                projectId: meetingOnlyProject.id,
                name: "Customer sync",
                status: .ready,
                createdAt: .now,
                updatedAt: .now
            )
            try fixture.manager.dbQueue.write { db in
                try meeting.insert(db)
                try MeetingParticipantRecord(
                    meetingId: meeting.id,
                    contactId: contactID,
                    role: .required,
                    responseStatus: .accepted,
                    source: "test",
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
            }
            return (directProject.id, meeting.id)
        }

        private func seedScopedResources(
            in fixture: CustomerIntelligenceFixture,
            organizationID: UUID,
            contactID: UUID,
            meetingID: UUID
        ) throws -> (directTopicID: UUID, directInsightID: UUID) {
            let directTopic = try fixture.repository.createConversationTopic(
                vaultId: fixture.vault.id,
                title: "Direct topic",
                currentState: "Active",
                references: [.init(resourceType: .organization, resourceID: organizationID)]
            )
            _ = try fixture.repository.createConversationTopic(
                vaultId: fixture.vault.id,
                title: "Meeting-only topic",
                currentState: "Active",
                references: [.init(resourceType: .meeting, resourceID: meetingID, note: "Evidence")]
            )
            let directInsight = try fixture.repository.createInsight(
                vaultId: fixture.vault.id,
                content: "Direct insight"
            )
            _ = try fixture.repository.addInsightReference(
                insightId: directInsight.id,
                resourceType: .contact,
                resourceId: contactID,
                role: .context
            )
            let meetingOnlyInsight = try fixture.repository.createInsight(
                vaultId: fixture.vault.id,
                content: "Meeting-only insight"
            )
            _ = try fixture.repository.addInsightReference(
                insightId: meetingOnlyInsight.id,
                resourceType: .meeting,
                resourceId: meetingID,
                role: .evidence
            )
            return (directTopic.id, directInsight.id)
        }

        @Test
        func workspaceStillLoadsOrganizationsWhenInsightCountFails() async throws {
            let fixture = try CustomerIntelligenceFixture()
            let organization = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Visible organization"
            )
            try await fixture.manager.dbQueue.write { db in
                try db.execute(sql: "ALTER TABLE insights RENAME COLUMN isAccepted TO legacyAccepted")
            }
            let model = CustomerIntelligenceWorkspaceViewModel(
                dbQueue: fixture.manager.dbQueue,
                vaultID: fixture.vault.id
            )

            await model.load()

            #expect(model.roots.map(\.id) == [organization.id])
            #expect(model.counts.unacceptedInsights == 0)
            #expect(model.errorMessage != nil)
        }

        @Test
        func recordNavigationKeepsSidebarSectionAndSelectionsIndependent() async {
            let settings = AppSettings.shared
            let previousSection = settings.customerIntelligenceSectionRawValue
            let previousScope = settings.customerIntelligenceScopeRawValue
            defer {
                settings.customerIntelligenceSectionRawValue = previousSection
                settings.customerIntelligenceScopeRawValue = previousScope
            }
            settings.customerIntelligenceSectionRawValue = CustomerIntelligenceSection.overview.rawValue
            settings.customerIntelligenceScopeRawValue = ""
            let model = CustomerIntelligenceWorkspaceViewModel(dbQueue: nil, vaultID: nil)
            let contactID = UUID()
            let topicID = UUID()

            await model.openContact(contactID)
            await model.openTopic(topicID)

            #expect(model.section == .topics)
            #expect(model.selection.contactID == contactID)
            #expect(model.selection.topicID == topicID)
            model.selectSection(.overview)
            #expect(model.selection.topicID == topicID)
        }

        @Test
        func linkedRecordOutsideTheCurrentCustomerScopeOpensInAllCustomers() async throws {
            let settings = AppSettings.shared
            let previousSection = settings.customerIntelligenceSectionRawValue
            let previousScope = settings.customerIntelligenceScopeRawValue
            defer {
                settings.customerIntelligenceSectionRawValue = previousSection
                settings.customerIntelligenceScopeRawValue = previousScope
            }
            settings.customerIntelligenceSectionRawValue = CustomerIntelligenceSection.overview.rawValue
            settings.customerIntelligenceScopeRawValue = ""
            let fixture = try CustomerIntelligenceFixture()
            let first = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "First"
            )
            let second = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Second"
            )
            let contact = try fixture.repository.upsertContact(
                vaultId: fixture.vault.id,
                email: "second@example.com",
                displayName: "Second Contact"
            )
            _ = try fixture.repository.addOrganizationMembership(
                organizationId: second.id,
                contactId: contact.id
            )
            let model = CustomerIntelligenceWorkspaceViewModel(
                dbQueue: fixture.manager.dbQueue,
                vaultID: fixture.vault.id
            )
            await model.load()
            await model.selectScope(.organization(first.id))

            await model.openContact(contact.id)

            #expect(model.scope == .all)
            #expect(model.section == .contacts)
            #expect(model.selection.contactID == contact.id)
        }

        @Test
        func workspaceRestoresLastSectionAndCustomerScope() {
            let settings = AppSettings.shared
            let previousSection = settings.customerIntelligenceSectionRawValue
            let previousScope = settings.customerIntelligenceScopeRawValue
            defer {
                settings.customerIntelligenceSectionRawValue = previousSection
                settings.customerIntelligenceScopeRawValue = previousScope
            }
            let rootID = UUID()
            settings.customerIntelligenceSectionRawValue = CustomerIntelligenceSection.projects.rawValue
            settings.customerIntelligenceScopeRawValue = rootID.uuidString

            let model = CustomerIntelligenceWorkspaceViewModel(dbQueue: nil, vaultID: nil)

            #expect(model.section == .projects)
            #expect(model.scope == .organization(rootID))
        }
    }
#endif
