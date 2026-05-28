import SwiftUI
import UIKit

// Lightweight file image view (preview only)
struct FileImageView: View {
    let url: URL
    let targetMaxPixelSize: Int
    let isInteracting: Bool
    @State private var uiImage: UIImage?
    private var requestKey: String { "\(url.path)|\(targetMaxPixelSize)" }

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
        .task(id: requestKey) { await load() }
    }

    private func load() async {
        guard url.isFileURL else { return }
        let request = ThumbnailPipeline.shared.request(for: targetMaxPixelSize, isInteracting: isInteracting)

        if let cached = await ThumbnailPipeline.shared.cachedImage(for: url, matchingOrNearestTo: request.level) {
            await MainActor.run {
                self.uiImage = cached.image
            }
            if cached.level == request.level || isInteracting {
                return
            }
        }

        let image = await ThumbnailPipeline.shared.image(for: url, request: request)
        guard !Task.isCancelled else { return }
        await MainActor.run {
            self.uiImage = image
        }
    }

    static func requestedThumbnailPixelSize(
        screenMaxDimensionPoints: CGFloat,
        displayScale: CGFloat,
        isInteracting: Bool
    ) -> Int {
        let requestedPixels = screenMaxDimensionPoints * displayScale
        return ThumbnailPipeline.shared.level(for: requestedPixels, isInteracting: isInteracting)
    }
}
