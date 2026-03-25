//
//  ContentView.swift
//  SuperCoolArtReferenceTool
//
//  Created by andy lin on 2/16/26.
//

import SwiftUI
import UniformTypeIdentifiers
import UIKit
import ImageIO
import simd

#if canImport(CanvasModel)
import CanvasModel
#endif

// MARK: - CMElement compatibility (fallback)
// A local element wrapper used when a concrete CMElement type isn't available.
struct CMElementCompat {
    var header: CMElementHeader
    var payloadURL: URL
}

extension LocalBoardStore {
    /// Compatibility upsert that stores headers when CMElement isn't available.
    func upsertCompat(elements: [CMElementCompat]) async {
        await upsert(headers: elements.map { $0.header })
    }
}

struct ContentView: View {
    // View transform (world -> screen)
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero

    // Gesture state
    @State private var dragStartOffset: CGSize? = nil
    @State private var zoomStartScale: CGFloat? = nil

    // Grid options
    @State private var showGrid: Bool = true
    @State private var gridSpacingWorld: CGFloat = 128.0

    @State private var store = LocalBoardStore()

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

    @State private var defaultLayerId: CMLayerID = UUID()

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                Toggle("Grid", isOn: $showGrid)
                    .toggleStyle(.switch)
                Spacer()
                Button("- ") { zoom(by: 0.8, anchor: nil) }
                Text("Scale: \(String(format: "%.2f", scale))")
                Button("+ ") { zoom(by: 1.25, anchor: nil) }
                InsertFileControl { urls in
                    insertImagesAtCenter(urls)
                }
            }
            .padding(.horizontal)

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

                        // Draw origin crosshair for reference
                        let originX = 0 * s + off.width
                        let originY = 0 * s + off.height
                        var cross = Path()
                        cross.move(to: CGPoint(x: originX - 8, y: originY))
                        cross.addLine(to: CGPoint(x: originX + 8, y: originY))
                        cross.move(to: CGPoint(x: originX, y: originY - 8))
                        cross.addLine(to: CGPoint(x: originX, y: originY + 8))
                        ctx.stroke(cross, with: .color(.red.opacity(0.8)), lineWidth: 1)
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
                .onAppear { canvasSize = geo.size }
                .onChange(of: geo.size) { newSize in
                    canvasSize = newSize
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
        .padding()
    }

    // MARK: - Helpers

    private func clamp(_ value: CGFloat, _ minVal: CGFloat, _ maxVal: CGFloat) -> CGFloat {
        min(max(value, minVal), maxVal)
    }

    private func zoom(by factor: CGFloat, anchor: CGPoint?) {
        // Zoom around provided anchor or view center if nil
        // We need a proxy for the view size; perform a center-anchored zoom if no anchor.
        // Here, we approximate by using the visible midpoint in screen space (0.5, 0.5) of last known geometry.
        // For simplicity, if no anchor is provided, use the current screen center derived from offset/scale.
        // This is a rough approximation suitable for dev buttons.
        let newScale = clamp(scale * factor, minScale, maxScale)
        let screenAnchor = anchor ?? CGPoint(x: 0.5 * UIScreen.main.bounds.width,
                                             y: 0.5 * UIScreen.main.bounds.height)
        let worldXBefore = (screenAnchor.x - offset.width) / scale
        let worldYBefore = (screenAnchor.y - offset.height) / scale
        scale = newScale
        let newOffsetX = screenAnchor.x - worldXBefore * newScale
        let newOffsetY = screenAnchor.y - worldYBefore * newScale
        offset = CGSize(width: newOffsetX, height: newOffsetY)
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

            // Prepare header for LocalBoardStore (headers-only upsert)
            let cmRect = CMWorldRect(
                origin: SIMD2<Double>(Double(rect.origin.x), Double(rect.origin.y)),
                size: SIMD2<Double>(Double(rect.size.width), Double(rect.size.height))
            )
            let transform = CMAffineTransform2D() // identity transform

            let id = UUID()
            let z = nextZIndex
            placedImages.append(PlacedImage(id: id, url: url, worldRect: rect, zIndex: z))
            nextZIndex += 1
            // Insert with stable default layer ID
            // let layerId: CMLayerID = UUID()  // replaced with:
            let layerId: CMLayerID = defaultLayerId

            let header = CMElementHeader(id: id, type: CMElementType.image, transform: transform, bounds: cmRect, layerId: layerId, zIndex: z)
            let element = CMElementCompat(header: header, payloadURL: url)
            Task { await store.upsertCompat(elements: [element]) }
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

//
// MARK: - Drop Handling (file-scope)
//

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
    ContentView()
}

