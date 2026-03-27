import SwiftUI
import UniformTypeIdentifiers
import UIKit
import ImageIO
import simd

struct BoardCanvasView: View {
    typealias ImportHandler = ([URL]) -> Void
    private let onInsertURLs: ImportHandler

    // View transform (world -> screen)
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero

    // Gesture state
    @State private var dragStartOffset: CGSize? = nil
    @State private var zoomStartScale: CGFloat? = nil

    // Grid options
    @Binding private var showGrid: Bool
    @State private var gridSpacingWorld: CGFloat = 128.0

    // Placed images
    @State private var placedImages: [PlacedImage] = []
    @State private var nextZIndex: Int = 0
    @State private var canvasSize: CGSize = .zero

    // Drop/import types (images and GIFs only)
    private let allowedDropTypes: [UTType] = [.image, .gif]

    // Image sizing constraints in world units (adjust as desired)
    private let maxImageDimensionWorld: CGFloat = 512
    private let minImageDimensionWorld: CGFloat = 64

    // Zoom bounds
    private let minScale: CGFloat = 0.05
    private let maxScale: CGFloat = 8.0

    // Binding to receive external insert requests (e.g., from toolbar)
    @Binding private var externalInsertURLs: [URL]?

    @Binding private var snapshotTrigger: UUID?
    private let onSnapshot: (([CMCanvasElement]) -> Void)?
    @Binding private var elementsToLoad: [CMCanvasElement]?

