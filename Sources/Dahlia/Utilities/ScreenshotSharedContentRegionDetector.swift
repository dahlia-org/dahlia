import CoreGraphics
import Vision

struct ScreenshotSharedContentCandidate: Equatable, Sendable {
    let boundingBox: CGRect
    let confidence: Float
}

enum ScreenshotSharedContentRegionDetector {
    private static let minimumConfidence: Float = 0.8
    private static let minimumNormalizedArea = 0.40
    private static let minimumDominanceRatio = 1.5
    private static let minimumAspectRatio: CGFloat = 0.40
    private static let maximumAspectRatio: CGFloat = 0.85

    static func region(in image: CGImage) async -> CGRect? {
        if let rectangleRegion = await rectangleRegion(in: image) {
            return rectangleRegion
        }
        return await roundedRectangleRegion(in: image)
    }

    private static func rectangleRegion(in image: CGImage) async -> CGRect? {
        var request = DetectRectanglesRequest()
        request.maximumObservations = 4
        request.minimumConfidence = minimumConfidence
        request.minimumSize = 0.35
        request.minimumAspectRatio = Float(minimumAspectRatio)
        request.maximumAspectRatio = Float(maximumAspectRatio)
        request.quadratureToleranceDegrees = 5

        guard let observations = try? await request.perform(on: image) else { return nil }
        return region(
            from: observations.map {
                ScreenshotSharedContentCandidate(
                    boundingBox: $0.boundingBox.cgRect,
                    confidence: $0.confidence
                )
            },
            imageSize: CGSize(width: image.width, height: image.height)
        )
    }

    static func roundedRectangleRegion(in image: CGImage) async -> CGRect? {
        if let lightRegion = await contourRegion(in: image, detectsDarkOnLight: false) {
            return lightRegion
        }
        return await contourRegion(in: image, detectsDarkOnLight: true)
    }

    private static func contourRegion(
        in image: CGImage,
        detectsDarkOnLight: Bool
    ) async -> CGRect? {
        var request = DetectContoursRequest()
        request.maximumImageDimension = 512
        request.detectsDarkOnLight = detectsDarkOnLight
        guard let observation = try? await request.perform(on: image) else { return nil }
        let candidates = observation.topLevelContours.compactMap { contour -> ScreenshotSharedContentCandidate? in
            let points = contour.normalizedPoints
            guard points.count >= 8 else { return nil }
            let minX = points.lazy.map(\.x).min() ?? 0
            let minY = points.lazy.map(\.y).min() ?? 0
            let maxX = points.lazy.map(\.x).max() ?? 0
            let maxY = points.lazy.map(\.y).max() ?? 0
            let boundingBox = CGRect(
                x: CGFloat(minX),
                y: CGFloat(minY),
                width: CGFloat(maxX - minX),
                height: CGFloat(maxY - minY)
            )
            let boundingArea = area(of: boundingBox)
            guard boundingArea > 0,
                  polygonArea(points) >= boundingArea * 0.85 else { return nil }
            return ScreenshotSharedContentCandidate(boundingBox: boundingBox, confidence: 1)
        }
        return region(
            from: candidates,
            imageSize: CGSize(width: image.width, height: image.height)
        )
    }

    static func region(
        from candidates: [ScreenshotSharedContentCandidate],
        imageSize: CGSize
    ) -> CGRect? {
        guard imageSize.width > 0,
              imageSize.height > 0,
              imageSize.width.isFinite,
              imageSize.height.isFinite else { return nil }

        let qualified = candidates
            .filter { isQualified($0, imageSize: imageSize) }
            .sorted { area(of: $0.boundingBox) > area(of: $1.boundingBox) }
        guard let largest = qualified.first else { return nil }
        if qualified.count > 1 {
            let secondArea = area(of: qualified[1].boundingBox)
            guard area(of: largest.boundingBox) >= secondArea * minimumDominanceRatio else { return nil }
        }

        let normalizedRect = largest.boundingBox
        let minX = (normalizedRect.minX * imageSize.width).rounded()
        let minY = ((1 - normalizedRect.maxY) * imageSize.height).rounded()
        let maxX = (normalizedRect.maxX * imageSize.width).rounded()
        let maxY = ((1 - normalizedRect.minY) * imageSize.height).rounded()
        let imageRect = CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
        let imageBounds = CGRect(origin: .zero, size: imageSize)
        guard imageBounds.contains(imageRect), !imageRect.isEmpty else { return nil }
        return imageRect
    }

    private static func isQualified(
        _ candidate: ScreenshotSharedContentCandidate,
        imageSize: CGSize
    ) -> Bool {
        let rect = candidate.boundingBox
        let pixelWidth = rect.width * imageSize.width
        let pixelHeight = rect.height * imageSize.height
        let aspectRatio = min(pixelWidth, pixelHeight) / max(pixelWidth, pixelHeight)
        return candidate.confidence >= minimumConfidence
            && rect.minX >= 0
            && rect.minY >= 0
            && rect.maxX <= 1
            && rect.maxY <= 1
            && pixelWidth > pixelHeight
            && aspectRatio >= minimumAspectRatio
            && aspectRatio <= maximumAspectRatio
            && area(of: rect) >= minimumNormalizedArea
            && rect.width.isFinite
            && rect.height.isFinite
    }

    private static func area(of rect: CGRect) -> CGFloat {
        rect.width * rect.height
    }

    private static func polygonArea(_ points: [simd_float2]) -> CGFloat {
        var doubledArea: Float = 0
        for index in points.indices {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            doubledArea += current.x * next.y - next.x * current.y
        }
        return CGFloat(abs(doubledArea) / 2)
    }
}
