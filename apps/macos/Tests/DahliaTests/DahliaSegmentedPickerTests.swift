#if canImport(Testing)
    import AppKit
    import SwiftUI
    import Testing
    @testable import Dahlia

    @MainActor
    struct DahliaSegmentedPickerTests {
        @Test(arguments: [false, true], [false, true])
        func selectionHonorsDisabledStateAndBindingValidation(isDisabled: Bool, rejectsChange: Bool) async throws {
            var selection = false
            var pickerSize = CGSize.zero
            let host = NSHostingView(rootView: DahliaSegmentedPicker(
                title: "Input mode",
                selection: Binding(get: { selection }, set: { if !rejectsChange { selection = $0 } }),
                options: [false, true],
                label: { $0 ? "JSON" : "Form" }
            )
            .labelsHidden()
            .disabled(isDisabled)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { pickerSize = $0 }
            .padding(10)
            .frame(width: 320, height: 80, alignment: .topLeading))
            host.frame = CGRect(x: 0, y: 0, width: 320, height: 80)
            let window = NSWindow(contentRect: host.frame, styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            window.makeKeyAndOrderFront(nil)
            host.layoutSubtreeIfNeeded()
            try #require(await pollUntil { pickerSize.width > 0 })

            // Hit the last segment's padding, outside its text.
            let point = CGPoint(x: 10 + pickerSize.width - 7, y: 80 - 10 - pickerSize.height / 2)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
                ))
                window.sendEvent(event)
            }
            #expect(selection == (!isDisabled && !rejectsChange))
        }
    }
#endif
