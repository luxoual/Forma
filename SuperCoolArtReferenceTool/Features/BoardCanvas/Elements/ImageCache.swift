import UIKit
import ImageIO

actor ThumbnailPipeline {
    struct Request: Hashable {
        let level: Int
        let allowsUpgrade: Bool
    }

    struct CachedThumbnail {
        let level: Int
        let image: UIImage
    }

    static let shared = ThumbnailPipeline()
    nonisolated private static let thumbnailLevels = [128, 256, 384, 512, 768, 1024, 1536, 2048]

    private let cache = ImageCache()
    private let decodeLimiter = AsyncLimiter(limit: 4)
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    nonisolated func request(for pixelSize: Int, isInteracting: Bool) -> Request {
        let level = level(for: CGFloat(pixelSize), isInteracting: isInteracting)
        return Request(level: level, allowsUpgrade: !isInteracting)
    }

    nonisolated func level(for requestedPixels: CGFloat, isInteracting: Bool) -> Int {
        let clamped = max(128, min(2048, Int(requestedPixels.rounded(.up))))
        let maxInteractiveLevel = 512
        let upperBound = isInteracting ? maxInteractiveLevel : 2048
        let limited = min(clamped, upperBound)
        for level in Self.thumbnailLevels where level >= limited {
            return level
        }
        return upperBound
    }

    func cachedImage(for url: URL, matchingOrNearestTo level: Int) async -> CachedThumbnail? {
        await cache.cachedImage(for: url, matchingOrNearestTo: level)
    }

    func image(for url: URL, request: Request) async -> UIImage? {
        let cacheKey = makeCacheKey(url: url, level: request.level)
        if let exact = await cache.image(forKey: cacheKey) {
            return exact
        }

        if request.allowsUpgrade,
           let cached = await cache.cachedImage(for: url, matchingOrNearestTo: request.level),
           cached.level >= request.level {
            return cached.image
        }

        if let task = inFlight[cacheKey] {
            return await task.value
        }

        let task = Task(priority: .utility) { [decodeLimiter] () -> UIImage? in
            await decodeLimiter.withPermit {
                await Task.detached(priority: .utility) { () -> UIImage? in
                    let options: [CFString: Any] = [
                        kCGImageSourceShouldCache: false,
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: request.level,
                        kCGImageSourceCreateThumbnailWithTransform: true
                    ]
                    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                    if let cgImage = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) {
                        return UIImage(cgImage: cgImage)
                    }
                    return UIImage(contentsOfFile: url.path)
                }.value
            }
        }

        inFlight[cacheKey] = task
        let image = await task.value
        inFlight.removeValue(forKey: cacheKey)
        if let image {
            await cache.insert(image, forKey: cacheKey, url: url, level: request.level)
        }
        return image
    }

    private func makeCacheKey(url: URL, level: Int) -> String {
        "\(url.path)|\(level)"
    }
}

actor ImageCache {
    private let cache = NSCache<NSString, UIImage>()
    private var levelsByURL: [String: Set<Int>] = [:]

    init() {
        cache.countLimit = 768
        cache.totalCostLimit = 256 * 1024 * 1024
    }

    func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func cachedImage(for url: URL, matchingOrNearestTo requestedLevel: Int) -> ThumbnailPipeline.CachedThumbnail? {
        let path = url.path
        let levels = levelsByURL[path] ?? []

        guard !levels.isEmpty else { return nil }

        let preferredLevel = levels.sorted().first(where: { $0 >= requestedLevel })
            ?? levels.sorted().last
        guard let preferredLevel else { return nil }

        let key = "\(path)|\(preferredLevel)"
        guard let image = cache.object(forKey: key as NSString) else { return nil }
        return ThumbnailPipeline.CachedThumbnail(level: preferredLevel, image: image)
    }

    func insert(_ image: UIImage, forKey key: String, url: URL, level: Int) {
        let pixelCount = Int(image.size.width * image.size.height * image.scale * image.scale)
        let cost = max(pixelCount * 4, 1)
        cache.setObject(image, forKey: key as NSString, cost: cost)
        levelsByURL[url.path, default: []].insert(level)
    }
}

actor AsyncLimiter {
    private let limit: Int
    private var activeCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async {
        if activeCount < limit {
            activeCount += 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.resume()
        } else {
            activeCount = max(0, activeCount - 1)
        }
    }

    func withPermit<T>(_ operation: @Sendable () async -> T) async -> T {
        await acquire()
        let result = await operation()
        release()
        return result
    }
}
