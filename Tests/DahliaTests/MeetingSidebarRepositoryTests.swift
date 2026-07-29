import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct MeetingSidebarRepositoryTests {
        @Test
        func paginatesNewestMeetingsInBoundedBatches() throws {
            let fixture = try MeetingSidebarRepositoryFixture()
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            var insertedIDs: [UUID] = []

            try fixture.manager.dbQueue.write { db in
                for index in 0 ..< 52 {
                    insertedIDs.append(try fixture.insertMeeting(
                        name: "Meeting \(index)",
                        createdAt: start.addingTimeInterval(TimeInterval(index)),
                        in: db
                    ))
                }
            }

            let firstPage = try fixture.manager.dbQueue.read { db in
                try MeetingRepository.fetchMeetingSidebarPage(
                    vaultId: fixture.vault.id,
                    limit: 50,
                    in: db
                )
            }
            let secondPage = try fixture.manager.dbQueue.read { db in
                try MeetingRepository.fetchMeetingSidebarPage(
                    vaultId: fixture.vault.id,
                    after: firstPage.nextCursor,
                    limit: 50,
                    in: db
                )
            }

            #expect(firstPage.items.count == 50)
            #expect(firstPage.items.map(\.id) == Array(insertedIDs.reversed().prefix(50)))
            #expect(firstPage.hasMore)
            #expect(firstPage.groups.flatMap(\.meetings).map(\.id) == firstPage.items.map(\.id))
            #expect(secondPage.items.map(\.id) == Array(insertedIDs.prefix(2).reversed()))
            #expect(!secondPage.hasMore)
        }

        @Test
        func searchesSidebarMetadataButNotTranscriptText() async throws {
            let fixture = try MeetingSidebarRepositoryFixture()
            let expected = try fixture.insertSearchFixtures()

            #expect(try await fixture.resultIDs(query: "Quarterly") == [expected.title])
            #expect(try await fixture.resultIDs(query: "budget") == [expected.description])
            #expect(try await fixture.resultIDs(query: "Acme/Zephyr") == [expected.project])
            #expect(try await fixture.resultIDs(query: "Launch") == [expected.calendar])
            #expect(try await fixture.resultIDs(query: "Customer") == [expected.tag])
            #expect(try await fixture.resultIDs(query: "verbatimneedle").isEmpty)
            #expect(try await fixture.resultIDs(query: "%_") == [expected.literal])
            #expect(try await fixture.resultIDs(query: "resume") == [expected.localized])
            #expect(try await fixture.resultIDs(query: "Priority") == [expected.separatorTag])
        }

        @Test
        func filtersByProjectHierarchyTagsAndDateBounds() async throws {
            let fixture = try MeetingSidebarRepositoryFixture()
            let startDate = Date(timeIntervalSince1970: 1_800_000_000)
            let endDate = startDate.addingTimeInterval(86_400)
            let values = try fixture.insertAdvancedSearchFixtures(
                startDate: startDate,
                endDate: endDate
            )

            let page = try await MeetingRepository.searchMeetingSidebarPage(
                vaultId: fixture.vault.id,
                criteria: MeetingSearchCriteria(
                    text: "Needle",
                    projectIDs: [values.projectID],
                    tagIDs: [values.tagID],
                    startDate: startDate,
                    endDate: endDate
                ),
                limit: 50,
                dbQueue: fixture.manager.dbQueue
            )

            #expect(page.items.map(\.id) == [values.meetingID])
            #expect(page.items.first?.searchMatchContext?.kind == .title)
        }

        @Test
        func reportsTheMetadataThatMatchedFreeText() async throws {
            let fixture = try MeetingSidebarRepositoryFixture()
            _ = try fixture.insertSearchFixtures()

            let page = try await MeetingRepository.searchMeetingSidebarPage(
                vaultId: fixture.vault.id,
                criteria: MeetingSearchCriteria(text: "budget"),
                limit: 50,
                dbQueue: fixture.manager.dbQueue
            )

            #expect(page.items.count == 1)
            #expect(page.items.first?.searchMatchContext?.kind == .description)
            #expect(page.items.first?.searchMatchContext?.text.contains("budget") == true)
        }

        @Test
        func fetchesSelectedMeetingDetailSeparately() throws {
            let fixture = try MeetingSidebarRepositoryFixture()
            let meetingID = try fixture.insertSelectedDetailFixture()

            let overview = try fixture.manager.dbQueue.read { db in
                try MeetingRepository.fetchMeetingDetail(
                    id: meetingID,
                    vaultId: fixture.vault.id,
                    in: db
                )
            }
            let item = try #require(overview)

            #expect(item.meetingName == "Selected meeting")
            #expect(item.meetingDescription == "Overview description")
            #expect(item.projectName == "Acme/Platform")
            #expect(item.calendarEvent?.title == "Calendar title")
            #expect(item.hasSummary)
            #expect(item.tags == [TagInfo(name: "Planning", colorHex: "#123456")])
        }

        @Test
        func fetchesRequestedSidebarItemOutsideMaterializedPages() throws {
            let fixture = try MeetingSidebarRepositoryFixture()
            let meetingID = try fixture.manager.dbQueue.write { db in
                try fixture.insertMeeting(name: "Uncached meeting", in: db)
            }

            let items = try fixture.manager.dbQueue.read { db in
                try MeetingRepository.fetchMeetingSidebarItems(
                    ids: [meetingID],
                    vaultId: fixture.vault.id,
                    in: db
                )
            }

            #expect(items.map(\.id) == [meetingID])
            #expect(items.first?.meetingName == "Uncached meeting")
        }

        @Test
        func fetchesLightweightMeetingReferencesForOneVault() throws {
            let fixture = try MeetingSidebarRepositoryFixture()
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            let olderID = try fixture.manager.dbQueue.write { db in
                try fixture.insertMeeting(name: "Older", createdAt: start, in: db)
            }
            let newerID = try fixture.manager.dbQueue.write { db in
                try fixture.insertMeeting(name: "   ", createdAt: start.addingTimeInterval(1), in: db)
            }

            let references = try fixture.manager.dbQueue.read { db in
                try MeetingRepository.fetchMeetingReferences(vaultId: fixture.vault.id, in: db)
            }

            #expect(references.map(\.id) == [newerID, olderID])
            #expect(references.map(\.name) == [L10n.newMeeting, "Older"])
        }
    }

    private struct MeetingSidebarRepositoryFixture {
        let manager: AppDatabaseManager
        let vault: VaultRecord

        init() throws {
            manager = try AppDatabaseManager(path: ":memory:")
            vault = VaultRecord(
                id: .v7(),
                path: "/tmp/sidebar-repository-tests",
                name: "Test",
                createdAt: .now,
                lastOpenedAt: .now
            )
            try manager.dbQueue.write { db in
                try vault.insert(db)
            }
        }

        func insertSearchFixtures() throws -> SidebarSearchFixtureIDs {
            try manager.dbQueue.write { db in
                let otherVault = VaultRecord(
                    id: .v7(),
                    path: "/tmp/sidebar-repository-other-vault",
                    name: "Other",
                    createdAt: .now,
                    lastOpenedAt: .now
                )
                try otherVault.insert(db)
                let titleID = try insertMeeting(name: "Quarterly Plan", in: db)
                let descriptionID = try insertMeeting(
                    name: "Description match",
                    description: "Discuss the budget forecast",
                    in: db
                )
                let childProjectID = try insertNestedProject(childName: "Zephyr", in: db)
                let projectID = try insertMeeting(name: "Project match", projectId: childProjectID, in: db)
                let calendarKey = try insertCalendarEvent(
                    title: "Launch Review",
                    uid: "sidebar-search@example.com",
                    in: db
                )
                let calendarID = try insertMeeting(name: "Calendar match", calendarKey: calendarKey, in: db)
                let tagID = try insertMeeting(name: "Tag match", in: db)
                try attachTag(name: "Important Customer", colorHex: "#808080", to: tagID, in: db)
                try insertTranscriptOnlyMeeting(text: "verbatimneedle", in: db)
                let literalID = try insertMeeting(name: "Status 100%_ready", in: db)
                let localizedID = try insertMeeting(name: "Résumé review", in: db)
                let separatorTagID = try insertMeeting(name: "Separator tag match", in: db)
                try attachTag(
                    name: "Special\u{1E}Priority\u{1F}Tag",
                    colorHex: "#112233",
                    to: separatorTagID,
                    in: db
                )
                try insertOtherVaultTitleMeeting(vaultId: otherVault.id, in: db)
                return SidebarSearchFixtureIDs(
                    title: titleID,
                    description: descriptionID,
                    project: projectID,
                    calendar: calendarID,
                    tag: tagID,
                    literal: literalID,
                    localized: localizedID,
                    separatorTag: separatorTagID
                )
            }
        }

        func insertSelectedDetailFixture() throws -> UUID {
            try manager.dbQueue.write { db in
                let projectID = try insertNestedProject(childName: "Platform", in: db)
                let calendarKey = try insertCalendarEvent(
                    title: "Calendar title",
                    uid: "selected-overview@example.com",
                    in: db
                )
                let meetingID = try insertMeeting(
                    name: "Selected meeting",
                    description: "Overview description",
                    projectId: projectID,
                    calendarKey: calendarKey,
                    in: db
                )
                try SummaryRecord(
                    meetingId: meetingID,
                    title: "Summary",
                    document: "{}",
                    createdAt: .now
                ).insert(db)
                try attachTag(name: "Planning", colorHex: "#123456", to: meetingID, in: db)
                return meetingID
            }
        }

        func insertAdvancedSearchFixtures(
            startDate: Date,
            endDate: Date
        ) throws -> AdvancedSearchFixtureValues {
            try manager.dbQueue.write { db in
                let rootID = try insertProject(name: "Root", type: .customer, in: db)
                let childID = try insertProject(name: "Child", parentID: rootID, in: db)
                let otherID = try insertProject(name: "Other", type: .internal, in: db)
                let planningTagID = try insertTag(name: "Planning", colorHex: "#123456", in: db)
                let reviewTagID = try insertTag(name: "Review", colorHex: "#654321", in: db)
                let included = try insertMeeting(
                    name: "Needle included",
                    projectId: childID,
                    createdAt: startDate,
                    in: db
                )
                let wrongTag = try insertMeeting(
                    name: "Needle wrong tag",
                    projectId: childID,
                    createdAt: startDate.addingTimeInterval(1),
                    in: db
                )
                let wrongProject = try insertMeeting(
                    name: "Needle wrong project",
                    projectId: otherID,
                    createdAt: startDate.addingTimeInterval(2),
                    in: db
                )
                let excludedEnd = try insertMeeting(
                    name: "Needle excluded end",
                    projectId: childID,
                    createdAt: endDate,
                    in: db
                )
                try attachTag(id: planningTagID, to: included, in: db)
                try attachTag(id: reviewTagID, to: wrongTag, in: db)
                try attachTag(id: planningTagID, to: wrongProject, in: db)
                try attachTag(id: planningTagID, to: excludedEnd, in: db)
                return AdvancedSearchFixtureValues(
                    projectID: rootID,
                    tagID: planningTagID,
                    meetingID: included
                )
            }
        }

        func insertMeeting(
            name: String,
            description: String = "",
            projectId: UUID? = nil,
            createdAt: Date = .now,
            calendarKey: CalendarEventKey? = nil,
            in db: Database
        ) throws -> UUID {
            let id = UUID.v7()
            try MeetingRecord(
                id: id,
                vaultId: vault.id,
                projectId: projectId,
                name: name,
                description: description,
                createdAt: createdAt,
                updatedAt: createdAt,
                calendarEventIcalUid: calendarKey?.icalUid,
                calendarEventRecurrenceId: calendarKey?.recurrenceId
            ).insert(db)
            return id
        }

        func resultIDs(query: String) async throws -> Set<UUID> {
            Set(try await MeetingRepository.searchMeetingSidebarPage(
                vaultId: vault.id,
                query: query,
                limit: 50,
                dbQueue: manager.dbQueue
            ).items.map(\.id))
        }

        private func insertNestedProject(childName: String, in db: Database) throws -> UUID {
            let root = ProjectRecord(
                id: .v7(),
                vaultId: vault.id,
                parentProjectId: nil,
                name: "Acme",
                createdAt: .now,
                projectType: .customer
            )
            let child = ProjectRecord(
                id: .v7(),
                vaultId: vault.id,
                parentProjectId: root.id,
                name: childName,
                createdAt: .now,
                projectType: nil
            )
            try root.insert(db)
            try child.insert(db)
            return child.id
        }

        private func insertProject(
            name: String,
            parentID: UUID? = nil,
            type: ProjectType? = nil,
            in db: Database
        ) throws -> UUID {
            let project = ProjectRecord(
                id: .v7(),
                vaultId: vault.id,
                parentProjectId: parentID,
                name: name,
                createdAt: .now,
                projectType: type
            )
            try project.insert(db)
            return project.id
        }

        private func insertTag(name: String, colorHex: String, in db: Database) throws -> Int64 {
            try TagRecord(name: name, colorHex: colorHex, createdAt: .now).insert(db)
            return db.lastInsertedRowID
        }

        private func attachTag(id: Int64, to meetingID: UUID, in db: Database) throws {
            try MeetingTagRecord(meetingId: meetingID, tagId: id).insert(db)
        }

        private func insertCalendarEvent(
            title: String,
            uid: String,
            in db: Database
        ) throws -> CalendarEventKey {
            let key = CalendarEventKey(
                icalUid: uid,
                recurrenceId: ICalendarRecurrenceID.singleEvent
            )
            try CalendarEventRecord.upsert(
                event: calendarEvent(title: title, key: key),
                now: .now,
                in: db
            )
            return key
        }

        private func attachTag(
            name: String,
            colorHex: String,
            to meetingID: UUID,
            in db: Database
        ) throws {
            try TagRecord(name: name, colorHex: colorHex, createdAt: .now).insert(db)
            let fetchedTagID = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM tags WHERE name = ?",
                arguments: [name]
            )
            let tagID = try #require(fetchedTagID)
            try MeetingTagRecord(meetingId: meetingID, tagId: tagID).insert(db)
        }

        private func insertTranscriptOnlyMeeting(text: String, in db: Database) throws {
            let meetingID = try insertMeeting(name: "Transcript only", in: db)
            try TranscriptSegmentRecord(
                id: .v7(),
                meetingId: meetingID,
                startTime: .now,
                text: text,
                translatedText: nil,
                isConfirmed: true
            ).insert(db)
        }

        private func insertOtherVaultTitleMeeting(vaultId: UUID, in db: Database) throws {
            try MeetingRecord(
                id: .v7(),
                vaultId: vaultId,
                projectId: nil,
                name: "Quarterly Plan",
                createdAt: .now,
                updatedAt: .now
            ).insert(db)
        }

        func calendarEvent(title: String, key: CalendarEventKey) -> CalendarEvent {
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            return CalendarEvent(
                id: "calendar::\(key.recurrenceId)",
                calendarID: "primary",
                calendarName: "Primary",
                calendarColorHex: nil,
                platformId: key.recurrenceId,
                title: title,
                description: "Calendar description",
                icalUid: key.icalUid,
                recurrenceId: key.recurrenceId,
                startDate: start,
                endDate: start.addingTimeInterval(3600),
                isAllDay: false,
                conferenceURI: nil
            )
        }
    }

    private struct SidebarSearchFixtureIDs {
        let title: UUID
        let description: UUID
        let project: UUID
        let calendar: UUID
        let tag: UUID
        let literal: UUID
        let localized: UUID
        let separatorTag: UUID
    }

    private struct AdvancedSearchFixtureValues {
        let projectID: UUID
        let tagID: Int64
        let meetingID: UUID
    }
#endif
