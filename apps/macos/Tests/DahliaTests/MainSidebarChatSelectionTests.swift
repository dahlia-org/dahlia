#if canImport(Testing)
    import AppKit
    import Testing
    @testable import Dahlia

    struct MainSidebarChatSelectionTests {
        private let order = ["a", "b", "c", "d"]

        @Test func plainClickOpensAndClearsSelection() {
            var selection = MainSidebarChatSelection()
            let selects = selection.click("b", modifiers: .command, order: order, openID: nil)
            #expect(selects)
            let opensThread = !selection.click("c", modifiers: [], order: order, openID: nil)
            #expect(opensThread)
            #expect(selection.ids.isEmpty)
            #expect(!selection.isSelecting)
        }

        @Test func commandClickTogglesAndStartsFromOpenThread() {
            var selection = MainSidebarChatSelection()
            let handled = selection.click("c", modifiers: .command, order: order, openID: "a")
            #expect(handled)
            #expect(selection.ids == ["a", "c"])
            _ = selection.click("a", modifiers: .command, order: order, openID: "a")
            #expect(selection.ids == ["c"])
        }

        @Test func deselectingLastThreadDoesNotReselectOpenThread() {
            var selection = MainSidebarChatSelection()
            _ = selection.click("a", modifiers: .command, order: order, openID: "a")
            #expect(selection.ids.isEmpty)
            #expect(selection.isSelecting)
            _ = selection.click("c", modifiers: .command, order: order, openID: "a")
            #expect(selection.ids == ["c"])
            selection.clear()
            #expect(!selection.isSelecting)
            _ = selection.click("c", modifiers: .command, order: order, openID: "a")
            #expect(selection.ids == ["a", "c"])
        }

        @Test func shiftClickSelectsRangeFromAnchor() {
            var selection = MainSidebarChatSelection()
            _ = selection.click("b", modifiers: [], order: order, openID: nil)
            let handled = selection.click("d", modifiers: .shift, order: order, openID: nil)
            #expect(handled)
            #expect(selection.ids == ["b", "c", "d"])
            _ = selection.click("a", modifiers: .shift, order: order, openID: nil)
            #expect(selection.ids == ["a", "b"])
        }

        @Test func selectionDoesNotCarryAcrossSections() {
            var selection = MainSidebarChatSelection()
            _ = selection.click("a", modifiers: .command, order: order, openID: nil)
            _ = selection.click("x", modifiers: .command, order: ["x", "y"], openID: nil, isSettled: true)
            #expect(selection.ids == ["x"])
        }

        @Test(arguments: [false, true])
        func missingAnchorPreservesSelectionAndDoesNotReseedOpenThread(shift: Bool) {
            var selection = MainSidebarChatSelection()
            _ = selection.click("b", modifiers: .command, order: order, openID: nil)
            _ = selection.click("c", modifiers: .command, order: order, openID: nil)
            _ = selection.click("d", modifiers: shift ? .shift : .command, order: ["a", "b", "d"], openID: "a")
            #expect(selection.ids == ["b", "d"])
        }

        @Test func losingEverySelectedRowKeepsExplicitSelectionMode() {
            var selection = MainSidebarChatSelection()
            _ = selection.click("c", modifiers: .command, order: order, openID: nil)
            _ = selection.click("d", modifiers: .command, order: ["a", "b", "d"], openID: "a")
            #expect(selection.ids == ["d"])
        }
    }
#endif
