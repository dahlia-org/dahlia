import CoreGraphics
import Foundation
import ImageIO

/// スクリーンショットのデコードを直列化し、スクロール中のデコード集中を防ぐ。
actor ScreenshotImageLoader {
    static let shared = ScreenshotImageLoader()

    private struct CacheKey: Hashable {
        let screenshotID: UUID
        let maxPixelSize: Int
    }

    private struct CacheEntry {
        let image: CGImage
        let cost: Int
        var lastAccess: UInt64
    }

    private let cacheCostLimit: Int
    private var cache: [CacheKey: CacheEntry] = [:]
    private var cacheCost = 0
    private var accessCounter: UInt64 = 0

    init(cacheCostLimit: Int = 32 * 1024 * 1024) {
        self.cacheCostLimit = cacheCostLimit
    }

    func image(screenshotID: UUID, data: Data, maxPixelSize: Int) -> CGImage? {
        guard !Task.isCancelled, maxPixelSize > 0 else { return nil }

        let key = CacheKey(screenshotID: screenshotID, maxPixelSize: maxPixelSize)
        accessCounter &+= 1
        if var entry = cache[key] {
            entry.lastAccess = accessCounter
            cache[key] = entry
            return entry.image
        }

        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions),
              !Task.isCancelled else { return nil }

        let cost = image.bytesPerRow * image.height
        cache[key] = CacheEntry(image: image, cost: cost, lastAccess: accessCounter)
        cacheCost += cost
        evictIfNeeded(excluding: key)
        return image
    }

    func remove(screenshotID: UUID) {
        let keys = cache.keys.filter { $0.screenshotID == screenshotID }
        for key in keys {
            if let removed = cache.removeValue(forKey: key) {
                cacheCost -= removed.cost
            }
        }
    }

    private func evictIfNeeded(excluding protectedKey: CacheKey) {
        while cacheCost > cacheCostLimit,
              let oldest = cache
              .filter({ $0.key != protectedKey })
              .min(by: { $0.value.lastAccess < $1.value.lastAccess }) {
            cache.removeValue(forKey: oldest.key)
            cacheCost -= oldest.value.cost
        }
    }
}
