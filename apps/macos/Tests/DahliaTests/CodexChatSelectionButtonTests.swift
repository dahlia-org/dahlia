#if canImport(Testing)
    import AppKit
    import SwiftUI
    import Testing
    @testable import Dahlia

    @MainActor
    struct CodexChatSelectionButtonTests {
        @Observable
        final class ModelPanelPresentation {
            var isPresented = false
        }

        @Test(arguments: [false, true], ["left", "right", "top", "bottom"])
        func paddingTogglesTheSelectionPanel(isApproval: Bool, edge: String) async throws {
            let session = CodexChatSessionModel(service: TestCodexChatService(mode: .complete))
            let presentation = ModelPanelPresentation()
            let modelPresentation = Binding(
                get: { presentation.isPresented },
                set: { presentation.isPresented = $0 }
            )
            var buttonSize = CGSize.zero
            let button = Group {
                if isApproval {
                    CodexChatApprovalMethodButton(session: session)
                } else {
                    CodexChatConfigurationButton(session: session, externalPresentation: modelPresentation)
                }
            }
            let host = NSHostingView(rootView: button
                .onGeometryChange(for: CGSize.self) { $0.size } action: { actual in
                    buttonSize = actual
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(40)
                .background(Color.black)
                .overlay {
                    if !isApproval {
                        CodexChatConfigurationOverlay(session: session, isPresented: modelPresentation)
                    }
                })
            host.frame = CGRect(x: 0, y: 0, width: 700, height: 500)
            let window = NSWindow(contentRect: host.frame, styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            window.makeKeyAndOrderFront(nil)
            host.layoutSubtreeIfNeeded()
            try #require(await pollUntil { buttonSize.width > 0 })
            let size = buttonSize

            let panelRegion = host.convert(CGRect(x: isApproval ? 60 : 640, y: 100, width: 20, height: 20), from: nil)
            let before = try snapshot(host, in: panelRegion)
            let point = switch edge {
            case "left": CGPoint(x: 42, y: 40 + size.height / 2)
            case "right": CGPoint(x: 40 + size.width - 2, y: 40 + size.height / 2)
            case "top": CGPoint(x: 40 + size.width / 2, y: 40 + size.height - 2)
            default: CGPoint(x: 40 + size.width / 2, y: 42)
            }
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
                ))
                NSApplication.shared.sendEvent(event)
            }
            #expect(await pollUntil(timeout: .seconds(2)) {
                guard let after = try? snapshot(host, in: panelRegion) else { return false }
                return after != before
            })

            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
                ))
                NSApplication.shared.sendEvent(event)
                if type == .leftMouseDown {
                    #expect(!(await pollUntil(timeout: .milliseconds(100)) {
                        guard let after = try? snapshot(host, in: panelRegion) else { return false }
                        return after == before
                    }))
                }
            }
            #expect(await pollUntil(timeout: .seconds(2)) {
                guard let after = try? snapshot(host, in: panelRegion) else { return false }
                return after == before
            })
        }

        private func snapshot(_ host: NSView, in region: CGRect) throws -> Data {
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: region))
            host.cacheDisplay(in: region, to: bitmap)
            return try #require(bitmap.tiffRepresentation)
        }
    }
#endif
