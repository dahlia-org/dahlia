import AppKit
import SwiftUI

extension NSImage {
    /// The bundled Databricks logo, marking Databricks accounts and sign-in.
    static var databricksLogo: NSImage {
        Bundle.appModule.url(forResource: "ProviderDatabricks", withExtension: "svg").flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil) ?? NSImage()
    }
}

extension Image {
    static var databricksLogo: Image { Image(nsImage: .databricksLogo) }
}
