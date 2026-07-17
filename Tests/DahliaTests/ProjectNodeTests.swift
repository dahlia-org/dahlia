import Foundation
#if canImport(Testing)
    import Testing
    @testable import Dahlia

    struct ProjectNodeTests {
        @Test
        func marksDirectParentAsHavingChildren() {
            let rows = FlatProjectRow.buildRows(
                fromRecords: [
                    project(named: "foo"),
                    project(named: "foo/bar"),
                ]
            )

            #expect(rows.map(\.hasChildren) == [true, false])
        }

        @Test
        func ignoresSiblingPrefixesWhenDeterminingChildren() {
            let rows = FlatProjectRow.buildRows(
                fromRecords: [
                    project(named: "foo"),
                    project(named: "foo-archive"),
                    project(named: "foo/bar"),
                ]
            )

            #expect(rows.map(\.hasChildren) == [true, false, false])
        }

        @Test
        func ignoresNonDescendantPrefixMatches() {
            let rows = FlatProjectRow.buildRows(
                fromRecords: [
                    project(named: "foo"),
                    project(named: "foo.bar"),
                    project(named: "foo/bar"),
                    project(named: "foo0"),
                ]
            )

            #expect(rows.map(\.hasChildren) == [true, false, false, false])
        }

        @Test
        func marksIntermediateNodesAsHavingChildren() {
            let rows = FlatProjectRow.buildRows(
                fromRecords: [
                    project(named: "a/b"),
                    project(named: "a/b/c"),
                    project(named: "z"),
                ]
            )

            #expect(rows.map(\.hasChildren) == [true, false, false])
        }

        @Test
        func keepsInputOrderWhileComputingChildrenIndependently() {
            let rows = FlatProjectRow.buildRows(
                fromRecords: [
                    project(named: "foo/bar"),
                    project(named: "foo"),
                    project(named: "foo/baz"),
                ]
            )

            #expect(rows.map(\.name) == ["foo/bar", "foo", "foo/baz"])
            #expect(rows.map(\.hasChildren) == [false, true, false])
        }

        @Test
        func buildsNestedProjectTreeWithRecursiveMeetingCounts() {
            let nodes = ProjectTreeNode.buildNodes(
                from: [
                    projectOverview(named: "foo", meetingCount: 2),
                    projectOverview(named: "foo/bar", meetingCount: 1),
                    projectOverview(named: "foo/bar/baz", meetingCount: 3),
                    projectOverview(named: "z", meetingCount: 4),
                ]
            )

            #expect(nodes.map(\.displayName) == ["foo", "z"])
            #expect(nodes.map(\.meetingCount) == [6, 4])
            #expect(nodes.first?.children?.map(\.displayName) == ["bar"])
            #expect(nodes.first?.children?.first?.meetingCount == 4)
            #expect(nodes.first?.children?.first?.children?.map(\.displayName) == ["baz"])
        }

        @Test
        func filtersProjectTreeKeepingAncestorsAndAggregateCounts() {
            let nodes = ProjectTreeNode.buildNodes(
                from: [
                    projectOverview(named: "foo", meetingCount: 2),
                    projectOverview(named: "foo/bar", meetingCount: 1),
                    projectOverview(named: "foo/bar/baz", meetingCount: 3),
                    projectOverview(named: "z", meetingCount: 4),
                ]
            )
            let filteredNodes = nodes.compactMap { $0.filtered(matching: "baz") }

            #expect(filteredNodes.map(\.displayName) == ["foo"])
            #expect(filteredNodes.first?.meetingCount == 6)
            #expect(filteredNodes.first?.children?.map(\.displayName) == ["bar"])
            #expect(filteredNodes.first?.children?.first?.meetingCount == 4)
            #expect(filteredNodes.first?.children?.first?.children?.map(\.displayName) == ["baz"])
        }

        @Test
        func projectSearchUsesLocalizedStandardMatching() {
            let nodes = ProjectTreeNode.buildNodes(
                from: [
                    projectOverview(named: "Café", meetingCount: 0),
                    projectOverview(named: "Café/Planning", meetingCount: 2),
                    projectOverview(named: "Archive", meetingCount: 1),
                ]
            )

            let filteredNodes = nodes.compactMap { $0.filtered(matching: "cafe") }

            #expect(filteredNodes.map(\.displayName) == ["Café"])
            #expect(filteredNodes.first?.children?.map(\.displayName) == ["Planning"])
        }

        @Test
        func projectSearchReturnsNoNodesForUnmatchedQuery() {
            let nodes = ProjectTreeNode.buildNodes(
                from: [projectOverview(named: "Alpha/Beta", meetingCount: 1)]
            )

            #expect(nodes.compactMap { $0.filtered(matching: "Gamma") }.isEmpty)
        }

        private func project(named name: String) -> ProjectRecord {
            ProjectRecord(id: .v7(), vaultId: .v7(), name: name, createdAt: Date())
        }

        private func projectOverview(named name: String, meetingCount: Int) -> ProjectOverviewItem {
            ProjectOverviewItem(
                projectId: .v7(),
                projectName: name,
                createdAt: Date(),
                missingOnDisk: false,
                meetingCount: meetingCount,
                latestMeetingDate: nil
            )
        }
    }

#elseif canImport(XCTest)
    import XCTest
    @testable import Dahlia

    final class ProjectNodeTests: XCTestCase {
        func testMarksDirectParentAsHavingChildren() {
            let rows = FlatProjectRow.buildRows(
                fromRecords: [
                    project(named: "foo"),
                    project(named: "foo/bar"),
                ]
            )

            XCTAssertEqual(rows.map(\.hasChildren), [true, false])
        }

        func testIgnoresSiblingPrefixesWhenDeterminingChildren() {
            let rows = FlatProjectRow.buildRows(
                fromRecords: [
                    project(named: "foo"),
                    project(named: "foo-archive"),
                    project(named: "foo/bar"),
                ]
            )

            XCTAssertEqual(rows.map(\.hasChildren), [true, false, false])
        }

        func testIgnoresNonDescendantPrefixMatches() {
            let rows = FlatProjectRow.buildRows(
                fromRecords: [
                    project(named: "foo"),
                    project(named: "foo.bar"),
                    project(named: "foo/bar"),
                    project(named: "foo0"),
                ]
            )

            XCTAssertEqual(rows.map(\.hasChildren), [true, false, false, false])
        }

        func testMarksIntermediateNodesAsHavingChildren() {
            let rows = FlatProjectRow.buildRows(
                fromRecords: [
                    project(named: "a/b"),
                    project(named: "a/b/c"),
                    project(named: "z"),
                ]
            )

            XCTAssertEqual(rows.map(\.hasChildren), [true, false, false])
        }

        func testKeepsInputOrderWhileComputingChildrenIndependently() {
            let rows = FlatProjectRow.buildRows(
                fromRecords: [
                    project(named: "foo/bar"),
                    project(named: "foo"),
                    project(named: "foo/baz"),
                ]
            )

            XCTAssertEqual(rows.map(\.name), ["foo/bar", "foo", "foo/baz"])
            XCTAssertEqual(rows.map(\.hasChildren), [false, true, false])
        }

        private func project(named name: String) -> ProjectRecord {
            ProjectRecord(id: .v7(), vaultId: .v7(), name: name, createdAt: Date())
        }
    }
#endif
