#if canImport(Testing)
    import AppKit
    import SwiftUI
    import Testing
    @testable import Dahlia

    @MainActor
    struct DahliaToggleStyleTests {
        @Test(arguments: [ColorScheme.light, .dark], [ControlSize.small, .regular])
        func uncheckedCheckboxIsVisibleAgainstAppSurfaces(colorScheme: ColorScheme, size: ControlSize) throws {
            let surfaces = [
                Color(nsColor: .controlBackgroundColor),
                Color(nsColor: .windowBackgroundColor),
                colorScheme == .dark ? Color.black : .white,
            ]
            for surface in surfaces {
                let view = Toggle(isOn: .constant(false)) { EmptyView() }
                    .toggleStyle(.dahliaCheckbox)
                    .controlSize(size)
                    .fixedSize()
                    .padding(4)
                    .background(surface)
                    .environment(\.colorScheme, colorScheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let bitmap = try NSBitmapImageRep(cgImage: #require(renderer.cgImage))
                let background = try #require(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))
                var strongestContrast: CGFloat = 1
                for y in 0 ..< bitmap.pixelsHigh {
                    for x in 0 ..< bitmap.pixelsWide {
                        let pixel = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                        let values = [luminance(background), luminance(pixel)].sorted()
                        strongestContrast = max(strongestContrast, (values[1] + 0.05) / (values[0] + 0.05))
                    }
                }
                #expect(strongestContrast >= 3, "\(colorScheme), \(size): \(strongestContrast):1")
            }
        }

        @Test(arguments: [ColorScheme.light, .dark], [false, true])
        func knobContrastsWithTrack(colorScheme: ColorScheme, isOn: Bool) throws {
            for size in [ControlSize.small, .regular] {
                let (knob, track) = try renderedColors(colorScheme: colorScheme, isOn: isOn, size: size)
                let luminances = [knob, track].map(luminance).sorted()
                let contrast = (luminances[1] + 0.05) / (luminances[0] + 0.05)
                #expect(contrast >= 3, "\(colorScheme), \(size), on=\(isOn): \(contrast):1")
            }
        }

        @Test(arguments: [ColorScheme.light, .dark], [ControlSize.small, .regular])
        func knobColorStaysTheSame(colorScheme: ColorScheme, size: ControlSize) throws {
            let off = try renderedColors(colorScheme: colorScheme, isOn: false, size: size).knob
            let on = try renderedColors(colorScheme: colorScheme, isOn: true, size: size).knob
            #expect(abs(off.redComponent - on.redComponent) < 0.01)
            #expect(abs(off.greenComponent - on.greenComponent) < 0.01)
            #expect(abs(off.blueComponent - on.blueComponent) < 0.01)
        }

        private func renderedColors(colorScheme: ColorScheme, isOn: Bool, size: ControlSize) throws -> (knob: NSColor, track: NSColor) {
            let view = Toggle("Setting", isOn: .constant(isOn))
                .toggleStyle(.dahliaSwitch)
                .labelsHidden()
                .controlSize(size)
                .fixedSize()
                .background(colorScheme == .dark ? Color.black : .white)
                .environment(\.colorScheme, colorScheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let bitmap = try NSBitmapImageRep(cgImage: #require(renderer.cgImage))
            let y = bitmap.pixelsHigh / 2
            let left = bitmap.pixelsHigh / 2
            let right = bitmap.pixelsWide - left
            let knob = try #require(bitmap.colorAt(x: isOn ? right : left, y: y)?.usingColorSpace(.sRGB))
            let track = try #require(bitmap.colorAt(x: isOn ? left : right, y: y)?.usingColorSpace(.sRGB))
            return (knob, track)
        }

        private func luminance(_ color: NSColor) -> CGFloat {
            let components = [color.redComponent, color.greenComponent, color.blueComponent].map {
                $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * components[0] + 0.7152 * components[1] + 0.0722 * components[2]
        }
    }
#endif