    init(externalInsertURLs: Binding<[URL]?> = .constant(nil), showGrid: Binding<Bool> = .constant(true), snapshotTrigger: Binding<UUID?> = .constant(nil), loadElements: Binding<[CMCanvasElement]?> = .constant(nil), onInsertURLs: @escaping ImportHandler = { _ in }, onSnapshot: (([CMCanvasElement]) -> Void)? = nil) {
        self._externalInsertURLs = externalInsertURLs
        self._showGrid = showGrid
        self.onInsertURLs = onInsertURLs
        self._snapshotTrigger = snapshotTrigger
        self._elementsToLoad = loadElements
        self.onSnapshot = onSnapshot
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Grid background
                Canvas { ctx, size in
                    guard showGrid else { return }

                    let s = scale
                    let off = offset

                    // Visible world rect
                    let worldMinX = (-off.width) / s
                    let worldMinY = (-off.height) / s
                    let worldMaxX = (size.width - off.width) / s
                    let worldMaxY = (size.height - off.height) / s

                    // Draw minor grid lines
                    var path = Path()
                    let spacing = max(8.0, gridSpacingWorld)

                    // Start lines aligned to world grid
                    let startX = floor(worldMinX / spacing) * spacing
                    let startY = floor(worldMinY / spacing) * spacing

                    // Vertical lines
                    var x = startX
                    while x <= worldMaxX {
                        let screenX = x * s + off.width
                        path.move(to: CGPoint(x: screenX, y: 0))
                        path.addLine(to: CGPoint(x: screenX, y: size.height))
                        x += spacing
                    }
                    // Horizontal lines
                    var y = startY
                    while y <= worldMaxY {
                        let screenY = y * s + off.height
                        path.move(to: CGPoint(x: 0, y: screenY))
                        path.addLine(to: CGPoint(x: size.width, y: screenY))
                        y += spacing
                    }

                    ctx.stroke(path, with: .color(.gray.opacity(0.25)), lineWidth: 0.5)
                }
                .ignoresSafeArea()

                // Render placed images (world -> screen mapping)
                ForEach(placedImages) { item in
                    FileImageView(url: item.url)
                        .frame(width: item.worldRect.width * scale,
                               height: item.worldRect.height * scale)
                        .position(x: (item.worldRect.midX * scale) + offset.width,
                                  y: (item.worldRect.midY * scale) + offset.height)
                        .shadow(radius: 1)
                        .zIndex(Double(item.zIndex))
                }
            }
            .onDrop(of: allowedDropTypes, delegate: CanvasDropDelegate(allowedTypes: allowedDropTypes) { point, urls in
                insertImages(atScreenPoint: point, urls: urls)
            })
            .border(Color.gray.opacity(0.4), width: 1)
            .onAppear {
                canvasSize = geo.size
                // Center the canvas on world origin (0, 0) on first appearance
                if offset == .zero {
                    offset = CGSize(width: geo.size.width / 2, height: geo.size.height / 2)
                }
            }
            .onChange(of: geo.size) { oldValue, newValue in
                canvasSize = newValue
            }
            .onChange(of: externalInsertURLs) { oldValue, newValue in
                if let urls = newValue, !urls.isEmpty {
                    insertImagesAtCenter(urls)
                    // Clear the binding after processing
                    DispatchQueue.main.async {
                        externalInsertURLs = nil
                    }
                }
            }
            .onChange(of: snapshotTrigger) { oldValue, newValue in
                // When token changes, produce a snapshot and call back
                guard newValue != nil else { return }
                let elements = snapshotElements()
                onSnapshot?(elements)
            }
            .onChange(of: elementsToLoad) { oldValue, newValue in
                if let els = newValue {
                    applyElements(els)
                    // Clear the binding after applying
                    DispatchQueue.main.async {
                        elementsToLoad = nil
                    }
                }
            }
            .contentShape(Rectangle())
            // Drag to pan
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragStartOffset == nil { dragStartOffset = offset }
                        guard let start = dragStartOffset else { return }
                        offset = CGSize(width: start.width + value.translation.width,
                                        height: start.height + value.translation.height)
                    }
                    .onEnded { _ in
                        dragStartOffset = nil
                    }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        if zoomStartScale == nil { zoomStartScale = scale }
                        let startScale = zoomStartScale ?? scale
                        let newScale = clamp(startScale * value, minScale, maxScale)

                        // Zoom around the view center
                        let anchor = CGPoint(x: geo.size.width / 2.0, y: geo.size.height / 2.0)
                        let worldXBefore = (anchor.x - offset.width) / scale
                        let worldYBefore = (anchor.y - offset.height) / scale

                        scale = newScale
                        let newOffsetX = anchor.x - worldXBefore * newScale
                        let newOffsetY = anchor.y - worldYBefore * newScale
                        offset = CGSize(width: newOffsetX, height: newOffsetY)
                    }
                    .onEnded { _ in
                        zoomStartScale = nil
                    }
            )
        }
    }

    // MARK: - Helpers

    private func clamp(_ value: CGFloat, _ minVal: CGFloat, _ maxVal: CGFloat) -> CGFloat {
        min(max(value, minVal), maxVal)
    }

    // MARK: - Snapshot / Load Elements (Backend Bridge)

    private func snapshotElements() -> [CMCanvasElement] {
        let defaultLayer = UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID()
        return placedImages.map { item in
            let rect = item.worldRect
            let header = CMElementHeader(
                id: item.id,
                type: .image,
                transform: CMAffineTransform2D(),
                bounds: CMWorldRect(
                    origin: SIMD2<Double>(Double(rect.origin.x), Double(rect.origin.y)),
                    size: SIMD2<Double>(Double(rect.size.width), Double(rect.size.height))
                ),
                layerId: defaultLayer,
                zIndex: item.zIndex
            )
            let payload = CMCanvasElementPayload.image(
                url: item.url,
                size: SIMD2<Double>(Double(rect.size.width), Double(rect.size.height))
            )
            return CMCanvasElement(header: header, payload: payload)
        }
    }

    private func applyElements(_ elements: [CMCanvasElement]) {
        placedImages.removeAll()
        nextZIndex = 0
        for el in elements {
            switch el.payload {
            case .image(let url, _):
                let b = el.header.bounds
                let rect = CGRect(x: CGFloat(b.origin.x), y: CGFloat(b.origin.y), width: CGFloat(b.size.x), height: CGFloat(b.size.y))
                let z = el.header.zIndex
                placedImages.append(PlacedImage(id: el.id, url: url, worldRect: rect, zIndex: z))
                nextZIndex = max(nextZIndex, z + 1)
            default:
                // Ignore non-image payloads in this MVP view
                continue
            }
        }
    }

    // MARK: - Image Insertion

    private func insertImagesAtCenter(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let center = CGPoint(x: canvasSize.width / 2.0, y: canvasSize.height / 2.0)
        let resolved = urls.compactMap { makeSandboxCopyIfNeeded(from: $0) }
        insertImages(atScreenPoint: center, urls: resolved)
    }

    private func insertImages(atScreenPoint point: CGPoint, urls: [URL]) {
        for originalURL in urls {
            guard let url = makeSandboxCopyIfNeeded(from: originalURL) else { continue }
            let pixelSize = imagePixelSize(url: url)
            let worldSize = worldSizeForPixelSize(pixelSize)
            let worldCenter = screenToWorld(point)
            // Choose a non-overlapping rect near the desired center
            let desiredCenter = CGPoint(x: worldCenter.x, y: worldCenter.y)
            let rect = firstNonOverlappingRect(near: desiredCenter, size: worldSize)

            let id = UUID()
            let z = nextZIndex
            placedImages.append(PlacedImage(id: id, url: url, worldRect: rect, zIndex: z))
            nextZIndex += 1
        }
    }

    private func screenToWorld(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - offset.width) / scale, y: (p.y - offset.height) / scale)
    }

    private func imagePixelSize(url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            if let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
               let h = props[kCGImagePropertyPixelHeight] as? CGFloat {
                return CGSize(width: w, height: h)
            }
        }
        return nil
    }

    private func worldSizeForPixelSize(_ pixelSize: CGSize?) -> CGSize {
        // Default square if size unknown
        guard let pixelSize, pixelSize.width > 0, pixelSize.height > 0 else {
            return CGSize(width: 256, height: 256)
        }
        let aspect = pixelSize.width / pixelSize.height
        // Scale so that the longer side equals maxImageDimensionWorld, but clamp to min
        if aspect >= 1 {
            // Landscape
            let w = max(minImageDimensionWorld, min(maxImageDimensionWorld, maxImageDimensionWorld))
            let h = w / max(aspect, 0.01)
            return CGSize(width: w, height: h)
        } else {
            // Portrait
            let h = max(minImageDimensionWorld, min(maxImageDimensionWorld, maxImageDimensionWorld))
            let w = h * max(aspect, 0.01)
            return CGSize(width: w, height: h)
        }
    }

    // Find a nearby non-overlapping rect by nudging diagonally until it doesn't intersect existing items
    private func firstNonOverlappingRect(near center: CGPoint, size: CGSize) -> CGRect {
        let maxTries = 64
        let nudge: CGFloat = 24
        var attempt = 0
        var origin = CGPoint(x: center.x - size.width / 2.0,
                             y: center.y - size.height / 2.0)
        var rect = CGRect(origin: origin, size: size)
        while attempt < maxTries && placedImages.contains(where: { $0.worldRect.intersects(rect) }) {
            origin.x += nudge
            origin.y += nudge
            rect.origin = origin
            attempt += 1
        }
        return rect
    }

    // Copy a picked URL into the app's Application Support/ImportedImages directory for reliable access
    private func makeSandboxCopyIfNeeded(from url: URL) -> URL? {
        // If it's already in our container, just return it
        if url.isFileURL, url.path.contains(Bundle.main.bundleIdentifier ?? "") {
            return url
        }
        var accessGranted = url.startAccessingSecurityScopedResource()
        defer { if accessGranted { url.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return url }
        let dir = appSupport.appendingPathComponent("ImportedImages", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let ext = url.pathExtension.isEmpty ? "dat" : url.pathExtension
            let dest = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
            // Prefer a direct file copy; fall back to Data if needed
            do {
                try fm.copyItem(at: url, to: dest)
                return dest
            } catch {
                if let data = try? Data(contentsOf: url) {
                    try data.write(to: dest, options: [.atomic])
                    return dest
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    // MARK: - Models

    private struct PlacedImage: Identifiable {
        let id: UUID
        let url: URL
        var worldRect: CGRect
        var zIndex: Int
    }

    // Lightweight file image view (preview only)
    private struct FileImageView: View {
        let url: URL
        @State private var uiImage: UIImage?

        var body: some View {
            Group {
                if let uiImage {
                    Image(uiImage: uiImage)
                        .resizable()
                        .interpolation(.medium)
                        .antialiased(true)
                        .scaledToFill()
                } else {
                    ZStack {
                        Rectangle().fill(Color.secondary.opacity(0.15))
                        ProgressView()
                    }
                }
            }
            .clipped()
            .task { await load() }
        }

        private func load() async {
            guard url.isFileURL else { return }
            if let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
                await MainActor.run { self.uiImage = img }
            }
        }
    }
}

// MARK: - Drop Handling (file-scope)

struct CanvasDropDelegate: DropDelegate {
    let allowedTypes: [UTType]
    let onDrop: (CGPoint, [URL]) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        !info.itemProviders(for: allowedTypes).isEmpty
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: allowedTypes)
        let location = info.location
        Task {
            let urls = await loadURLsFromProviders(providers, preferredTypes: allowedTypes)
            if !urls.isEmpty {
                onDrop(location, urls)
            }
        }
        return true
    }
}

func loadURLsFromProviders(_ providers: [NSItemProvider], preferredTypes: [UTType]) async -> [URL] {
    await withTaskGroup(of: URL?.self) { group in
        for provider in providers {
            if let firstType = preferredTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) {
                group.addTask {
                    if let url = await provider.loadFileURLCompat(for: firstType) { return url }
                    if let dataURL = await provider.loadDataAsTempFileCompat(for: firstType) { return dataURL }
                    return nil
                }
            }
        }
        var results: [URL] = []
        for await url in group { if let url { results.append(url) } }
        return results
    }
}

extension NSItemProvider {
    func loadFileURLCompat(for type: UTType) async -> URL? {
        await withCheckedContinuation { continuation in
            self.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }
    func loadDataAsTempFileCompat(for type: UTType) async -> URL? {
        await withCheckedContinuation { continuation in
            self.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                guard let data else {
                    continuation.resume(returning: nil)
                    return
                }
                let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                let ext = type.preferredFilenameExtension ?? "dat"
                let filename = UUID().uuidString + "." + ext
                let url = tempDir.appendingPathComponent(filename)
                do {
                    try data.write(to: url, options: [.atomic])
                    continuation.resume(returning: url)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

#Preview {
    BoardCanvasView()
}
