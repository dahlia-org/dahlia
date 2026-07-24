import Foundation
#if canImport(Testing)
    import Testing
    @testable import Dahlia

    struct ProjectNodeTests {
        @Test
        func marksDirectParentAsHavingChildren() {
            let rows = FlatProjectRow.buildRows(
                fromRecords: projects(named: ["foo", "foo/bar"])
            )

            #expect(rows.map(\.hasChildren) == [true, false])
        }

        @Test
        func ignoresSiblingPrefixesWhenDeterminingChildren() {
            let rows = FlatProjectRow.buildRows(
                fromRecords: projects(named: ["foo", "foo-archive", "foo/bar"])
            )

            #expect(rows.map(\.hasChildren) == [true, false, false])
        }

        @Test
        func ignoresNonDescendantPrefixMatches() {
            let rows = FlatProjectRow.buildRows(
                fromRecords: projects(named: ["foo", "foo.bar", "foo/bar", "foo0"])
            )

            #expect(rows.map(\.hasChildren) == [true, false, false, false])
        }

        @Test
        func marksIntermediateNodesAsHavingChildren() {
            let rows = FlatProjectRow.buildRows(
                fromRecords: projects(named: ["a/b", "a/b/c", "z"])
            )

            #expect(rows.map(\.hasChildren) == [true, false, false])
        }

        @Test
        func keepsInputOrderWhileComputingChildrenIndependently() {
            let rows = FlatProjectRow.buildRows(
                fromRecords: projects(named: ["foo/bar", "foo", "foo/baz"])
            )

            #expect(rows.map(\.name) == ["foo/bar", "foo", "foo/baz"])
            #expect(rows.map(\.hasChildren) == [false, true, false])
        }

        @Test
        func buildsNestedProjectTreeWithRecursiveMeetingCounts() {
            let nodes = ProjectTreeNode.buildNodes(
                from: projectOverviews(named: [
                    ("foo", 2), ("foo/bar", 1), ("foo/bar/baz", 3), ("z", 4),
                ])
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
                from: projectOverviews(named: [
                    ("foo", 2), ("foo/bar", 1), ("foo/bar/baz", 3), ("z", 4),
                ])
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
                from: projectOverviews(named: [
                    ("Café", 0), ("Café/Planning", 2), ("Archive", 1),
                ])
            )

            let filteredNodes = nodes.compactMap { $0.filtered(matching: "cafe") }

            #expect(filteredNodes.map(\.displayName) == ["Café"])
            #expect(filteredNodes.first?.children?.map(\.displayName) == ["Planning"])
        }

        @Test
        func projectSearchReturnsNoNodesForUnmatchedQuery() {
            let nodes = ProjectTreeNode.buildNodes(
                from: projectOverviews(named: [("Alpha", 0), ("Alpha/Beta", 1)])
            )

            #expect(nodes.compactMap { $0.filtered(matching: "Gamma") }.isEmpty)
        }

        private func projects(named names: [String]) -> [ProjectRecord] {
            let ids = Dictionary(uniqueKeysWithValues: names.map { ($0, UUID.v7()) })
            let vaultID = UUID.v7()
            return names.map { name in
                let components = name.split(separator: "/")
                let parentPath = components.dropLast().joined(separator: "/")
                return ProjectRecord(
                    id: ids[name]!,
                    vaultId: vaultID,
                    parentProjectId: parentPath.isEmpty ? nil : ids[parentPath],
                    leafName: String(components.last!),
                    createdAt: Date(),
                    projectType: parentPath.isEmpty ? .undefined : nil,
                    resolvedPath: name
                )
            }
        }

        private func projectOverviews(named values: [(String, Int)]) -> [ProjectOverviewItem] {
            let ids = Dictionary(uniqueKeysWithValues: values.map { ($0.0, UUID.v7()) })
            return values.map { name, meetingCount in
                let components = name.split(separator: "/")
                let parentPath = components.dropLast().joined(separator: "/")
                return ProjectOverviewItem(
                    projectId: ids[name]!,
                    projectName: name,
                    projectLeafName: String(components.last!),
                    parentProjectId: parentPath.isEmpty ? nil : ids[parentPath],
                    createdAt: Date(),
                    missingOnDisk: false,
                    meetingCount: meetingCount,
                    latestMeetingDate: nil
                )
            }
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
