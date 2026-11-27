#if canImport(Testing)
    import AppKit
    import Observation
    import SwiftUI
    import Testing
    @testable import Dahlia

    @MainActor
    struct DahliaSegmentedPickerTests {
        @Test(arguments: [false, true], [false, true])
        func keyboardMovesFocusAndCommitsValidatedSelection(inGroupedForm: Bool, rejectsChange: Bool) async throws {
            for (initial, movesRight) in [(0, false), (0, true), (1, false), (1, true)] {
                let state = SegmentedPickerTestSelection()
                state.value = initial
                let selection = Binding(get: { state.value }, set: {
                    state.lastAttempt = $0
                    if !rejectsChange { state.value = $0 }
                })
                let picker = DahliaSegmentedPicker(title: "Input mode", selection: selection, options: [0, 1]) { $0 == 0 ? "Form" : "JSON" }
                let host = NSHostingView(rootView: Group {
                    if inGroupedForm {
                        Form { picker }.formStyle(.grouped)
                    } else {
                        VStack { picker }.padding()
                    }
                }.frame(width: 500, height: 150))
                let before = NSTextField(string: "Before")
                let after = NSTextField(string: "After")
                let stack = NSStackView(views: [before, host, after])
                stack.orientation = .vertical
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 500, height: 220),
                    styleMask: .titled,
                    backing: .buffered,
                    defer: false
                )
                window.isReleasedWhenClosed = false
                window.contentView = stack
                defer { window.close() }
                window.makeKeyAndOrderFront(nil)
                stack.layoutSubtreeIfNeeded()
                try #require(await pollUntil { !focusableLeaves(in: host).isEmpty })
                let targets = focusableLeaves(in: host)
                #expect(targets.count == 1)
                let target = try #require(targets.first)
                // Supply adjacent fields so Tab entry and exit use a stable key loop without changing system preferences.
                window.autorecalculatesKeyViewLoop = false
                before.nextKeyView = target
                target.nextKeyView = after
                try #require(window.makeFirstResponder(before))
                try sendKey("\t", code: 48, to: window)
                try #require(window.firstResponder === target)

                try sendKey(movesRight ? "\u{F703}" : "\u{F702}", code: movesRight ? 124 : 123, to: window)
                #expect(state.value == initial)
                try sendKey(" ", code: 49, to: window)
                let accepted = rejectsChange ? initial : 1 - initial
                try #require(await pollUntil { state.value == accepted })
                #expect(state.lastAttempt == 1 - initial)
                #expect(window.firstResponder === target)
                try sendKey("\t", code: 48, to: window)
                #expect(after.currentEditor() === window.firstResponder)
            }
        }

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

        private func focusableLeaves(in view: NSView) -> [NSView] {
            let children = view.subviews.flatMap { focusableLeaves(in: $0) }
            return children.isEmpty && view.acceptsFirstResponder ? [view] : children
        }

        private func sendKey(_ characters: String, code: UInt16, to window: NSWindow) throws {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = try #require(NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
                ))
                window.sendEvent(event)
            }
        }
    }

    @MainActor @Observable
    private final class SegmentedPickerTestSelection {
        var value = 0
        var lastAttempt: Int?
    }
#endif
