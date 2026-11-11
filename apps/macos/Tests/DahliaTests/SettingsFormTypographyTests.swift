#if canImport(Testing)
    import AppKit
    import SwiftUI
    import Testing
    @testable import Dahlia

    @MainActor
    struct SettingsFormTypographyTests {
        @Test
        func nativeFieldsAndMenuPickersUseTheBaseFont() throws {
            let form = Form {
                TextField("Name", text: .constant("Example"))
                SecureField("Password", text: .constant("Example"))
                DahliaMenuPicker(title: "Choice", selection: .constant("a"), options: ["a", "b"], label: { $0 })
            }
            .formStyle(.grouped)
            .font(.dahliaBody)
            let host = NSHostingView(rootView: form)
            host.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
            let window = NSWindow(contentRect: host.frame, styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            window.makeKeyAndOrderFront(nil)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()

            let fields: [NSTextField] = descendants(in: host)
            #expect(fields.count >= 2)
            for field in fields {
                #expect(field.font?.pointSize == 14)
            }
            let menus: [NSPopUpButton] = descendants(in: host)
            let menu = try #require(menus.first)
            // The native control's font property can remain 13 while its displayed attributed title uses the supplied font.
            let title = menu.attributedTitle
            let font = try #require(title.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            #expect(font.pointSize == 14)
        }

        private func descendants<T: NSView>(in view: NSView) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(in: $0) }
        }
    }
#endif
