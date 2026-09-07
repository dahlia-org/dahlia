#if canImport(Testing)
    import AppKit
    import SwiftUI
    import Testing
    @testable import Dahlia

    @MainActor
    struct MeetingSyncStatusViewTests {
        @Test
        func syncedSymbolColorsTheInnerCheckmarkGreen() throws {
            let renderer = ImageRenderer(content: MeetingSyncStatusView(state: .synced)
                .padding(8)
                .background(.white)
                .environment(\.colorScheme, .light))
            renderer.scale = 4
            let bitmap = try NSBitmapImageRep(cgImage: #require(renderer.cgImage))
            var greenColumns: [Int] = []
            var grayColumns: [Int] = []
            for y in 0 ..< bitmap.pixelsHigh {
                for x in 0 ..< bitmap.pixelsWide {
                    let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    let red = color.redComponent
                    let green = color.greenComponent
                    let blue = color.blueComponent
                    if green > red + 0.1, green > blue + 0.1 {
                        greenColumns.append(x)
                    } else if max(red, green, blue) < 0.8, abs(red - green) < 0.05, abs(green - blue) < 0.05 {
                        grayColumns.append(x)
                    }
                }
            }
            // The checkmark sits inside the wider cloud outline; swapping palette slots reverses these bounds.
            #expect(try #require(greenColumns.min()) > #require(grayColumns.min()))
            #expect(try #require(greenColumns.max()) < #require(grayColumns.max()))
        }
    }
#endif
