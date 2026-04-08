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
    @State private var isInteracting: Bool = false
    @State private var interactionEndTask: Task<Void, Never>? = nil

    // Grid options
    @Binding private var showGrid: Bool
    @Binding private var canvasColor: Color
    @State private var gridSpacingWorld: CGFloat = 128.0
    @Environment(\.displayScale) private var displayScale

    // Placed images (source-of-truth for interactions)
    @State private var placedImages: [PlacedImage] = []
    // Render-only set from viewport culling
    @State private var visibleImages: [PlacedImage] = []
    @State private var nextZIndex: Int = 0
    @State private var canvasSize: CGSize = .zero

    // Backend store for tile-based culling
    @State private var canvasStore: LocalBoardStore
    @State private var refreshTask: Task<Void, Never>? = nil

    // Drop/import types (images and GIFs only)
    private let allowedDropTypes: [UTType] = [.image, .gif]

    // Image sizing constraints in world units (adjust as desired)
    private let maxImageDimensionWorld: CGFloat = 512
    private let minImageDimensionWorld: CGFloat = 64

    // Zoom bounds
    private let minScale: CGFloat = 0.05
    private let maxScale: CGFloat = 8.0

    // Active tool from toolbar
    @Binding private var activeTool: CanvasTool
    // Selection state
    @State private var selection = CanvasSelectionState()
    @State private var currentDragMode: DragMode? = nil
    @State private var dragStartWorldPos: CGPoint? = nil

    // Binding to receive external insert requests (e.g., from toolbar)
    @Binding private var externalInsertURLs: [URL]?

    @Binding private var snapshotTrigger: UUID?
    private let onSnapshot: (([CMCanvasElement]) -> Void)?
    @Binding private var elementsToLoad: [CMCanvasElement]?

    init(activeTool: Binding<CanvasTool> = .constant(.pointer), externalInsertURLs: Binding<[URL]?> = .constant(nil), showGrid: Binding<Bool> = .constant(true), canvasColor: Binding<Color> = .constant(.white), snapshotTrigger: Binding<UUID?> = .constant(nil), loadElements: Binding<[CMCanvasElement]?> = .constant(nil), onInsertURLs: @escaping ImportHandler = { _ in }, onSnapshot: (([CMCanvasElement]) -> Void)? = nil) {
        let store = LocalBoardStore()
        self._canvasStore = State(initialValue: store)
        self._activeTool = activeTool
        self._externalInsertURLs = externalInsertURLs
        self._showGrid = showGrid
        self._canvasColor = canvasColor
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

                // Render visible images only (world -> screen mapping)
                ForEach(visibleImages) { item in
                    let isSelected = selection.selectedIDs.contains(item.id)
                    let isBeingResized = selection.isResizing && selection.resizeElementID == item.id
                    let liveRect = isBeingResized ? (selection.resizeCurrentRect ?? item.worldRect) : item.worldRect

                    let liveDX = (isSelected && selection.isDragging) ? selection.dragOffset.width * scale : 0
                    let liveDY = (isSelected && selection.isDragging) ? selection.dragOffset.height * scale : 0

                    let maxDimensionPoints = max(liveRect.width * scale, liveRect.height * scale)
                    let requestedPixelSize = FileImageView.bucketedMaxPixelSize(maxDimensionPoints * displayScale)
                    let targetMaxPixelSize = isInteracting ? min(requestedPixelSize, 768) : requestedPixelSize
                    FileImageView(url: item.url, targetMaxPixelSize: targetMaxPixelSize, isInteracting: isInteracting)
                        .frame(width: liveRect.width * scale,
                               height: liveRect.height * scale)
                        .overlay {
                            if isSelected {
                                SelectionOverlay()
                            }
                        }
                        .position(x: (liveRect.midX * scale) + offset.width + liveDX,
                                  y: (liveRect.midY * scale) + offset.height + liveDY)
                        .shadow(radius: isInteracting ? 0 : 1)
                        .zIndex(Double(item.zIndex))
                }
            }
            .onDrop(of: allowedDropTypes, delegate: CanvasDropDelegate(allowedTypes: allowedDropTypes) { point, urls in
                insertImages(atScreenPoint: point, urls: urls)
            })
            .background {
                canvasColor.ignoresSafeArea()
            }
            .border(Color.gray.opacity(0.4), width: 1)
            .onAppear {
                canvasSize = geo.size
                // Center the canvas on world origin (0, 0) on first appearance
                if offset == .zero {
                    offset = CGSize(width: geo.size.width / 2, height: geo.size.height / 2)
                }
                scheduleRefreshVisibleElements()
            }
            .onChange(of: geo.size) { oldValue, newValue in
                canvasSize = newValue
                scheduleRefreshVisibleElements()
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
                Task {
                    let elements = await canvasStore.allElements()
                    await MainActor.run {
                        onSnapshot?(elements)
                    }
                }
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
            // Drag: routed through active tool behavior
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        startInteraction()
                        if currentDragMode == nil {
                            // First event — check for handle hit before tool behavior
                            dragStartOffset = offset

                            if let (handle, item) = hitTestHandle(screenPoint: value.startLocation) {
                                // Resize mode
                                selection.resizeHandle = handle
                                selection.resizeStartRect = item.worldRect
                                selection.resizeElementID = item.id
                                currentDragMode = .resizeItem
                                applyDrag(value: value, mode: .resizeItem)
                                return
                            }

                            // Normal tool behavior routing
                            let worldStart = screenToWorld(value.startLocation)
                            dragStartWorldPos = worldStart
                            let behavior = toolBehavior(for: activeTool)
                            let store = canvasStore
                            let sel = selection
                            Task { @MainActor in
                                let mode = await behavior.dragBegan(
                                    worldStart: worldStart,
                                    store: store,
                                    selection: sel
                                )
                                currentDragMode = mode
                                applyDrag(value: value, mode: mode)
                            }
                            return
                        }
                        if let mode = currentDragMode {
                            applyDrag(value: value, mode: mode)
                        }
                    }
                    .onEnded { value in
                        if currentDragMode == .moveItem {
                            commitMove()
                        } else if currentDragMode == .resizeItem {
                            commitResize()
                        }
                        currentDragMode = nil
                        dragStartOffset = nil
                        dragStartWorldPos = nil
                        selection.isDragging = false
                        selection.dragOffset = .zero
                        endInteraction()
                    }
            )
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { value in
                        let worldPt = screenToWorld(value.location)
                        let behavior = toolBehavior(for: activeTool)
                        let store = canvasStore
                        let sel = selection
                        Task {
                            await behavior.tapped(worldPoint: worldPt, store: store, selection: sel)
                            await refreshVisibleElements()
                        }
                    }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        startInteraction()
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
                        scheduleRefreshVisibleElements()
                    }
                    .onEnded { _ in
                        zoomStartScale = nil
                        endInteraction()
                    }
            )
        }
    }

    // MARK: - Helpers

    private func clamp(_ value: CGFloat, _ minVal: CGFloat, _ maxVal: CGFloat) -> CGFloat {
        min(max(value, minVal), maxVal)
    }

    private func startInteraction() {
        interactionEndTask?.cancel()
        if !isInteracting {
            isInteracting = true
        }
    }

    private func endInteraction() {
        interactionEndTask?.cancel()
        interactionEndTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            isInteracting = false
        }
    }

    // MARK: - Handle Hit-Testing

    /// Screen-space hit radius for grabbing handles
    private let handleHitRadius: CGFloat = 30

    /// Check if a screen point is near any handle on the selected item.
    /// Returns the handle position and the item's world rect if hit.
    private func hitTestHandle(screenPoint: CGPoint) -> (HandlePosition, PlacedImage)? {
        guard selection.selectedIDs.count == 1,
              let selectedID = selection.selectedIDs.first,
              let item = visibleImages.first(where: { $0.id == selectedID }) else {
            return nil
        }

        let itemScreenRect = CGRect(
            x: item.worldRect.origin.x * scale + offset.width,
            y: item.worldRect.origin.y * scale + offset.height,
            width: item.worldRect.width * scale,
            height: item.worldRect.height * scale
        )

        var bestHandle: HandlePosition?
        var bestDist: CGFloat = .greatestFiniteMagnitude

        for handle in HandlePosition.allCases {
            let handleScreenPt = handle.point(in: itemScreenRect.size)
            let handleAbsolute = CGPoint(
                x: itemScreenRect.origin.x + handleScreenPt.x,
                y: itemScreenRect.origin.y + handleScreenPt.y
            )
            let dx = screenPoint.x - handleAbsolute.x
            let dy = screenPoint.y - handleAbsolute.y
            let dist = sqrt(dx * dx + dy * dy)
            if dist < handleHitRadius && dist < bestDist {
                bestDist = dist
                bestHandle = handle
            }
        }

        if let handle = bestHandle {
            return (handle, item)
        }
        return nil
    }

    // MARK: - Drag Helpers

    private func applyDrag(value: DragGesture.Value, mode: DragMode) {
        switch mode {
        case .pan:
            guard let start = dragStartOffset else { return }
            offset = CGSize(
                width: start.width + value.translation.width,
                height: start.height + value.translation.height
            )
            scheduleRefreshVisibleElements()
        case .moveItem:
            let worldDX = value.translation.width / scale
            let worldDY = value.translation.height / scale
            selection.dragOffset = CGSize(width: worldDX, height: worldDY)
            selection.isDragging = true
        case .resizeItem:
            applyResize(translation: value.translation)
        case .none:
            break
        }
    }

    // MARK: - Resize Logic

    private func applyResize(translation: CGSize) {
        guard let handle = selection.resizeHandle,
              let startRect = selection.resizeStartRect else { return }

        let worldDX = translation.width / scale
        let worldDY = translation.height / scale

        let anchorPos = handle.anchorPosition
        let anchorPt = anchorPos.point(in: startRect.size)
        let anchorWorld = CGPoint(
            x: startRect.origin.x + anchorPt.x,
            y: startRect.origin.y + anchorPt.y
        )

        let handlePt = handle.point(in: startRect.size)
        let draggedWorld = CGPoint(
            x: startRect.origin.x + handlePt.x + worldDX,
            y: startRect.origin.y + handlePt.y + worldDY
        )

        var newRect: CGRect

        if handle.isCorner {
            // Aspect-ratio locked resize
            let aspect = startRect.width / max(startRect.height, 0.001)

            var rawW = abs(draggedWorld.x - anchorWorld.x)
            var rawH = abs(draggedWorld.y - anchorWorld.y)

            // Lock aspect ratio to whichever axis moved more
            if rawW / max(aspect, 0.001) > rawH {
                rawH = rawW / aspect
            } else {
                rawW = rawH * aspect
            }

            // Enforce minimum size
            rawW = max(rawW, minImageDimensionWorld)
            rawH = max(rawH, minImageDimensionWorld / max(aspect, 0.001))

            // Build rect from anchor point, expanding toward the dragged corner
            let originX = handle.isLeftSide ? anchorWorld.x - rawW : anchorWorld.x
            let originY = handle.isTopSide ? anchorWorld.y - rawH : anchorWorld.y

            newRect = CGRect(x: originX, y: originY, width: rawW, height: rawH)
        } else {
            // Single-axis edge resize
            var newOrigin = startRect.origin
            var newSize = startRect.size

            switch handle {
            case .topCenter:
                let newTop = min(draggedWorld.y, anchorWorld.y - minImageDimensionWorld)
                newSize.height = anchorWorld.y - newTop
                newOrigin.y = newTop
            case .bottomCenter:
                let newBottom = max(draggedWorld.y, anchorWorld.y + minImageDimensionWorld)
                newSize.height = newBottom - anchorWorld.y
                newOrigin.y = anchorWorld.y
            case .leftCenter:
                let newLeft = min(draggedWorld.x, anchorWorld.x - minImageDimensionWorld)
                newSize.width = anchorWorld.x - newLeft
                newOrigin.x = newLeft
            case .rightCenter:
                let newRight = max(draggedWorld.x, anchorWorld.x + minImageDimensionWorld)
                newSize.width = newRight - anchorWorld.x
                newOrigin.x = anchorWorld.x
            default:
                return
            }

            newRect = CGRect(origin: newOrigin, size: newSize)
        }

        selection.resizeCurrentRect = newRect
    }

    private func commitResize() {
        guard let elementID = selection.resizeElementID,
              let newRect = selection.resizeCurrentRect else {
            selection.clearResize()
            return
        }

        // Update local placedImages
        if let idx = placedImages.firstIndex(where: { $0.id == elementID }) {
            placedImages[idx].worldRect = newRect
        }

        // Update visibleImages to prevent flash
        if let idx = visibleImages.firstIndex(where: { $0.id == elementID }) {
            visibleImages[idx].worldRect = newRect
        }

        // Batch update backend store
        let store = canvasStore
        Task {
            let fetched = await store.elements(for: [elementID])
            if var element = fetched[elementID] {
                element.header.bounds = CMWorldRect(
                    origin: SIMD2<Double>(Double(newRect.origin.x), Double(newRect.origin.y)),
                    size: SIMD2<Double>(Double(newRect.width), Double(newRect.height))
                )
                if case .image(let url, _) = element.payload {
                    element.payload = .image(
                        url: url,
                        size: SIMD2<Double>(Double(newRect.width), Double(newRect.height))
                    )
                }
                await store.upsert(elements: [element])
            }
            await refreshVisibleElements()
        }

        selection.clearResize()
    }

    private func commitMove() {
        let dx = selection.dragOffset.width
        let dy = selection.dragOffset.height
        guard dx != 0 || dy != 0 else { return }

        let idsToMove = selection.selectedIDs

        // Update local placedImages
        for i in placedImages.indices {
            if idsToMove.contains(placedImages[i].id) {
                placedImages[i].worldRect.origin.x += dx
                placedImages[i].worldRect.origin.y += dy
            }
        }

        // Immediately update visibleImages so there's no flash
        // when dragOffset resets to zero before the async store refresh
        for i in visibleImages.indices {
            if idsToMove.contains(visibleImages[i].id) {
                visibleImages[i].worldRect.origin.x += dx
                visibleImages[i].worldRect.origin.y += dy
            }
        }

        // Batch update backend store
        Task {
            let fetched = await canvasStore.elements(for: Array(idsToMove))
            var updated: [CMCanvasElement] = []
            for (_, var element) in fetched {
                element.header.bounds.origin.x += Double(dx)
                element.header.bounds.origin.y += Double(dy)
                updated.append(element)
            }
            if !updated.isEmpty {
                await canvasStore.upsert(elements: updated)
            }
            await refreshVisibleElements()
        }
    }

    // MARK: - Snapshot / Load Elements (Backend Bridge)

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
        Task {
            await canvasStore.replaceAll(with: elements)
            await refreshVisibleElements()
        }
    }

    private func currentViewportRect() -> CMWorldRect {
        let s = Double(scale)
        let off = offset
        let worldMinX = (-off.width) / CGFloat(s)
        let worldMinY = (-off.height) / CGFloat(s)
        let worldMaxX = (canvasSize.width - off.width) / CGFloat(s)
        let worldMaxY = (canvasSize.height - off.height) / CGFloat(s)
        return CMWorldRect(
            origin: SIMD2<Double>(Double(worldMinX), Double(worldMinY)),
            size: SIMD2<Double>(Double(worldMaxX - worldMinX), Double(worldMaxY - worldMinY))
        )
    }

    private func scheduleRefreshVisibleElements() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            let delay: UInt64 = isInteracting ? 80_000_000 : 40_000_000
            try? await Task.sleep(nanoseconds: delay)
            await refreshVisibleElements()
        }
    }

    private func refreshVisibleElements() async {
        guard canvasSize != .zero else { return }
        let viewport = currentViewportRect()
        let headers = await canvasStore.headers(in: viewport, margin: 512, limit: nil)
        let ids = headers.map { $0.id }
        let elementsById = await canvasStore.elements(for: ids)
        let items: [PlacedImage] = headers.compactMap { header in
            guard let element = elementsById[header.id] else { return nil }
            switch element.payload {
            case .image(let url, _):
                let b = header.bounds
                let rect = CGRect(x: CGFloat(b.origin.x), y: CGFloat(b.origin.y), width: CGFloat(b.size.x), height: CGFloat(b.size.y))
                return PlacedImage(id: header.id, url: url, worldRect: rect, zIndex: header.zIndex)
            default:
                return nil
            }
        }
        visibleImages = items
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

            let header = CMElementHeader(
                id: id,
                type: .image,
                transform: CMAffineTransform2D(),
                bounds: CMWorldRect(
                    origin: SIMD2<Double>(Double(rect.origin.x), Double(rect.origin.y)),
                    size: SIMD2<Double>(Double(rect.size.width), Double(rect.size.height))
                ),
                layerId: UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID(),
                zIndex: z
            )
            let payload = CMCanvasElementPayload.image(
                url: url,
                size: SIMD2<Double>(Double(rect.size.width), Double(rect.size.height))
            )
            let element = CMCanvasElement(header: header, payload: payload)
            Task {
                await canvasStore.upsert(elements: [element])
                await refreshVisibleElements()
            }
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
        let accessGranted = url.startAccessingSecurityScopedResource()
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
}

private final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 512
    }

    func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func insert(_ image: UIImage, forKey key: String) {
        cache.setObject(image, forKey: key as NSString)
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
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                // The provided URL is temporary and deleted when this callback returns,
                // so copy it to a stable temp location before resuming.
                let ext = url.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "dat") : url.pathExtension
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(ext)
                do {
                    try FileManager.default.copyItem(at: url, to: dest)
                    continuation.resume(returning: dest)
                } catch {
                    continuation.resume(returning: nil)
                }
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
