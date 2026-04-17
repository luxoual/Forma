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
    @State private var twoFingerPanStartOffset: CGSize? = nil
    @State private var zoomStartScale: CGFloat? = nil
    @State private var isInteracting: Bool = false
    @State private var interactionEndTask: Task<Void, Never>? = nil

    // Grid options
    @Binding private var showGrid: Bool
    @Binding private var canvasColor: Color
    @State private var gridSpacingWorld: CGFloat = 128.0
    @Environment(\.displayScale) private var displayScale

    // Placed images (source-of-truth for interactions)
    @State private var placedItems: [PlacedCanvasItem] = []
    // Render-only set from viewport culling
    @State private var visibleItems: [PlacedCanvasItem] = []
    @State private var nextZIndex: Int = 0
    @State private var canvasSize: CGSize = .zero
    @State private var textEditorState: TextEditorState?

    // Backend store for tile-based culling
    @State private var canvasStore: LocalBoardStore
    @State private var refreshTask: Task<Void, Never>? = nil
    @State private var storeMutationTask: Task<Void, Never>? = nil

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

    // Command history for undo/redo
    var commandHistory: CanvasCommandHistory
    @Binding private var undoTrigger: UUID?
    @Binding private var redoTrigger: UUID?

    // Binding to receive external insert requests (e.g., from toolbar)
    @Binding private var externalInsertURLs: [URL]?
    @Binding private var pendingTextInsertion: PendingTextInsertion?

    @Binding private var snapshotTrigger: UUID?
    private let onSnapshot: (([CMCanvasElement]) -> Void)?
    @Binding private var elementsToLoad: [CMCanvasElement]?

    @MainActor
    init(activeTool: Binding<CanvasTool> = .constant(.pointer), externalInsertURLs: Binding<[URL]?> = .constant(nil), pendingTextInsertion: Binding<PendingTextInsertion?> = .constant(nil), showGrid: Binding<Bool> = .constant(true), canvasColor: Binding<Color> = .constant(.white), snapshotTrigger: Binding<UUID?> = .constant(nil), loadElements: Binding<[CMCanvasElement]?> = .constant(nil), commandHistory: CanvasCommandHistory, undoTrigger: Binding<UUID?> = .constant(nil), redoTrigger: Binding<UUID?> = .constant(nil), onInsertURLs: @escaping ImportHandler = { _ in }, onSnapshot: (([CMCanvasElement]) -> Void)? = nil) {
        let store = LocalBoardStore()
        self._canvasStore = State(initialValue: store)
        self._activeTool = activeTool
        self._externalInsertURLs = externalInsertURLs
        self._pendingTextInsertion = pendingTextInsertion
        self._showGrid = showGrid
        self._canvasColor = canvasColor
        self.commandHistory = commandHistory
        self._undoTrigger = undoTrigger
        self._redoTrigger = redoTrigger
        self.onInsertURLs = onInsertURLs
        self._snapshotTrigger = snapshotTrigger
        self._elementsToLoad = loadElements
        self.onSnapshot = onSnapshot
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                gridBackgroundView()

                // Render visible canvas items only (world -> screen mapping)
                ForEach(visibleItems) { item in
                    itemLayer(item)
                }

                // Marquee selection rectangle
                if selection.isMarqueeing, let worldRect = selection.marqueeWorldRect {
                    marqueeOverlayView(worldRect: worldRect)
                }

                // Floating action bar under the current selection
                if let bbox = selectionBoundingBox(),
                   !selection.isDragging,
                   !selection.isResizing,
                   !selection.isGroupResizing,
                   !selection.isMarqueeing {
                    selectionActionBarView(bbox: bbox)
                }

                // Group bounding box with resize handles
                if selection.selectedIDs.count > 1, !selection.isDragging {
                    groupSelectionOverlayView()
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
            .onChange(of: pendingTextInsertion) { _, newValue in
                guard let newValue else { return }
                insertTextAtCenter(initialText: newValue.initialText)
                DispatchQueue.main.async {
                    pendingTextInsertion = nil
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
                    commandHistory.clear()
                    // Clear the binding after applying
                    DispatchQueue.main.async {
                        elementsToLoad = nil
                    }
                }
            }
            .onChange(of: undoTrigger) { _, newValue in
                guard newValue != nil else { return }
                performUndo()
                DispatchQueue.main.async { undoTrigger = nil }
            }
            .onChange(of: redoTrigger) { _, newValue in
                guard newValue != nil else { return }
                performRedo()
                DispatchQueue.main.async { redoTrigger = nil }
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

                            if let hitResult = hitTestHandle(screenPoint: value.startLocation) {
                                switch hitResult {
                                case .singleItem(let handle, let item):
                                    selection.resizeHandle = handle
                                    selection.resizeStartRect = item.worldRect
                                    selection.resizeElementID = item.id
                                case .group(let handle, let bbox):
                                    var startRects: [UUID: CGRect] = [:]
                                    for img in placedItems where selection.selectedIDs.contains(img.id) {
                                        startRects[img.id] = img.worldRect
                                    }
                                    selection.groupResizeStartRects = startRects
                                    selection.groupResizeBBoxStart = bbox
                                    selection.groupResizeBBoxCurrent = bbox
                                    selection.resizeHandle = handle
                                }
                                currentDragMode = .resizeItem
                                applyDrag(value: value, mode: .resizeItem)
                                return
                            }

                            // Normal tool behavior routing (synchronous — no async race)
                            let worldStart = screenToWorld(value.startLocation)
                            dragStartWorldPos = worldStart
                            let behavior = toolBehavior(for: activeTool)
                            let items = placedItems.map {
                                HitTestItem(id: $0.id, worldRect: $0.worldRect, zIndex: $0.zIndex)
                            }
                            let mode = behavior.dragBegan(
                                worldStart: worldStart,
                                items: items,
                                selection: selection
                            )
                            currentDragMode = mode
                            if mode == .marqueeSelect {
                                selection.marqueeStartWorld = worldStart
                                selection.marqueeCurrentWorld = worldStart
                            }
                            // Fire-and-forget: reorder in store for z-order persistence
                            if mode == .moveItem {
                                let store = canvasStore
                                let ids = Array(selection.selectedIDs)
                                Task { await store.moveToTop(elementIDs: ids) }
                            }
                            applyDrag(value: value, mode: mode)
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
                            if selection.isGroupResizing {
                                commitGroupResize()
                            } else {
                                commitResize()
                            }
                        } else if currentDragMode == .marqueeSelect {
                            commitMarqueeSelect()
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
            .background(TwoFingerPanView(onPan: handleTwoFingerPan))
            .sheet(item: $textEditorState) { editorState in
                TextBoxEditorSheet(
                    initialText: editorState.text,
                    onCancel: { textEditorState = nil },
                    onSave: { newText in
                        updateTextElement(id: editorState.id, text: newText)
                        textEditorState = nil
                    }
                )
            }
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

    private func handleTwoFingerPan(phase: TwoFingerPanView.Phase, translation: CGSize) {
        switch phase {
        case .began:
            startInteraction()
            twoFingerPanStartOffset = offset
        case .changed:
            let start = twoFingerPanStartOffset ?? offset
            offset = CGSize(width: start.width + translation.width,
                            height: start.height + translation.height)
            scheduleRefreshVisibleElements()
        case .ended:
            twoFingerPanStartOffset = nil
            endInteraction()
        }
    }

    private func gridBackgroundView() -> some View {
        Canvas { ctx, size in
            guard showGrid else { return }

            let s = scale
            let off = offset
            let worldMinX = (-off.width) / s
            let worldMinY = (-off.height) / s
            let worldMaxX = (size.width - off.width) / s
            let worldMaxY = (size.height - off.height) / s

            var path = Path()
            let spacing = max(8.0, gridSpacingWorld)
            let startX = floor(worldMinX / spacing) * spacing
            let startY = floor(worldMinY / spacing) * spacing

            var x = startX
            while x <= worldMaxX {
                let screenX = x * s + off.width
                path.move(to: CGPoint(x: screenX, y: 0))
                path.addLine(to: CGPoint(x: screenX, y: size.height))
                x += spacing
            }

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
        .accessibilityHidden(true)
        .onTapGesture {
            toolBehavior(for: activeTool).tappedEmpty(selection: selection)
        }
    }

    private func itemLayer(_ item: PlacedCanvasItem) -> some View {
        let isSelected = selection.selectedIDs.contains(item.id)
        let liveRect = liveRect(for: item, isSelected: isSelected)
        let liveDX = (isSelected && selection.isDragging) ? selection.dragOffset.width * scale : 0
        let liveDY = (isSelected && selection.isDragging) ? selection.dragOffset.height * scale : 0
        let multiSelected = selection.selectedIDs.count > 1

        return canvasItemPlacementView(
            item: item,
            liveRect: liveRect,
            isSelected: isSelected,
            multiSelected: multiSelected,
            liveDX: liveDX,
            liveDY: liveDY
        )
    }

    private func handleItemTap(itemID: UUID) {
        let behavior = toolBehavior(for: activeTool)
        let store = canvasStore
        let selectionState = selection
        Task {
            await behavior.tappedItem(id: itemID, store: store, selection: selectionState)
            await refreshVisibleElements()
        }
    }

    private func liveRect(for item: PlacedCanvasItem, isSelected: Bool) -> CGRect {
        let isBeingResized = selection.isResizing && selection.resizeElementID == item.id
        let isBeingGroupResized = selection.isGroupResizing && isSelected

        if isBeingGroupResized,
           let startRects = selection.groupResizeStartRects,
           let originalRect = startRects[item.id],
           let bboxStart = selection.groupResizeBBoxStart,
           let bboxCurrent = selection.groupResizeBBoxCurrent {
            return scaledRect(original: originalRect, bboxStart: bboxStart, bboxCurrent: bboxCurrent)
        }

        if isBeingResized {
            return selection.resizeCurrentRect ?? item.worldRect
        }

        return item.worldRect
    }

    private func marqueeOverlayView(worldRect: CGRect) -> some View {
        let screenRect = CGRect(
            x: worldRect.origin.x * scale + offset.width,
            y: worldRect.origin.y * scale + offset.height,
            width: worldRect.width * scale,
            height: worldRect.height * scale
        )

        return MarqueeOverlayView(screenRect: screenRect)
            .allowsHitTesting(false)
            .zIndex(Double(Int.max - 1))
    }

    private func selectionActionBarView(bbox: CGRect) -> some View {
        let screenX = bbox.midX * scale + offset.width
        let screenY = bbox.maxY * scale + offset.height + 24
        let onEdit = selectedTextItemForEditing() != nil ? beginEditingSelectedText : nil

        return CanvasSelectionActionBar(onEdit: onEdit, onDelete: deleteSelection)
            .position(x: screenX, y: screenY)
            .zIndex(Double(Int.max))
    }

    @ViewBuilder
    private func groupSelectionOverlayView() -> some View {
        let bbox = selection.isGroupResizing ? (selection.groupResizeBBoxCurrent ?? groupBoundingBox()) : groupBoundingBox()
        if let bbox {
            let screenRect = CGRect(
                x: bbox.origin.x * scale + offset.width,
                y: bbox.origin.y * scale + offset.height,
                width: bbox.width * scale,
                height: bbox.height * scale
            )
            GroupSelectionOverlay()
                .frame(width: screenRect.width, height: screenRect.height)
                .position(x: screenRect.midX, y: screenRect.midY)
                .allowsHitTesting(false)
                .zIndex(Double(Int.max))
        }
    }

    // MARK: - Handle Hit-Testing

    /// Screen-space hit radius for grabbing handles
    private let handleHitRadius: CGFloat = 30

    private enum HandleHitResult {
        case singleItem(handle: HandlePosition, item: PlacedCanvasItem)
        case group(handle: HandlePosition, bbox: CGRect)
    }

    /// Pure query: hit-test screen point against handles on the current selection.
    private func hitTestHandle(screenPoint: CGPoint) -> HandleHitResult? {
        if selection.selectedIDs.count == 1,
           let selectedID = selection.selectedIDs.first,
           let item = visibleItems.first(where: { $0.id == selectedID }) {
            let itemScreenRect = CGRect(
                x: item.worldRect.origin.x * scale + offset.width,
                y: item.worldRect.origin.y * scale + offset.height,
                width: item.worldRect.width * scale,
                height: item.worldRect.height * scale
            )
            if let handle = hitTestHandleOnRect(screenPoint: screenPoint, screenRect: itemScreenRect) {
                return .singleItem(handle: handle, item: item)
            }
        } else if selection.selectedIDs.count > 1, let bbox = groupBoundingBox() {
            let bboxScreenRect = CGRect(
                x: bbox.origin.x * scale + offset.width,
                y: bbox.origin.y * scale + offset.height,
                width: bbox.width * scale,
                height: bbox.height * scale
            )
            if let handle = hitTestHandleOnRect(screenPoint: screenPoint, screenRect: bboxScreenRect) {
                return .group(handle: handle, bbox: bbox)
            }
        }
        return nil
    }

    /// Shared helper: hit-test a screen point against 8 handles on a screen-space rect.
    private func hitTestHandleOnRect(screenPoint: CGPoint, screenRect: CGRect) -> HandlePosition? {
        var bestHandle: HandlePosition?
        var bestDist: CGFloat = .greatestFiniteMagnitude

        for handle in HandlePosition.allCases {
            let handleScreenPt = handle.point(in: screenRect.size)
            let handleAbsolute = CGPoint(
                x: screenRect.origin.x + handleScreenPt.x,
                y: screenRect.origin.y + handleScreenPt.y
            )
            let dx = screenPoint.x - handleAbsolute.x
            let dy = screenPoint.y - handleAbsolute.y
            let dist = sqrt(dx * dx + dy * dy)
            if dist < handleHitRadius && dist < bestDist {
                bestDist = dist
                bestHandle = handle
            }
        }
        return bestHandle
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
            if selection.isGroupResizing {
                applyGroupResize(translation: value.translation)
            } else {
                applyResize(translation: value.translation)
            }
        case .marqueeSelect:
            let screenCurrent = CGPoint(
                x: value.startLocation.x + value.translation.width,
                y: value.startLocation.y + value.translation.height
            )
            selection.marqueeCurrentWorld = screenToWorld(screenCurrent)
        case .none:
            break
        }
    }

    // MARK: - Resize Logic

    /// Pure function: compute a new rect from a handle drag on a reference rect.
    private func computeResizedRect(
        handle: HandlePosition,
        startRect: CGRect,
        translation: CGSize
    ) -> CGRect? {
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

        if handle.isCorner {
            let aspect = startRect.width / max(startRect.height, 0.001)
            var rawW = abs(draggedWorld.x - anchorWorld.x)
            var rawH = abs(draggedWorld.y - anchorWorld.y)

            if rawW / max(aspect, 0.001) > rawH {
                rawH = rawW / aspect
            } else {
                rawW = rawH * aspect
            }

            rawW = max(rawW, minImageDimensionWorld)
            rawH = max(rawH, minImageDimensionWorld / max(aspect, 0.001))

            let originX = handle.isLeftSide ? anchorWorld.x - rawW : anchorWorld.x
            let originY = handle.isTopSide ? anchorWorld.y - rawH : anchorWorld.y
            return CGRect(x: originX, y: originY, width: rawW, height: rawH)
        } else {
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
                return nil
            }

            return CGRect(origin: newOrigin, size: newSize)
        }
    }

    private func applyResize(translation: CGSize) {
        guard let handle = selection.resizeHandle,
              let startRect = selection.resizeStartRect,
              let newRect = computeResizedRect(handle: handle, startRect: startRect, translation: translation) else { return }
        selection.resizeCurrentRect = newRect
    }

    private func commitResize() {
        guard let elementID = selection.resizeElementID,
              let startRect = selection.resizeStartRect,
              let newRect = selection.resizeCurrentRect else {
            selection.clearResize()
            return
        }

        // Skip no-op resizes (e.g., clamped to min size or negligible drag)
        guard newRect != startRect else {
            selection.clearResize()
            return
        }

        commandHistory.push(.resize(elementID: elementID, fromRect: startRect, toRect: newRect))
        applyResizeRect(elementID: elementID, rect: newRect)
        selection.clearResize()
    }

    // MARK: - Group Resize Logic

    /// World-space union of every currently selected item's rect. Returns nil
    /// if no items are selected. Unlike `groupBoundingBox()` this works for
    /// any non-empty selection (single or multi).
    private func selectionBoundingBox() -> CGRect? {
        let rects = placedItems.filter { selection.selectedIDs.contains($0.id) }.map(\.worldRect)
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    private func groupBoundingBox() -> CGRect? {
        guard selection.selectedIDs.count > 1 else { return nil }
        let rects = placedItems.filter { selection.selectedIDs.contains($0.id) }.map(\.worldRect)
        guard !rects.isEmpty else { return nil }
        return rects.dropFirst().reduce(rects[0]) { $0.union($1) }
    }

    private func scaledRect(original: CGRect, bboxStart: CGRect, bboxCurrent: CGRect) -> CGRect {
        let scaleX = bboxStart.width > 0.001 ? bboxCurrent.width / bboxStart.width : 1
        let scaleY = bboxStart.height > 0.001 ? bboxCurrent.height / bboxStart.height : 1
        let newX = bboxCurrent.origin.x + (original.origin.x - bboxStart.origin.x) * scaleX
        let newY = bboxCurrent.origin.y + (original.origin.y - bboxStart.origin.y) * scaleY
        let newW = original.width * scaleX
        let newH = original.height * scaleY
        return CGRect(x: newX, y: newY, width: newW, height: newH)
    }

    private func applyGroupResize(translation: CGSize) {
        guard let handle = selection.resizeHandle,
              let bboxStart = selection.groupResizeBBoxStart,
              let newBBox = computeResizedRect(handle: handle, startRect: bboxStart, translation: translation) else { return }
        selection.groupResizeBBoxCurrent = newBBox
    }

    private func commitGroupResize() {
        guard let startRects = selection.groupResizeStartRects,
              let bboxStart = selection.groupResizeBBoxStart,
              let bboxCurrent = selection.groupResizeBBoxCurrent,
              bboxStart != bboxCurrent else {
            selection.clearGroupResize()
            return
        }

        var toRects: [UUID: CGRect] = [:]
        for (id, originalRect) in startRects {
            toRects[id] = scaledRect(original: originalRect, bboxStart: bboxStart, bboxCurrent: bboxCurrent)
        }

        commandHistory.push(.groupResize(fromRects: startRects, toRects: toRects))
        applyResizeRects(toRects)
        selection.clearGroupResize()
    }

    // MARK: - Marquee Select

    private func commitMarqueeSelect() {
        guard let rect = selection.marqueeWorldRect else {
            selection.clearMarquee()
            return
        }

        let cmRect = CMWorldRect(
            origin: SIMD2<Double>(Double(rect.origin.x), Double(rect.origin.y)),
            size: SIMD2<Double>(Double(rect.width), Double(rect.height))
        )

        let store = canvasStore
        Task { @MainActor in
            let headers = await store.headers(in: cmRect, limit: nil)
            let ids = Set(headers.map { $0.id })
            selection.selectedIDs = ids
            selection.clearMarquee()
            await refreshVisibleElements()
        }
    }

    private func commitMove() {
        let dx = selection.dragOffset.width
        let dy = selection.dragOffset.height
        guard dx != 0 || dy != 0 else { return }

        let idsToMove = selection.selectedIDs
        commandHistory.push(.move(elementIDs: idsToMove, delta: CGSize(width: dx, height: dy)))
        applyMoveDelta(elementIDs: idsToMove, dx: dx, dy: dy)
    }

    // MARK: - Undo / Redo

    func performUndo() {
        guard let command = commandHistory.popUndo() else { return }
        switch command {
        case .move(let ids, let delta):
            applyMoveDelta(elementIDs: ids, dx: -delta.width, dy: -delta.height)
        case .resize(let id, let fromRect, _):
            applyResizeRect(elementID: id, rect: fromRect)
        case .groupResize(let fromRects, _):
            applyResizeRects(fromRects)
        case .insert(let snapshots):
            removeElements(snapshots: snapshots)
        case .delete(let snapshots):
            addElements(snapshots: snapshots)
        }
    }

    func performRedo() {
        guard let command = commandHistory.popRedo() else { return }
        switch command {
        case .move(let ids, let delta):
            applyMoveDelta(elementIDs: ids, dx: delta.width, dy: delta.height)
        case .resize(let id, _, let toRect):
            applyResizeRect(elementID: id, rect: toRect)
        case .groupResize(_, let toRects):
            applyResizeRects(toRects)
        case .insert(let snapshots):
            addElements(snapshots: snapshots)
        case .delete(let snapshots):
            removeElements(snapshots: snapshots)
        }
    }

    // MARK: - Command Execution Helpers

    /// Enqueue a serialized store mutation. Cancels any in-flight mutation first,
    /// then awaits its completion before running the new one.
    private func enqueueStoreMutation(_ work: @escaping @Sendable (LocalBoardStore) async -> Void) {
        let previous = storeMutationTask
        let store = canvasStore
        storeMutationTask = Task { @MainActor in
            previous?.cancel()
            _ = await previous?.result  // wait for cancellation to settle
            await work(store)
            await refreshVisibleElements()
        }
    }

    private func applyMoveDelta(elementIDs: Set<UUID>, dx: CGFloat, dy: CGFloat) {
        for i in placedItems.indices {
            if elementIDs.contains(placedItems[i].id) {
                placedItems[i].worldRect.origin.x += dx
                placedItems[i].worldRect.origin.y += dy
            }
        }
        for i in visibleItems.indices {
            if elementIDs.contains(visibleItems[i].id) {
                visibleItems[i].worldRect.origin.x += dx
                visibleItems[i].worldRect.origin.y += dy
            }
        }

        enqueueStoreMutation { store in
            let fetched = await store.elements(for: Array(elementIDs))
            var updated: [CMCanvasElement] = []
            for (_, var element) in fetched {
                element.header.bounds.origin.x += Double(dx)
                element.header.bounds.origin.y += Double(dy)
                updated.append(element)
            }
            if !updated.isEmpty {
                await store.upsert(elements: updated)
            }
        }
    }

    private func applyResizeRect(elementID: UUID, rect: CGRect) {
        if let idx = placedItems.firstIndex(where: { $0.id == elementID }) {
            placedItems[idx].worldRect = rect
        }
        if let idx = visibleItems.firstIndex(where: { $0.id == elementID }) {
            visibleItems[idx].worldRect = rect
        }

        enqueueStoreMutation { store in
            let fetched = await store.elements(for: [elementID])
            if var element = fetched[elementID] {
                let previousBounds = element.header.bounds
                element.header.bounds = CMWorldRect(
                    origin: SIMD2<Double>(Double(rect.origin.x), Double(rect.origin.y)),
                    size: SIMD2<Double>(Double(rect.width), Double(rect.height))
                )
                switch element.payload {
                case .image(let url, _):
                    element.payload = .image(
                        url: url,
                        size: SIMD2<Double>(Double(rect.width), Double(rect.height))
                    )
                case .text(let content, let fontName, let fontSize, let color):
                    let scaleFactor = textScaleFactor(from: previousBounds, to: element.header.bounds)
                    element.payload = .text(
                        content: content,
                        fontName: fontName,
                        fontSize: max(12, fontSize * scaleFactor),
                        color: color
                    )
                default:
                    break
                }
                await store.upsert(elements: [element])
            }
        }
    }

    /// Batch-apply multiple resize rects in a single store mutation (used by group resize + undo/redo).
    private func applyResizeRects(_ rects: [UUID: CGRect]) {
        // Update in-memory arrays synchronously
        for (id, rect) in rects {
            if let idx = placedItems.firstIndex(where: { $0.id == id }) {
                placedItems[idx].worldRect = rect
            }
            if let idx = visibleItems.firstIndex(where: { $0.id == id }) {
                visibleItems[idx].worldRect = rect
            }
        }

        // Single batched store mutation
        let ids = Array(rects.keys)
        enqueueStoreMutation { store in
            let fetched = await store.elements(for: ids)
            var updated: [CMCanvasElement] = []
            for (id, rect) in rects {
                if var element = fetched[id] {
                    let previousBounds = element.header.bounds
                    element.header.bounds = CMWorldRect(
                        origin: SIMD2<Double>(Double(rect.origin.x), Double(rect.origin.y)),
                        size: SIMD2<Double>(Double(rect.width), Double(rect.height))
                    )
                    switch element.payload {
                    case .image(let url, _):
                        element.payload = .image(
                            url: url,
                            size: SIMD2<Double>(Double(rect.width), Double(rect.height))
                        )
                    case .text(let content, let fontName, let fontSize, let color):
                        let scaleFactor = textScaleFactor(from: previousBounds, to: element.header.bounds)
                        element.payload = .text(
                            content: content,
                            fontName: fontName,
                            fontSize: max(12, fontSize * scaleFactor),
                            color: color
                        )
                    default:
                        break
                    }
                    updated.append(element)
                }
            }
            await store.upsert(elements: updated)
        }
    }

    private func addElements(snapshots: [PlacedElementSnapshot]) {
        for snap in snapshots {
            if let item = PlacedCanvasItem(element: snap.element) {
                placedItems.append(item)
            }
            nextZIndex = max(nextZIndex, snap.zIndex + 1)
        }

        let elements = snapshots.map { $0.element }
        enqueueStoreMutation { store in
            await store.upsert(elements: elements)
        }
    }

    /// Delete every currently selected item. Acts on `selection.selectedIDs`
    /// regardless of active tool — the action bar only appears when there's a
    /// selection, so the tool-specific resolution that the old context-menu
    /// path needed is unnecessary here.
    ///
    /// Snapshots are fetched from the store so undo restores the authoritative
    /// element (transform, layerId, etc.) rather than a reconstructed one.
    private func deleteSelection() {
        let targetIDs = selection.selectedIDs
        let placedByID: [UUID: PlacedCanvasItem] = Dictionary(
            uniqueKeysWithValues: placedItems
                .filter { targetIDs.contains($0.id) }
                .map { ($0.id, $0) }
        )
        guard !placedByID.isEmpty else { return }

        let store = canvasStore
        Task { @MainActor in
            let elementsByID = await store.elements(for: Array(placedByID.keys))
            let snapshots: [PlacedElementSnapshot] = placedByID.map { id, placed in
                let element = elementsByID[id] ?? placed.element
                return PlacedElementSnapshot(element: element)
            }
            commandHistory.push(.delete(snapshots: snapshots))
            removeElements(snapshots: snapshots)
        }
    }

    private func removeElements(snapshots: [PlacedElementSnapshot]) {
        let idsToRemove = Set(snapshots.map { $0.id })
        placedItems.removeAll { idsToRemove.contains($0.id) }
        visibleItems.removeAll { idsToRemove.contains($0.id) }
        selection.selectedIDs.subtract(idsToRemove)

        enqueueStoreMutation { store in
            await store.delete(elementIDs: Array(idsToRemove))
        }
    }

    // MARK: - Snapshot / Load Elements (Backend Bridge)

    private func applyElements(_ elements: [CMCanvasElement]) {
        placedItems.removeAll()
        nextZIndex = 0
        for el in elements {
            if let item = PlacedCanvasItem(element: el) {
                placedItems.append(item)
                nextZIndex = max(nextZIndex, el.header.zIndex + 1)
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
        let items: [PlacedCanvasItem] = headers.compactMap { header in
            guard let element = elementsById[header.id] else { return nil }
            return PlacedCanvasItem(element: element)
        }
        visibleItems = items
    }

    // MARK: - Image Insertion

    private func insertImagesAtCenter(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let center = CGPoint(x: canvasSize.width / 2.0, y: canvasSize.height / 2.0)
        insertImages(atScreenPoint: center, urls: urls)
    }

    private func insertImages(atScreenPoint point: CGPoint, urls: [URL]) {
        let worldCenter = screenToWorld(point)
        let insertionSpacing: CGFloat = 24
        var preparedImages: [(url: URL, size: CGSize)] = []

        for originalURL in urls {
            guard let url = makeSandboxCopyIfNeeded(from: originalURL) else { continue }
            preparedImages.append((url: url, size: worldSizeForPixelSize(imagePixelSize(url: url))))
        }

        let rects = batchInsertionRects(
            near: CGPoint(x: worldCenter.x, y: worldCenter.y),
            sizes: preparedImages.map(\.size),
            spacing: insertionSpacing
        )

        var snapshots: [PlacedElementSnapshot] = []
        var elements: [CMCanvasElement] = []

        for (index, preparedImage) in preparedImages.enumerated() {
            let url = preparedImage.url
            let rect = rects[index]
            let id = UUID()
            let z = nextZIndex

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
            if let item = PlacedCanvasItem(element: element) {
                placedItems.append(item)
            }
            nextZIndex += 1
            elements.append(element)

            snapshots.append(PlacedElementSnapshot(element: element))
        }

        if !snapshots.isEmpty {
            commandHistory.push(.insert(snapshots: snapshots))
        }

        Task {
            await canvasStore.upsert(elements: elements)
            await refreshVisibleElements()
        }
    }

    private func insertTextAtCenter(initialText: String) {
        let center = CGPoint(x: canvasSize.width / 2.0, y: canvasSize.height / 2.0)
        let worldCenter = screenToWorld(center)
        let size = CGSize(width: 320, height: 180)
        guard let rect = batchInsertionRects(near: worldCenter, sizes: [size], spacing: 24).first else { return }

        let id = UUID()
        let header = CMElementHeader(
            id: id,
            type: .text,
            transform: CMAffineTransform2D(),
            bounds: CMWorldRect(
                origin: SIMD2<Double>(Double(rect.origin.x), Double(rect.origin.y)),
                size: SIMD2<Double>(Double(rect.width), Double(rect.height))
            ),
            layerId: UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID(),
            zIndex: nextZIndex
        )
        let payload = CMCanvasElementPayload.text(
            content: initialText,
            fontName: "HelveticaNeue",
            fontSize: 28,
            color: "#111111"
        )
        let element = CMCanvasElement(header: header, payload: payload)
        let snapshot = PlacedElementSnapshot(element: element)

        if let item = PlacedCanvasItem(element: element) {
            placedItems.append(item)
        }
        nextZIndex += 1
        commandHistory.push(.insert(snapshots: [snapshot]))
        selection.select(id)
        textEditorState = TextEditorState(id: id, text: initialText)

        Task {
            await canvasStore.upsert(elements: [element])
            await refreshVisibleElements()
        }
    }

    private func updateTextElement(id: UUID, text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        if let index = placedItems.firstIndex(where: { $0.id == id }),
           case .text(let payload) = placedItems[index].content {
            let updatedElement = CMCanvasElement(
                header: placedItems[index].element.header,
                payload: .text(content: text, fontName: payload.fontName, fontSize: payload.fontSize, color: payload.color)
            )
            if let updatedItem = PlacedCanvasItem(element: updatedElement) {
                placedItems[index] = updatedItem
            }
        }
        if let index = visibleItems.firstIndex(where: { $0.id == id }),
           case .text(let payload) = visibleItems[index].content {
            let updatedElement = CMCanvasElement(
                header: visibleItems[index].element.header,
                payload: .text(content: text, fontName: payload.fontName, fontSize: payload.fontSize, color: payload.color)
            )
            if let updatedItem = PlacedCanvasItem(element: updatedElement) {
                visibleItems[index] = updatedItem
            }
        }

        enqueueStoreMutation { store in
            let fetched = await store.elements(for: [id])
            guard var element = fetched[id] else { return }
            guard case .text(_, let fontName, let fontSize, let color) = element.payload else { return }
            element.payload = .text(content: text, fontName: fontName, fontSize: fontSize, color: color)
            await store.upsert(elements: [element])
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

    private func batchInsertionRects(near center: CGPoint, sizes: [CGSize], spacing: CGFloat) -> [CGRect] {
        guard !sizes.isEmpty else { return [] }

        let columnCount = max(1, Int(ceil(sqrt(Double(sizes.count)))))
        let rowCount = Int(ceil(Double(sizes.count) / Double(columnCount)))
        let cellWidth = sizes.map(\.width).max() ?? maxImageDimensionWorld
        let cellHeight = sizes.map(\.height).max() ?? maxImageDimensionWorld
        let stepX = cellWidth + spacing
        let stepY = cellHeight + spacing

        let gridWidth = CGFloat(columnCount - 1) * stepX + cellWidth
        let gridHeight = CGFloat(rowCount - 1) * stepY + cellHeight
        let baseOrigin = CGPoint(x: center.x - gridWidth / 2.0, y: center.y - gridHeight / 2.0)

        let templateRects: [CGRect] = sizes.enumerated().map { index, size in
            let row = index / columnCount
            let column = index % columnCount
            let cellOrigin = CGPoint(
                x: baseOrigin.x + CGFloat(column) * stepX,
                y: baseOrigin.y + CGFloat(row) * stepY
            )
            let centeredOrigin = CGPoint(
                x: cellOrigin.x + (cellWidth - size.width) / 2.0,
                y: cellOrigin.y + (cellHeight - size.height) / 2.0
            )
            return CGRect(origin: centeredOrigin, size: size)
        }

        for offset in candidateBatchOffsets(stepX: stepX, stepY: stepY, maxRadius: 24) {
            let candidateRects = templateRects.map { $0.offsetBy(dx: offset.width, dy: offset.height) }
            if !intersectsPlacedItems(candidateRects) {
                return candidateRects
            }
        }

        // Fall back to a finer-grained local search before moving the whole batch
        // outside the currently occupied canvas region.
        let fineStepX = max(24, spacing)
        let fineStepY = max(24, spacing)
        for offset in candidateBatchOffsets(stepX: fineStepX, stepY: fineStepY, maxRadius: 64) {
            let candidateRects = templateRects.map { $0.offsetBy(dx: offset.width, dy: offset.height) }
            if !intersectsPlacedItems(candidateRects) {
                return candidateRects
            }
        }

        return guaranteedNonOverlappingRects(
            from: templateRects,
            spacing: spacing
        )
    }

    private func candidateBatchOffsets(stepX: CGFloat, stepY: CGFloat, maxRadius: Int) -> [CGSize] {
        var offsets: [CGSize] = [.zero]
        guard maxRadius > 0 else { return offsets }

        for radius in 1...maxRadius {
            for y in (-radius)...radius {
                for x in (-radius)...radius {
                    if max(abs(x), abs(y)) != radius {
                        continue
                    }
                    offsets.append(CGSize(width: CGFloat(x) * stepX, height: CGFloat(y) * stepY))
                }
            }
        }

        return offsets
    }

    private func intersectsPlacedItems(_ rects: [CGRect]) -> Bool {
        guard let batchBounds = union(of: rects) else { return false }
        let nearbyRects = placedItems
            .map(\.worldRect)
            .filter { $0.intersects(batchBounds) }

        guard !nearbyRects.isEmpty else { return false }
        return rects.contains { rect in
            nearbyRects.contains { $0.intersects(rect) }
        }
    }

    private func guaranteedNonOverlappingRects(from templateRects: [CGRect], spacing: CGFloat) -> [CGRect] {
        guard !templateRects.isEmpty else { return [] }
        guard let templateBounds = union(of: templateRects) else { return templateRects }
        guard let occupiedBounds = union(of: placedItems.map(\.worldRect)) else { return templateRects }

        let padding = max(spacing, 24)
        let leftOffset = CGSize(
            width: (occupiedBounds.minX - padding) - templateBounds.maxX,
            height: occupiedBounds.midY - templateBounds.midY
        )
        let rightOffset = CGSize(
            width: (occupiedBounds.maxX + padding) - templateBounds.minX,
            height: occupiedBounds.midY - templateBounds.midY
        )
        let topOffset = CGSize(
            width: occupiedBounds.midX - templateBounds.midX,
            height: (occupiedBounds.minY - padding) - templateBounds.maxY
        )
        let bottomOffset = CGSize(
            width: occupiedBounds.midX - templateBounds.midX,
            height: (occupiedBounds.maxY + padding) - templateBounds.minY
        )

        let escapeOffsets = [rightOffset, bottomOffset, leftOffset, topOffset]
        for offset in escapeOffsets {
            let candidateRects = templateRects.map { $0.offsetBy(dx: offset.width, dy: offset.height) }
            if !intersectsPlacedItems(candidateRects) {
                return candidateRects
            }
        }

        return templateRects.map { $0.offsetBy(dx: rightOffset.width, dy: rightOffset.height) }
    }

    private func union(of rects: [CGRect]) -> CGRect? {
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { partial, rect in
            partial.union(rect)
        }
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

    private func canvasItemView(for item: PlacedCanvasItem, liveRect: CGRect) -> some View {
        Group {
            switch item.content {
            case .image(let url):
                let maxDimensionPoints = max(liveRect.width * scale, liveRect.height * scale)
                let requestedPixelSize = FileImageView.bucketedMaxPixelSize(maxDimensionPoints * displayScale)
                let targetMaxPixelSize = isInteracting ? min(requestedPixelSize, 768) : requestedPixelSize
                FileImageView(url: url, targetMaxPixelSize: targetMaxPixelSize, isInteracting: isInteracting)
            case .text(let textPayload):
                TextCanvasItemView(textPayload: textPayload, rect: liveRect)
            }
        }
    }

    private func canvasItemPlacementView(
        item: PlacedCanvasItem,
        liveRect: CGRect,
        isSelected: Bool,
        multiSelected: Bool,
        liveDX: CGFloat,
        liveDY: CGFloat
    ) -> some View {
        let liveWidth = liveRect.width * scale
        let liveHeight = liveRect.height * scale

        return canvasItemView(for: item, liveRect: liveRect)
            .frame(width: liveWidth, height: liveHeight)
            .overlay(selectionOverlay(isSelected: isSelected, multiSelected: multiSelected))
            .onTapGesture {
                handleItemTap(itemID: item.id)
            }
            .position(
                x: (liveRect.midX * scale) + offset.width + liveDX,
                y: (liveRect.midY * scale) + offset.height + liveDY
            )
            .shadow(radius: isInteracting ? 0 : 1)
            .zIndex(Double(item.zIndex))
    }

    @ViewBuilder
    private func selectionOverlay(isSelected: Bool, multiSelected: Bool) -> some View {
        if isSelected && !multiSelected {
            SelectionOverlay()
        } else if isSelected && multiSelected {
            Rectangle()
                .strokeBorder(DesignSystem.Colors.tertiary.opacity(0.5), lineWidth: 1)
        }
    }

    private func selectedTextItemForEditing() -> PlacedCanvasItem? {
        guard selection.selectedIDs.count == 1, let selectedID = selection.selectedIDs.first else { return nil }
        return placedItems.first(where: { $0.id == selectedID && $0.isText })
    }

    private func beginEditingSelectedText() {
        guard let item = selectedTextItemForEditing(),
              case .text(let payload) = item.content else { return }
        textEditorState = TextEditorState(id: item.id, text: payload.content)
    }

    private func textScaleFactor(from oldBounds: CMWorldRect, to newBounds: CMWorldRect) -> Double {
        let widthScale = newBounds.size.x / max(oldBounds.size.x, 1)
        let heightScale = newBounds.size.y / max(oldBounds.size.y, 1)
        return min(widthScale, heightScale)
    }

    // MARK: - Models

    private struct TextEditorState: Identifiable {
        let id: UUID
        let text: String
    }

    private struct PlacedCanvasItem: Identifiable {
        let id: UUID
        let element: CMCanvasElement
        var worldRect: CGRect
        var zIndex: Int

        let content: Content

        var isText: Bool {
            if case .text = content { return true }
            return false
        }

        init?(element: CMCanvasElement) {
            let bounds = element.header.bounds
            let rect = CGRect(
                x: CGFloat(bounds.origin.x),
                y: CGFloat(bounds.origin.y),
                width: CGFloat(bounds.size.x),
                height: CGFloat(bounds.size.y)
            )

            let content: Content
            switch element.payload {
            case .image(let url, _):
                content = .image(url)
            case .text(let contentText, let fontName, let fontSize, let color):
                content = .text(TextPayload(content: contentText, fontName: fontName, fontSize: fontSize, color: color))
            default:
                return nil
            }

            self.id = element.id
            self.element = element
            self.worldRect = rect
            self.zIndex = element.header.zIndex
            self.content = content
        }

        enum Content {
            case image(URL)
            case text(TextPayload)
        }
    }

    private struct TextPayload {
        let content: String
        let fontName: String
        let fontSize: Double
        let color: String
    }

    private struct TextCanvasItemView: View {
        let textPayload: TextPayload
        let rect: CGRect

        var body: some View {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.white.opacity(0.94))
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)

                Text(textPayload.content)
                    .font(.custom(textPayload.fontName, size: max(14, textPayload.fontSize)))
                    .foregroundStyle(Color(hex: textPayload.color) ?? Color.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .multilineTextAlignment(.leading)
                    .padding(20)
            }
            .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
            .clipped()
        }
    }

    private struct TextBoxEditorSheet: View {
        let initialText: String
        let onCancel: () -> Void
        let onSave: (String) -> Void

        @State private var draftText: String

        init(initialText: String, onCancel: @escaping () -> Void, onSave: @escaping (String) -> Void) {
            self.initialText = initialText
            self.onCancel = onCancel
            self.onSave = onSave
            self._draftText = State(initialValue: initialText)
        }

        var body: some View {
            NavigationStack {
                TextEditor(text: $draftText)
                    .padding()
                    .navigationTitle("Edit Text")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel", action: onCancel)
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                onSave(draftText)
                            }
                        }
                    }
            }
        }
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

private extension Color {
    init?(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else { return nil }
        let red = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let blue = Double(value & 0xFF) / 255.0
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1)
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
    BoardCanvasView(commandHistory: CanvasCommandHistory())
}
