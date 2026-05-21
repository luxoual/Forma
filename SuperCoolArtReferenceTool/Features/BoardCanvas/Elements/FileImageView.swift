import SwiftUI
import UIKit
import ImageIO

// Lightweight file image view (preview only)
struct FileImageView: View {
    let url: URL
    let targetMaxPixelSize: Int
    let isInteracting: Bool
    @State private var uiImage: UIImage?
    private var cacheKey: String { "\(url.path)|\(targetMaxPixelSize)" }

    var body: some View {
        Group {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .interpolation(isInteracting ? .low : .medium)
                    .antialiased(true)
            } else {
                ZStack {
                    Rectangle().fill(Color.secondary.opacity(0.15))
                    ProgressView()
                }
            }
        }
        .clipped()
        .task(id: cacheKey) { await load(cacheKey: cacheKey) }
    }

    private func load(cacheKey: String) async {
        if let cached = ImageCache.shared.image(forKey: cacheKey) {
            await MainActor.run { self.uiImage = cached }
            return
        }

        guard url.isFileURL else { return }
        let pixelSize = targetMaxPixelSize
        let image = await Task.detached(priority: .utility) { () -> UIImage? in
            let options: [CFString: Any] = [
                kCGImageSourceShouldCache: false,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: pixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) {
                return UIImage(cgImage: cgImage)
            }
            return UIImage(contentsOfFile: url.path)
        }.value

        if let image {
            ImageCache.shared.insert(image, forKey: cacheKey)
        }
        await MainActor.run { self.uiImage = image }
    }

    static func bucketedMaxPixelSize(_ value: CGFloat) -> Int {
        let clamped = min(2048, max(128, Int(value.rounded(.up))))
        let bucket = 256
        let bucketed = Int(ceil(Double(clamped) / Double(bucket))) * bucket
        return min(2048, max(128, bucketed))
    }
}
