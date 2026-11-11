#if canImport(Testing)
    import AppKit
    import SwiftUI
    import Testing
    @testable import Dahlia

    @MainActor
    struct CodexChatSelectionButtonTests {
        @Test(arguments: [false, true], ["left", "right", "top", "bottom"])
        func paddingOpensTheSelectionPanel(isApproval: Bool, edge: String) async throws {
            let session = CodexChatSessionModel(service: TestCodexChatService(mode: .complete), runtimeProviderResolver: { .local })
            var modelPanelPresented = false
            let button = Group {
                if isApproval {
                    CodexChatApprovalMethodButton(session: session)
                } else {
                    CodexChatConfigurationButton(session: session, externalPresentation: Binding(
                        get: { modelPanelPresented },
                        set: { modelPanelPresented = $0 }
                    ))
                }
            }
            let measurement = NSHostingView(rootView: button)
            let size = measurement.fittingSize
            let host = NSHostingView(rootView: button
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(40)
                .background(Color.black))
            host.frame = CGRect(x: 0, y: 0, width: 700, height: 500)
            let window = NSWindow(contentRect: host.frame, styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            window.makeKeyAndOrderFront(nil)
            host.layoutSubtreeIfNeeded()

            let panelRegion = host.convert(CGRect(x: 60, y: 100, width: 20, height: 20), from: nil)
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
                window.sendEvent(event)
            }
            #expect(await pollUntil(timeout: .seconds(2)) {
                if !isApproval { return modelPanelPresented }
                guard let after = try? snapshot(host, in: panelRegion) else { return false }
                return after != before
            })
        }

        private func snapshot(_ host: NSView, in region: CGRect) throws -> Data {
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: region))
            host.cacheDisplay(in: region, to: bitmap)
            return try #require(bitmap.tiffRepresentation)
        }
    }
#endif
