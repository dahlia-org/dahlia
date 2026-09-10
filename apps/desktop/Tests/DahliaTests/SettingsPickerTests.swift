#if canImport(Testing)
    import AppKit
    import SwiftUI
    import Testing
    @testable import Dahlia

    @MainActor
    struct SettingsPickerTests {
        @Test
        func unavailableSelectionStaysVisibleWithoutChangingItsBinding() throws {
            var selected = "saved-model"
            let host = NSHostingView(rootView: DahliaMenuPicker(
                title: "Model",
                selection: Binding(get: { selected }, set: { selected = $0 }),
                options: ["available-model"],
                label: { $0 }
            ))
            host.frame = NSRect(x: 0, y: 0, width: 500, height: 60)
            host.layoutSubtreeIfNeeded()
            let picker = try #require(popup(in: host))
            #expect(picker.titleOfSelectedItem == "saved-model")
            #expect(picker.itemTitles == ["saved-model", "available-model"])
            #expect(selected == "saved-model")
        }

        private func popup(in view: NSView) -> NSPopUpButton? {
            if let popup = view as? NSPopUpButton { return popup }
            return view.subviews.lazy.compactMap { popup(in: $0) }.first
        }
    }
#endif
