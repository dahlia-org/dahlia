enum ScreenshotGridSizing {
    static let minimumWidth = 110.0
    static let maximumWidth = 200.0
    static let defaultMinimumWidth = maximumWidth
    /// 最大幅のタイルを標準的な 2x Retina で等倍表示できるデコード上限。
    static let maximumThumbnailPixelSize = Int(maximumWidth * 2)
}
