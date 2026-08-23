import SwiftUI

struct ScreenshotSearchResultImage: View {
    let imageState: ScreenshotImageLoadModel.State

    var body: some View {
        Group {
            if case let .loaded(image) = imageState {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(DahliaDesign.secondaryTextColor)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DahliaDesign.contentHighlightColor)
        .clipped()
    }
}
