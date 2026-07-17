import Combine
import CoreGraphics
import DahliaRuntimeSupport
import Foundation

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

        guard let image = CGImageDecoder.decode(data, maxPixelSize: maxPixelSize),
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

@MainActor
final class ScreenshotImageLoadModel: ObservableObject {
    enum State {
        case idle
        case loading
        case loaded(CGImage)
        case failed
    }

    @Published private(set) var state: State = .idle
    private var loadGeneration: UInt64 = 0

    func load(screenshotID: UUID, data: Data, maxPixelSize: Int) async {
        loadGeneration &+= 1
        let generation = loadGeneration
        state = .loading
        let image = await ScreenshotImageLoader.shared.image(
            screenshotID: screenshotID,
            data: data,
            maxPixelSize: maxPixelSize
        )
        guard !Task.isCancelled, loadGeneration == generation else { return }
        state = image.map(State.loaded) ?? .failed
    }

    /// Lazy grid が保持している画面外 View からデコード済み画像を解放する。
    func unload() {
        loadGeneration &+= 1
        state = .idle
    }
}
