import AppKit
import SwiftUI

extension NSImage {
    /// The bundled Databricks logo, marking Databricks accounts and sign-in.
    static var databricksLogo: NSImage {
        Bundle.appModule.url(forResource: "ProviderDatabricks", withExtension: "svg").flatMap(Self.init(contentsOf:))
            ?? Self(systemSymbolName: "server.rack", accessibilityDescription: nil) ?? Self()
    }
}

extension Image {
    static var databricksLogo: Image { Image(nsImage: .databricksLogo) }

    /// The bundled OpenAI mark, drawn in the text color so it shows in dark mode too.
    static var openAILogo: Image { monochromeLogo("ProviderOpenAI") }

    /// The bundled Claude mark (Font Awesome Free, CC BY 4.0; see `ProviderAnthropic-LICENSE.txt`).
    static var anthropicLogo: Image { monochromeLogo("ProviderAnthropic") }

    private static func monochromeLogo(_ name: String) -> Image {
        guard let image = Bundle.appModule.url(forResource: name, withExtension: "svg").flatMap(NSImage.init(contentsOf:)) else {
            return Image(systemName: "circle.hexagongrid")
        }
        image.isTemplate = true
        return Image(nsImage: image)
    }
}
