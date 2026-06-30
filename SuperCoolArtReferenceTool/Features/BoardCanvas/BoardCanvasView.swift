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

    // Placed texts. No viewport culling — text count is expected to be small
    // and each element's world footprint depends on screen-space rendering, so
    // tile-based culling adds complexity for little benefit at v1 scale.
    @State private var placedTexts: [PlacedText] = []
    /// Id of the text element currently in edit mode (nil when none).
    @State private var editingTextID: UUID? = nil
    /// Newly placed text ids that have not yet been committed to history/store.
    /// Cleared on first commitTextEdit so subsequent focus-loss callbacks
    /// for the same id can't push duplicate `.insert` commands.
    @State private var pendingTextInserts: Set<UUID> = []
    /// One-shot guard: when `insertText` auto-swaps the active tool back to
    /// `.pointer` (Figma convention — keep editing the just-placed text but
    /// route subsequent canvas taps through pointer), the resulting
    /// `onChange(of: activeTool)` would otherwise commit the brand-new draft.
    /// Set right before the programmatic write, consumed on the next firing.
    @State private var skipNextToolChangeCommit: Bool = false
    /// Snapshot of the text content captured at the moment a re-edit begins.
    /// Used to push an `.editTextContent` command on commit if the content
    /// actually changed. Nil for newly-placed texts (those use the
    /// `.insert` command path instead) and when no re-edit is active.
    @State private var editingTextOriginalContent: String? = nil

    @State private var nextZIndex: Int = 0
    @State private var canvasSize: CGSize = .zero

    // Backend store for tile-based culling
    @State private var canvasStore: LocalBoardStore
    @State private var refreshTask: Task<Void, Never>? = nil
    @State private var storeMutationTask: Task<Void, Never>? = nil
    @State private var insertionTask: Task<Void, Never>? = nil
    @State private var stickyDetailImageIDs: Set<UUID> = []

    // Drop/import types (images and GIFs only)
    private let allowedDropTypes: [UTType] = [.image, .gif]

    // Image sizing constraints in world units (adjust as desired)
    private let maxImageDimensionWorld: CGFloat = 512
    private let minImageDimensionWorld: CGFloat = 64
    private let insertionChunkSize = 48
    private let denseVisibleImageThreshold = 150
    private let maxDetailedImagesWhileInteracting = 120
    private let maxDetailedImagesAtRest = 180
    private let overviewPromotionMaxDimension: CGFloat = 28
    private let overviewPromotionMinArea: CGFloat = 36
    private let countAwareLODThreshold = 200
    private let minVisibleQueryMargin: Double = 64
    private let maxVisibleQueryMargin: Double = 512
    private let lodHysteresisScoreMargin: CGFloat = 0.12

    // Text element defaults. Font size is in BASE/world units. The text
    // is rendered at base size and then visually resized by `.scaleEffect(scale)`,
    // so the on-screen size is `defaultTextFontSize * scale` — it grows
    // and shrinks with canvas zoom (Figma/Miro convention). The base
    // unit choice is deliberate: layout (especially wrap-locked text)
    // happens once and stays invariant under zoom.
    // Color hex is round-tripped through CMCanvasElementPayload.text but in v1
    // the read path always falls back to DesignSystem.Colors.primary.
    private let defaultTextFontSize: CGFloat = 24
    private let defaultTextFontName: String = "system"
    private let defaultTextColorHex: String = "#191919"

    // Zoom bounds
    private let minScale: CGFloat = 0.05
    private let maxScale: CGFloat = 8.0

    // Active tool from toolbar
    @Binding private var activeTool: CanvasTool
    // Home-button trigger: fires jumpToContentCenter when set to a non-nil UUID
    @Binding private var homeTrigger: UUID?
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

    @Binding private var snapshotTrigger: UUID?
    /// Snapshot callback. `wasDirty` is a non-consuming peek at the store's dirty flag. Save
    /// paths must flip `markCleanTrigger` after a confirmed-successful write; the dirty flag
    /// survives a cancelled exporter this way.
    private let onSnapshot: (([CMCanvasElement], Bool) -> Void)?
    @Binding private var elementsToLoad: [CMCanvasElement]?
    @Binding private var markCleanTrigger: UUID?

    @MainActor
    init(activeTool: Binding<CanvasTool> = .constant(.pointer), externalInsertURLs: Binding<[URL]?> = .constant(nil), showGrid: Binding<Bool> = .constant(true), canvasColor: Binding<Color> = .constant(.white), snapshotTrigger: Binding<UUID?> = .constant(nil), loadElements: Binding<[CMCanvasElement]?> = .constant(nil), commandHistory: CanvasCommandHistory, undoTrigger: Binding<UUID?> = .constant(nil), redoTrigger: Binding<UUID?> = .constant(nil), homeTrigger: Binding<UUID?> = .constant(nil), markCleanTrigger: Binding<UUID?> = .constant(nil), onInsertURLs: @escaping ImportHandler = { _ in }, onSnapshot: (([CMCanvasElement], Bool) -> Void)? = nil) {
        let store = LocalBoardStore()
        self._canvasStore = State(initialValue: store)
        self._activeTool = activeTool
        self._externalInsertURLs = externalInsertURLs
        self._showGrid = showGrid
        self._canvasColor = canvasColor
        self.commandHistory = commandHistory
        self._undoTrigger = undoTrigger
        self._redoTrigger = redoTrigger
        self._homeTrigger = homeTrigger
        self._markCleanTrigger = markCleanTrigger
        self.onInsertURLs = onInsertURLs
        self._snapshotTrigger = snapshotTrigger
        self._elementsToLoad = loadElements
        self.onSnapshot = onSnapshot
    }

    var body: some View {
        GeometryReader { geo in
            let renderPlan = imageRenderPlan()
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
                .accessibilityHidden(true)
                .onTapGesture(coordinateSpace: .local) { location in
                    // Empty-canvas tap: SwiftUI's hit-testing routes taps to
                    // image views / floating overlays first, so this only fires
                    // when the user actually tapped bare canvas.
                    // Commit any in-flight text edit before doing anything
                    // else — the empty tap doesn't mutate selection (which
                    // would otherwise be the trigger), so without this an
                    // editing TextField would keep capturing keystrokes.
                    if let editing = editingTextID {
                        commitTextEdit(id: editing)
                    }
                    if activeTool == .text {
                        let world = screenToWorld(location)
                        insertText(at: world)
                        return
                    }
                    toolBehavior(for: activeTool).tappedEmpty(selection: selection)
                }

                if !renderPlan.overviewItems.isEmpty {
                    Canvas { ctx, _ in
                        for item in renderPlan.overviewItems {
                            let screenRect = CGRect(
                                x: item.worldRect.origin.x * scale + offset.width,
                                y: item.worldRect.origin.y * scale + offset.height,
                                width: item.worldRect.width * scale,
                                height: item.worldRect.height * scale
                            )
                            let fillRect = screenRect.integral.insetBy(dx: 0.25, dy: 0.25)
                            let fillPath = Path(roundedRect: fillRect, cornerRadius: min(3, min(fillRect.width, fillRect.height) * 0.2))
                            ctx.fill(fillPath, with: .color(DesignSystem.Colors.secondary.opacity(0.18)))
                            if fillRect.width >= 6, fillRect.height >= 6 {
                                ctx.stroke(fillPath, with: .color(DesignSystem.Colors.secondary.opacity(0.32)), lineWidth: 0.75)
                            }
                        }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }

                // Render detailed visible images only (world -> screen mapping)
                ForEach(renderPlan.detailItems) { item in
                    let isSelected = selection.selectedIDs.contains(item.id)
                    let isBeingResized = selection.isResizing && selection.resizeElementID == item.id
                    let isBeingGroupResized = selection.isGroupResizing && isSelected

                    let liveRect: CGRect = {
                        if isBeingGroupResized,
                           let startRects = selection.groupResizeStartRects,
                           let originalRect = startRects[item.id],
                           let bboxStart = selection.groupResizeBBoxStart,
                           let bboxCurrent = selection.groupResizeBBoxCurrent {
                            return scaledRect(original: originalRect, bboxStart: bboxStart, bboxCurrent: bboxCurrent)
                        } else if isBeingResized {
                            return selection.resizeCurrentRect ?? item.worldRect
                        } else {
                            return item.worldRect
                        }
                    }()

                    let liveDX = (isSelected && selection.isDragging) ? selection.dragOffset.width * scale : 0
                    let liveDY = (isSelected && selection.isDragging) ? selection.dragOffset.height * scale : 0

                    let multiSelected = selection.selectedIDs.count > 1

                    let maxDimensionPoints = max(liveRect.width * scale, liveRect.height * scale)
                    let targetMaxPixelSize = FileImageView.requestedThumbnailPixelSize(
                        screenMaxDimensionPoints: maxDimensionPoints,
                        displayScale: displayScale,
                        isInteracting: isInteracting
                    )
                    FileImageView(url: item.url, targetMaxPixelSize: targetMaxPixelSize, isInteracting: isInteracting)
                        .frame(width: liveRect.width * scale,
                               height: liveRect.height * scale)
                        .overlay {
                            if isSelected && !multiSelected {
                                SelectionOverlay(activeHandle: selection.resizeHandle)
                            } else if isSelected && multiSelected {
                                // Light border only for individual items in a multi-select
                                Rectangle()
                                    .strokeBorder(DesignSystem.Colors.tertiary.opacity(0.5), lineWidth: 1)
                            }
                        }
                        .onTapGesture {
                            let behavior = toolBehavior(for: activeTool)
                            let store = canvasStore
                            let sel = selection
                            let id = item.id
                            Task {
                                await behavior.tappedItem(id: id, store: store, selection: sel)
                                await refreshVisibleElements()
                            }
                        }
                        .position(x: (liveRect.midX * scale) + offset.width + liveDX,
                                  y: (liveRect.midY * scale) + offset.height + liveDY)
                        .shadow(radius: isInteracting ? 0 : 1)
                        .zIndex(Double(item.zIndex))
                }

                // Render placed text elements. Position is computed in screen
                // space (worldRect.midX × scale + offset). Font size and
                // wrap width are in BASE/world units; `TextElementView`
                // applies `.scaleEffect(scale)` so the visible size grows
                // and shrinks with canvas zoom. The element's world rect
                // size is updated by `.onGeometryChange` inside the text
                // view, so hit-testing / selection still operate in world
                // space against the latest measured layout.
                ForEach($placedTexts) { $placed in
                    let isSelected = selection.selectedIDs.contains(placed.id)
                    let isMultiSelected = selection.selectedIDs.count > 1
                    let liveDX = (isSelected && selection.isDragging) ? selection.dragOffset.width * scale : 0
                    let liveDY = (isSelected && selection.isDragging) ? selection.dragOffset.height * scale : 0
                    let id = placed.id
                    let isEditing = editingTextID == id

                    TextElementView(
                        placed: $placed,
                        scale: scale,
                        isEditing: isEditing,
                        isSelected: isSelected,
                        isMultiSelected: isMultiSelected,
                        onCommitEdit: { commitTextEdit(id: id) }
                    )
                    .position(
                        x: (placed.worldRect.midX * scale) + offset.width + liveDX,
                        y: (placed.worldRect.midY * scale) + offset.height + liveDY
                    )
                    .onTapGesture {
                        // Tap-on-sole-selected text → re-enter edit mode.
                        // Standard across pointer/group/text tools since all
                        // three can produce a single-text selection. Clearing
                        // selection first hides the action bar / chrome so
                        // they don't sit on top of the focused TextField.
                        if selection.selectedIDs.count == 1
                            && selection.selectedIDs.contains(id) {
                            selection.clearSelection()
                            // Snapshot the current content so we can detect a
                            // real change at commit-time and push undo.
                            editingTextOriginalContent = placed.content
                            editingTextID = id
                            return
                        }
                        let behavior = toolBehavior(for: activeTool)
                        let store = canvasStore
                        let sel = selection
                        Task {
                            await behavior.tappedItem(id: id, store: store, selection: sel)
                        }
                    }
                    .zIndex(Double(placed.zIndex))
                }

                // Marquee selection rectangle
                if selection.isMarqueeing, let worldRect = selection.marqueeWorldRect {
                    let screenRect = CGRect(
                        x: worldRect.origin.x * scale + offset.width,
                        y: worldRect.origin.y * scale + offset.height,
                        width: worldRect.width * scale,
                        height: worldRect.height * scale
                    )
                    MarqueeOverlayView(screenRect: screenRect)
                        .allowsHitTesting(false)
                        .zIndex(Double(Int.max - 1))
                }

                // Solo-text selection chrome — rendered externally at
                // screen coordinates so the resize handles stay at a
                // constant 10pt size regardless of canvas zoom (the text
                // body itself uses .scaleEffect for visual zoom, so any
                // overlay drawn inside that scaled view shrinks with
                // text — bad for touch targets on iPad). Symmetric with
                // how image group selection already renders chrome
                // outside the per-image view.
                if selection.selectedIDs.count == 1,
                   let selectedID = selection.selectedIDs.first,
                   let placed = placedTexts.first(where: { $0.id == selectedID }),
                   editingTextID != selectedID,
                   !selection.isDragging,
                   !selection.isMarqueeing {
                    let screenRect = CGRect(
                        x: placed.worldRect.origin.x * scale + offset.width,
                        y: placed.worldRect.origin.y * scale + offset.height,
                        width: placed.worldRect.width * scale,
                        height: placed.worldRect.height * scale
                    )
                    SelectionOverlay(
                        handles: TextElementView.textHandles,
                        activeHandle: selection.resizeHandle
                    )
                    .frame(width: screenRect.width, height: screenRect.height)
                    .position(x: screenRect.midX, y: screenRect.midY)
                    .allowsHitTesting(false)
                    .zIndex(Double(Int.max - 2))
                }

                // Editing border for the active text — rendered externally
                // for the same reason as the selection chrome above. The
                // 1.5pt stroke would otherwise scale with the text via
                // scaleEffect and become invisible at low zoom levels
                // when the text has been size-resized up.
                if let editingID = editingTextID,
                   let placed = placedTexts.first(where: { $0.id == editingID }) {
                    let screenRect = CGRect(
                        x: placed.worldRect.origin.x * scale + offset.width,
                        y: placed.worldRect.origin.y * scale + offset.height,
                        width: placed.worldRect.width * scale,
                        height: placed.worldRect.height * scale
                    )
                    Rectangle()
                        .strokeBorder(DesignSystem.Colors.tertiary, lineWidth: 1.5)
                        .frame(width: screenRect.width, height: screenRect.height)
                        .position(x: screenRect.midX, y: screenRect.midY)
                        .allowsHitTesting(false)
                        .zIndex(Double(Int.max - 2))
                }

                // Floating action bar beneath the current selection.
                SelectionActionBarLayer(
                    boundingBox: selectionBoundingBox(),
                    scale: scale,
                    offset: offset,
                    isInteracting: selection.isDragging
                        || selection.isResizing
                        || selection.isGroupResizing
                        || selection.isMarqueeing,
                    onDelete: deleteSelection
                )
                .zIndex(Double(Int.max))

                // Group bounding box with resize handles
                if selection.selectedIDs.count > 1, !selection.isDragging {
                    let bbox: CGRect? = selection.isGroupResizing
                        ? (selection.groupResizeBBoxCurrent ?? groupBoundingBox())
                        : groupBoundingBox()
                    if let bbox {
                        let screenRect = CGRect(
                            x: bbox.origin.x * scale + offset.width,
                            y: bbox.origin.y * scale + offset.height,
                            width: bbox.width * scale,
                            height: bbox.height * scale
                        )
                        GroupSelectionOverlay(activeHandle: selection.resizeHandle)
                            .frame(width: screenRect.width, height: screenRect.height)
                            .position(x: screenRect.midX, y: screenRect.midY)
                            .allowsHitTesting(false)
                            .zIndex(Double(Int.max))
                    }
                }
            }
            .overlay {
                if placedImages.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 80))
                            .foregroundStyle(DesignSystem.Colors.secondary)
                            .compositingGroup()
                            .blendMode(.difference)
                            .accessibilityHidden(true)

                        Text("Drag and drop an image here")
                            .font(.title3)
                            .foregroundStyle(DesignSystem.Colors.secondary)
                            .compositingGroup()
                            .blendMode(.difference)
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                let rects = allElementRects()
                if !rects.isEmpty {
                    CanvasMinimapView(
                        elementRects: rects,
                        viewportRect: viewportCGRect()
                    )
                    .padding(16)
                }
            }
            .onDrop(of: allowedDropTypes, delegate: CanvasDropDelegate(allowedTypes: allowedDropTypes) { point, urls in
                insertImages(atScreenPoint: point, urls: urls)
            })
            .background {
                canvasColor.ignoresSafeArea()
            }
            .onAppear {
                canvasSize = geo.size
                // Center the canvas on world origin (0, 0) on first appearance
                if offset == .zero {
                    offset = CGSize(width: geo.size.width / 2, height: geo.size.height / 2)
                }
                scheduleRefreshVisibleElements()
            }
            .onDisappear {
                refreshTask?.cancel()
                interactionEndTask?.cancel()
                insertionTask?.cancel()
            }
            .onChange(of: geo.size) { oldValue, newValue in
                canvasSize = newValue
                scheduleRefreshVisibleElements()
            }
            .onChange(of: externalInsertURLs) { oldValue, newValue in
                if let urls = newValue, !urls.isEmpty {
                    let isFirstInsert = placedImages.isEmpty
                    insertImagesAtCenter(urls)
                    if isFirstInsert {
                        commandHistory.clear()
                    }
                    DispatchQueue.main.async {
                        externalInsertURLs = nil
                    }
                }
            }
            .onChange(of: snapshotTrigger) { oldValue, newValue in
                // Emit snapshot + a peek at the dirty flag. Non-consuming: callers must flip
                // `markCleanTrigger` after a confirmed save, not here, so a cancelled exporter
                // leaves the dirty flag intact.
                guard newValue != nil else { return }
                // Commit any in-flight text edit BEFORE the snapshot so a
                // back-button press during edit doesn't drop the user's
                // unsaved text (the editing TextField only commits on
                // focus loss / selection change, neither of which the
                // back button triggers automatically).
                if let editing = editingTextID {
                    commitTextEdit(id: editing)
                }
                let pendingMutation = storeMutationTask
                Task {
                    // Wait for any in-flight store mutation (especially
                    // the upsert just fired by commitTextEdit above) to
                    // land before reading the store. Without this, the
                    // snapshot races and saves a manifest missing the
                    // text the user just typed.
                    if let pendingMutation {
                        _ = await pendingMutation.result
                    }
                    let elements = await canvasStore.allElements()
                    let wasDirty = await canvasStore.peekDirty()
                    onSnapshot?(elements, wasDirty)
                }
            }
            .onChange(of: markCleanTrigger) { _, newValue in
                guard newValue != nil else { return }
                Task { await canvasStore.markClean() }
                DispatchQueue.main.async { markCleanTrigger = nil }
            }
            .onChange(of: elementsToLoad) { oldValue, newValue in
                if let els = newValue {
                    applyElements(els)
                    commandHistory.clear()
                    selection.clearSelection()
                    // Clear the binding after applying
                    DispatchQueue.main.async {
                        elementsToLoad = nil
                    }
                }
            }
            .onChange(of: activeTool) { _, _ in
                // Switching tools commits any in-flight text edit so the user
                // doesn't end up with an invisible empty placeholder after
                // tapping another toolbar button mid-type.
                //
                // Skip the auto-swap fired by `insertText` itself, which
                // flips activeTool to `.pointer` while keeping focus on the
                // just-placed draft.
                if skipNextToolChangeCommit {
                    skipNextToolChangeCommit = false
                    return
                }
                if let editing = editingTextID {
                    commitTextEdit(id: editing)
                }
            }
            .onChange(of: selection.selectedIDs) { _, newIDs in
                // Tapping or marquee-selecting any other element while a text
                // is being edited should commit the edit — TextField's
                // `@FocusState` only fires on focus changes between focusable
                // views, but image / text taps don't acquire focus, so we
                // commit explicitly when selection changes to something other
                // than the editing text itself.
                //
                // Skip when newIDs is empty: that's a deselection (e.g.
                // `insertText` calling `clearSelection()` right after setting
                // `editingTextID` to a new draft). Without this guard the
                // brand-new text would be committed-and-removed in the same
                // frame it was placed, which tore down the focused TextField
                // mid-creation and crashed on real device.
                guard let editing = editingTextID,
                      !newIDs.isEmpty,
                      !newIDs.contains(editing) else { return }
                commitTextEdit(id: editing)
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
            .onChange(of: homeTrigger) { _, newValue in
                guard newValue != nil else { return }
                jumpToContentCenter()
                DispatchQueue.main.async { homeTrigger = nil }
            }
            .contentShape(Rectangle())
            // Drag: routed through active tool behavior
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        startInteraction()
                        if currentDragMode == nil {
                            // If a text is currently being edited and the
                            // drag started inside that text, swallow the
                            // gesture entirely — match Apple Notes / Pages
                            // / Figma / Miro convention where you cannot
                            // drag-to-move while editing. The user must
                            // tap outside (which commits the edit via the
                            // existing selection-change / empty-canvas-tap
                            // paths) and then drag in selection mode.
                            //
                            // This avoids fighting with UITextView's
                            // built-in text-selection gestures (which
                            // would otherwise produce a "first frame /
                            // last frame teleport" because UIKit's
                            // recognizers eat the live touches), and
                            // preserves drag-to-select-text inside the
                            // editing field as the natural fallback.
                            //
                            // We mark mode as `.none` so subsequent
                            // onChanged events in the same drag also
                            // no-op, and onEnded skips its commit
                            // dispatcher.
                            if let editingID = editingTextID,
                               let placed = placedTexts.first(where: { $0.id == editingID }),
                               placed.worldRect.contains(screenToWorld(value.startLocation)) {
                                currentDragMode = DragMode.none
                                return
                            }
                            dragStartOffset = offset

                            if let hitResult = hitTestHandle(screenPoint: value.startLocation) {
                                switch hitResult {
                                case .singleItem(let handle, let item):
                                    selection.resizeHandle = handle
                                    selection.resizeStartRect = item.worldRect
                                    selection.resizeElementID = item.id
                                case .singleTextItem(let handle, let text):
                                    selection.resizeHandle = handle
                                    selection.textResizeStartFontSize = text.fontSize
                                    selection.textResizeStartWrapWidth = text.wrapWidth
                                    selection.textResizeStartWorldRect = text.worldRect
                                    selection.textResizeElementID = text.id
                                case .group(let handle, let bbox):
                                    var startRects: [UUID: CGRect] = [:]
                                    for img in placedImages where selection.selectedIDs.contains(img.id) {
                                        startRects[img.id] = img.worldRect
                                    }
                                    var startTextStates: [UUID: TextResizeSnapshot] = [:]
                                    for txt in placedTexts where selection.selectedIDs.contains(txt.id) {
                                        startTextStates[txt.id] = TextResizeSnapshot(
                                            fontSize: txt.fontSize,
                                            wrapWidth: txt.wrapWidth,
                                            origin: txt.worldRect.origin
                                        )
                                    }
                                    selection.groupResizeStartRects = startRects
                                    selection.groupResizeTextStartStates = startTextStates.isEmpty ? nil : startTextStates
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
                            var items = visibleImages.map {
                                HitTestItem(id: $0.id, worldRect: $0.worldRect, zIndex: $0.zIndex)
                            }
                            items.append(contentsOf: placedTexts.map {
                                HitTestItem(id: $0.id, worldRect: $0.worldRect, zIndex: $0.zIndex)
                            })
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
                            if selection.isTextResizing {
                                commitTextResize()
                            } else if selection.isGroupResizing {
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
            .background(TwoFingerPanView(onPan: handleTwoFingerPan))
            .background(PinchGestureView(onPinch: handlePinch))
        }
    }

    // MARK: - Helpers

    private func clamp(_ value: CGFloat, _ minVal: CGFloat, _ maxVal: CGFloat) -> CGFloat {
        min(max(value, minVal), maxVal)
    }

    /// Pure function: compute the new `offset` that keeps the world point under
    /// `anchor` (in screen-space points) fixed while scale changes from `oldScale`
    /// to `newScale`. Extracted from `handlePinch` so the pivot-preserving math is
    /// callable without a live view (e.g. from future unit tests).
    ///
    /// Preserves `worldPoint = (anchor - offset) / scale` across the zoom step.
    static func zoomAnchoredOffset(
        anchor: CGPoint,
        oldOffset: CGSize,
        oldScale: CGFloat,
        newScale: CGFloat
    ) -> CGSize {
        let worldXBefore = (anchor.x - oldOffset.width) / oldScale
        let worldYBefore = (anchor.y - oldOffset.height) / oldScale
        return CGSize(
            width: anchor.x - worldXBefore * newScale,
            height: anchor.y - worldYBefore * newScale
        )
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

    private func handlePinch(phase: PinchGestureView.Phase, scaleDelta: CGFloat, anchor: CGPoint) {
        switch phase {
        case .began:
            startInteraction()
        case .changed:
            let newScale = clamp(scale * scaleDelta, minScale, maxScale)
            // Clamp can cancel the delta; skip to avoid unnecessary offset churn.
            guard newScale != scale else { return }
            // Pivot-preserving zoom: keep the world point currently under `anchor`
            // pinned to the same screen position after the scale change. Reading
            // `offset`/`scale` fresh every tick is what lets this compose with the
            // simultaneous two-finger pan (no frozen baselines to clobber).
            offset = Self.zoomAnchoredOffset(
                anchor: anchor,
                oldOffset: offset,
                oldScale: scale,
                newScale: newScale
            )
            scale = newScale
            scheduleRefreshVisibleElements()
        case .ended:
            endInteraction()
        }
    }

    private func handleTwoFingerPan(phase: TwoFingerPanView.Phase, delta: CGSize) {
        switch phase {
        case .began:
            startInteraction()
        case .changed:
            offset = CGSize(width: offset.width + delta.width,
                            height: offset.height + delta.height)
            scheduleRefreshVisibleElements()
        case .ended:
            endInteraction()
        }
    }

    // MARK: - Handle Hit-Testing

    /// Screen-space hit radius for grabbing handles
    private let handleHitRadius: CGFloat = 30

    private enum HandleHitResult {
        case singleItem(handle: HandlePosition, item: PlacedImage)
        case singleTextItem(handle: HandlePosition, text: PlacedText)
        case group(handle: HandlePosition, bbox: CGRect)
    }

    /// Pure query: hit-test screen point against handles on the current selection.
    private func hitTestHandle(screenPoint: CGPoint) -> HandleHitResult? {
        let textIDs = Set(placedTexts.map(\.id))
        // Solo text selection — corners scale font (Freeform-style),
        // left/right edges set wrap width. Top/bottom never hit since
        // the visual overlay doesn't render those handles for text, but
        // the gesture drag also rejects them defensively below.
        if selection.selectedIDs.count == 1,
           let selectedID = selection.selectedIDs.first,
           textIDs.contains(selectedID),
           let text = placedTexts.first(where: { $0.id == selectedID }) {
            let textScreenRect = CGRect(
                x: text.worldRect.origin.x * scale + offset.width,
                y: text.worldRect.origin.y * scale + offset.height,
                width: text.worldRect.width * scale,
                height: text.worldRect.height * scale
            )
            if let handle = hitTestHandleOnRect(screenPoint: screenPoint, screenRect: textScreenRect),
               handle != .topCenter && handle != .bottomCenter {
                return .singleTextItem(handle: handle, text: text)
            }
            return nil
        }
        // (Mixed/pure-text multi-selections fall through to the group
        // path below — text scales uniformly with the bbox, same as
        // images. Single-text selections were already handled above.)
        if selection.selectedIDs.count == 1,
           let selectedID = selection.selectedIDs.first,
           let item = visibleImages.first(where: { $0.id == selectedID }) {
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

    private func imageRenderPlan() -> ImageRenderPlan {
        computeImageRenderPlan(previousDetailIDs: stickyDetailImageIDs)
    }

    private func computeImageRenderPlan(previousDetailIDs: Set<UUID>) -> ImageRenderPlan {
        let selectedIDs = selection.selectedIDs
        guard visibleImages.count > denseVisibleImageThreshold else {
            return ImageRenderPlan(detailItems: visibleImages, overviewItems: [])
        }

        let detailBudget = isInteracting ? maxDetailedImagesWhileInteracting : maxDetailedImagesAtRest
        let viewportCenter = CGPoint(x: canvasSize.width * 0.5, y: canvasSize.height * 0.5)
        let viewportDiagonal = max(hypot(canvasSize.width, canvasSize.height), 1)
        let applyCountAwareLOD = visibleImages.count >= countAwareLODThreshold
        var forcedDetailIDs = Set<UUID>()
        var rankedCandidates: [(id: UUID, score: CGFloat)] = []

        for item in visibleImages {
            let screenRect = CGRect(
                x: item.worldRect.origin.x * scale + offset.width,
                y: item.worldRect.origin.y * scale + offset.height,
                width: item.worldRect.width * scale,
                height: item.worldRect.height * scale
            )
            let screenMaxDimension = max(screenRect.width, screenRect.height)
            let screenArea = max(screenRect.width * screenRect.height, 0)
            let distanceFromCenter = hypot(screenRect.midX - viewportCenter.x, screenRect.midY - viewportCenter.y)
            let normalizedDistance = min(distanceFromCenter / viewportDiagonal, 1)
            let centralityScore = 1 - normalizedDistance
            let sizeScore = min(screenArea / 4096, 1)
            let dimensionScore = min(screenMaxDimension / 96, 1)
            let score = (sizeScore * 0.5) + (dimensionScore * 0.2) + (centralityScore * 0.3)

            if selectedIDs.contains(item.id) {
                forcedDetailIDs.insert(item.id)
                continue
            }

            if !applyCountAwareLOD && screenMaxDimension >= overviewPromotionMaxDimension {
                forcedDetailIDs.insert(item.id)
                continue
            }

            if screenArea >= overviewPromotionMinArea || centralityScore > 0.8 {
                rankedCandidates.append((id: item.id, score: score))
            }
        }

        let sortedCandidates = rankedCandidates.sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.score > rhs.score
        }

        let remainingBudget = max(detailBudget - forcedDetailIDs.count, 0)
        let promotionFrontierScore = sortedCandidates.indices.contains(max(remainingBudget - 1, 0))
            ? sortedCandidates[max(remainingBudget - 1, 0)].score
            : 0
        let stickyRetainThreshold = max(promotionFrontierScore - lodHysteresisScoreMargin, 0)

        var stickyRetainedIDs: Set<UUID> = []
        if remainingBudget > 0 {
            let stickyCandidates = sortedCandidates.filter {
                previousDetailIDs.contains($0.id) && $0.score >= stickyRetainThreshold
            }
            stickyRetainedIDs = Set(stickyCandidates.prefix(remainingBudget).map(\.id))
        }

        let fillBudget = max(remainingBudget - stickyRetainedIDs.count, 0)
        let promotedIDs = Set(
            sortedCandidates
                .filter { !stickyRetainedIDs.contains($0.id) }
                .prefix(fillBudget)
                .map(\.id)
        )
        let detailIDs = forcedDetailIDs.union(stickyRetainedIDs).union(promotedIDs)

        let detailItems = visibleImages.filter { detailIDs.contains($0.id) }
        let overviewItems = visibleImages.filter { !detailIDs.contains($0.id) }
        return ImageRenderPlan(detailItems: detailItems, overviewItems: overviewItems)
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
            if selection.isTextResizing {
                applyTextResize(translation: value.translation)
            } else if selection.isGroupResizing {
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
    /// Pure resize-rect math. `minDimension` lets text resize use its
    /// own (smaller) floor — for images the default `minImageDimensionWorld`
    /// (64) prevents ugly tiny photos; for text we want the rect to be
    /// allowed to shrink down to whatever world width corresponds to the
    /// text's own minimum font size.
    private func computeResizedRect(
        handle: HandlePosition,
        startRect: CGRect,
        translation: CGSize,
        minDimension: CGFloat? = nil
    ) -> CGRect? {
        let worldDX = translation.width / scale
        let worldDY = translation.height / scale
        let minDim = minDimension ?? minImageDimensionWorld

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

            rawW = max(rawW, minDim)
            rawH = max(rawH, minDim / max(aspect, 0.001))

            let originX = handle.isLeftSide ? anchorWorld.x - rawW : anchorWorld.x
            let originY = handle.isTopSide ? anchorWorld.y - rawH : anchorWorld.y
            return CGRect(x: originX, y: originY, width: rawW, height: rawH)
        } else {
            var newOrigin = startRect.origin
            var newSize = startRect.size

            switch handle {
            case .topCenter:
                let newTop = min(draggedWorld.y, anchorWorld.y - minDim)
                newSize.height = anchorWorld.y - newTop
                newOrigin.y = newTop
            case .bottomCenter:
                let newBottom = max(draggedWorld.y, anchorWorld.y + minDim)
                newSize.height = newBottom - anchorWorld.y
                newOrigin.y = anchorWorld.y
            case .leftCenter:
                let newLeft = min(draggedWorld.x, anchorWorld.x - minDim)
                newSize.width = anchorWorld.x - newLeft
                newOrigin.x = newLeft
            case .rightCenter:
                let newRight = max(draggedWorld.x, anchorWorld.x + minDim)
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
        var rects = placedImages.filter { selection.selectedIDs.contains($0.id) }.map(\.worldRect)
        rects.append(contentsOf: placedTexts.filter { selection.selectedIDs.contains($0.id) }.map(\.worldRect))
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    private func groupBoundingBox() -> CGRect? {
        guard selection.selectedIDs.count > 1 else { return nil }
        var rects = placedImages.filter { selection.selectedIDs.contains($0.id) }.map(\.worldRect)
        rects.append(contentsOf: placedTexts.filter { selection.selectedIDs.contains($0.id) }.map(\.worldRect))
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

        // Live-mutate text state for immediate visual feedback. Images
        // render via `scaledRect` against bboxCurrent inside the ForEach
        // closure (no underlying mutation needed); text uses a different
        // render path (font size + frame), so it's simpler to mutate the
        // PlacedText fields directly each frame and let onGeometryChange
        // re-derive worldRect.size.
        if let startTextStates = selection.groupResizeTextStartStates {
            // Geometric mean of width and height ratios so text scales
            // for any axis change, not just width. Corner drags are
            // aspect-ratio-locked (widthRatio == heightRatio → factor
            // equals either ratio); top/bottom-edge drags only change
            // height, so a width-only factor would leave text unchanged
            // even though the bbox visibly grew or shrank.
            let widthRatio = bboxStart.width > 0.001 ? newBBox.width / bboxStart.width : 1
            let heightRatio = bboxStart.height > 0.001 ? newBBox.height / bboxStart.height : 1
            let factor = sqrt(max(widthRatio * heightRatio, 0))
            for (id, snapshot) in startTextStates {
                guard let idx = placedTexts.firstIndex(where: { $0.id == id }) else { continue }
                placedTexts[idx].fontSize = max(minTextFontSize, snapshot.fontSize * factor)
                if let startWrap = snapshot.wrapWidth {
                    placedTexts[idx].wrapWidth = max(minTextWrapWidth, startWrap * factor)
                }
                // Origin scales relative to the bbox the same way images
                // do via scaledRect (so positions track the bbox change).
                let originalRect = CGRect(origin: snapshot.origin, size: .zero)
                let newOrigin = scaledRect(
                    original: originalRect, bboxStart: bboxStart, bboxCurrent: newBBox
                ).origin
                placedTexts[idx].worldRect.origin = newOrigin
            }
        }
    }

    private func commitGroupResize() {
        guard let bboxStart = selection.groupResizeBBoxStart,
              let bboxCurrent = selection.groupResizeBBoxCurrent,
              bboxStart != bboxCurrent else {
            selection.clearGroupResize()
            return
        }
        let startRects = selection.groupResizeStartRects ?? [:]
        let startTextStates = selection.groupResizeTextStartStates ?? [:]

        var toRects: [UUID: CGRect] = [:]
        for (id, originalRect) in startRects {
            toRects[id] = scaledRect(original: originalRect, bboxStart: bboxStart, bboxCurrent: bboxCurrent)
        }

        // Build text "to" snapshots from the live-mutated PlacedText —
        // applyGroupResize has already brought them to their final state.
        var toTextStates: [UUID: TextResizeSnapshot] = [:]
        for (id, _) in startTextStates {
            guard let placed = placedTexts.first(where: { $0.id == id }) else { continue }
            toTextStates[id] = TextResizeSnapshot(
                fontSize: placed.fontSize,
                wrapWidth: placed.wrapWidth,
                origin: placed.worldRect.origin
            )
        }

        commandHistory.push(.groupResize(
            fromRects: startRects, toRects: toRects,
            fromTextStates: startTextStates, toTextStates: toTextStates
        ))
        applyGroupResizeApply(rects: toRects, textStates: toTextStates)
        selection.clearGroupResize()
    }

    /// Shared restore for `.groupResize` undo / redo / commit.
    ///
    /// Group resize can affect multiple images and multiple text elements
    /// in one gesture. Each call to `applyResizeRects` / `applyTextResizeState`
    /// fires its own `enqueueStoreMutation`, and `enqueueStoreMutation`
    /// CANCELS any in-flight mutation. So a naive loop would have only
    /// the last enqueued upsert reach the store — every prior one (image
    /// rects + earlier texts) gets cancelled mid-flight. We do the
    /// in-memory mutations synchronously and batch every store write into
    /// one `enqueueStoreMutation`, so cancellation only kills work that
    /// hasn't been fully prepared yet.
    private func applyGroupResizeApply(
        rects: [UUID: CGRect],
        textStates: [UUID: TextResizeSnapshot]
    ) {
        guard !rects.isEmpty || !textStates.isEmpty else { return }

        // ── In-memory mutations (sync) ─────────────────────────────
        // Image rects: filter out any text ids defensively (text can't
        // be in `rects` legally, but applyResizeRects had this guard
        // historically and we preserve it).
        let textIDs = Set(placedTexts.map(\.id))
        let imageRects = rects.filter { !textIDs.contains($0.key) }

        for (id, rect) in imageRects {
            if let idx = placedImages.firstIndex(where: { $0.id == id }) {
                placedImages[idx].worldRect = rect
            }
            if let idx = visibleImages.firstIndex(where: { $0.id == id }) {
                visibleImages[idx].worldRect = rect
            }
        }

        // Text states: mutate in-memory and pre-build the elements we'll
        // upsert. Building the elements before the Task closure means
        // the closure captures concrete values, not bindings into our
        // mutating arrays.
        var textElements: [CMCanvasElement] = []
        for (id, state) in textStates {
            guard let idx = placedTexts.firstIndex(where: { $0.id == id }) else { continue }
            placedTexts[idx].fontSize = state.fontSize
            placedTexts[idx].wrapWidth = state.wrapWidth
            placedTexts[idx].worldRect.origin = state.origin
            textElements.append(fallbackTextElement(for: placedTexts[idx]))
        }

        // ── Single batched store mutation ──────────────────────────
        let imageIDs = Array(imageRects.keys)
        enqueueStoreMutation { store in
            var updated: [CMCanvasElement] = []
            updated.reserveCapacity(imageIDs.count + textElements.count)

            // Images: fetch authoritative elements, mutate bounds + size.
            if !imageIDs.isEmpty {
                let fetched = await store.elements(for: imageIDs)
                for (id, rect) in imageRects {
                    if var element = fetched[id] {
                        element.header.bounds = CMWorldRect(
                            origin: SIMD2<Double>(Double(rect.origin.x), Double(rect.origin.y)),
                            size: SIMD2<Double>(Double(rect.width), Double(rect.height))
                        )
                        if case .image(let url, _) = element.payload {
                            element.payload = .image(
                                url: url,
                                size: SIMD2<Double>(Double(rect.width), Double(rect.height))
                            )
                        }
                        updated.append(element)
                    }
                }
            }

            // Text: elements were pre-built above (already authoritative
            // for content + style + bounds, so no fetch needed).
            updated.append(contentsOf: textElements)

            if !updated.isEmpty {
                await store.upsert(elements: updated)
            }
        }
    }

    // MARK: - Text Resize
    //
    // Text uses fontSize (and optionally wrapWidth + origin) as authoritative
    // state instead of a worldRect like images. Corners scale fontSize
    // uniformly (Freeform-style); left/right edges set wrapWidth (Figma-
    // style fixed-wrap text). Top/bottom edges are filtered out at hit-test
    // time and visually hidden in the selection overlay — height is always
    // content-derived.
    //
    // Direct mutation of `placedTexts[idx]` during drag is fine: the view
    // re-renders, `onGeometryChange` measures the new screen size, and the
    // worldRect downstream-derives via the existing measurement loop.

    /// Min font size floor — below this text becomes illegible on most
    /// canvases at typical zoom levels.
    private let minTextFontSize: CGFloat = 8.0
    /// Min wrap width floor — narrower than this and text wraps every word
    /// to its own line, which feels broken.
    private let minTextWrapWidth: CGFloat = 40.0

    private func applyTextResize(translation: CGSize) {
        guard let handle = selection.resizeHandle,
              let startFontSize = selection.textResizeStartFontSize,
              let startRect = selection.textResizeStartWorldRect,
              let id = selection.textResizeElementID,
              let idx = placedTexts.firstIndex(where: { $0.id == id }) else { return }

        let startWrapWidth = selection.textResizeStartWrapWidth

        if handle.isCorner {
            // Reuse the aspect-locked corner math from image resize to get a
            // proportional new rect; derive scale factor from width ratio.
            // Direct-mutate fontSize (and wrapWidth proportionally if set);
            // worldRect re-derives via onGeometryChange after re-render.
            //
            // Override `minDimension` so the rect floor matches the text's
            // own font-size minimum rather than the image-element minimum
            // (64). Without this the rect clamps before fontSize hits its
            // own floor, producing a visible "snap" when the user tries
            // to shrink small text past ~64 world units.
            let minDimForText = startRect.width * (minTextFontSize / max(startFontSize, 0.001))
            guard let newRect = computeResizedRect(
                handle: handle, startRect: startRect, translation: translation,
                minDimension: minDimForText
            ) else { return }
            let factor = newRect.width / max(startRect.width, 0.001)
            placedTexts[idx].fontSize = max(minTextFontSize, startFontSize * factor)
            if let startWrap = startWrapWidth {
                placedTexts[idx].wrapWidth = max(minTextWrapWidth, startWrap * factor)
            }
            // Origin shifts from corner drag the same way as image resize:
            // the *opposite* corner is the anchor, so origin tracks newRect.
            placedTexts[idx].worldRect.origin = newRect.origin
        } else if handle == .rightCenter {
            // Right edge drag → set wrap width, left edge anchored.
            // Reference width: existing wrapWidth if set, else current
            // measured worldRect.width (auto-width text).
            let baseWidth = startWrapWidth ?? startRect.width
            let worldDX = translation.width / scale
            let newWrap = max(minTextWrapWidth, baseWidth + worldDX)
            placedTexts[idx].wrapWidth = newWrap
            // Origin unchanged — left edge is anchor.
        } else if handle == .leftCenter {
            // Left edge drag → set wrap width AND shift origin so the right
            // edge stays anchored (Figma convention).
            let baseWidth = startWrapWidth ?? startRect.width
            let worldDX = translation.width / scale
            let newWrap = max(minTextWrapWidth, baseWidth - worldDX)
            placedTexts[idx].wrapWidth = newWrap
            // Right edge anchored at startRect.maxX; origin = right - newWrap.
            placedTexts[idx].worldRect.origin.x = startRect.maxX - newWrap
        }
    }

    private func commitTextResize() {
        defer { selection.clearTextResize() }
        guard let id = selection.textResizeElementID,
              let startFontSize = selection.textResizeStartFontSize,
              let startRect = selection.textResizeStartWorldRect,
              let idx = placedTexts.firstIndex(where: { $0.id == id }) else { return }
        let startWrapWidth = selection.textResizeStartWrapWidth
        let placed = placedTexts[idx]

        let toFontSize = placed.fontSize
        let toWrapWidth = placed.wrapWidth
        let toOrigin = placed.worldRect.origin

        // Skip no-op commits — happens if user touches a handle but doesn't
        // actually drag past the gesture's minimumDistance threshold.
        if toFontSize == startFontSize
            && toWrapWidth == startWrapWidth
            && toOrigin == startRect.origin {
            return
        }

        commandHistory.push(.resizeText(
            elementID: id,
            fromFontSize: startFontSize, toFontSize: toFontSize,
            fromWrapWidth: startWrapWidth, toWrapWidth: toWrapWidth,
            fromOrigin: startRect.origin, toOrigin: toOrigin
        ))

        let element = fallbackTextElement(for: placed)
        enqueueStoreMutation { store in
            await store.upsert(elements: [element])
        }
    }

    /// Restore a text element's resize-affected state (used by undo/redo
    /// of `.resizeText`). Matches the live-drag mutation surface so undo
    /// is bit-exact reversible.
    private func applyTextResizeState(
        elementID: UUID,
        fontSize: CGFloat,
        wrapWidth: CGFloat?,
        origin: CGPoint
    ) {
        guard let idx = placedTexts.firstIndex(where: { $0.id == elementID }) else { return }
        placedTexts[idx].fontSize = fontSize
        placedTexts[idx].wrapWidth = wrapWidth
        placedTexts[idx].worldRect.origin = origin
        let placed = placedTexts[idx]
        let element = fallbackTextElement(for: placed)
        enqueueStoreMutation { store in
            await store.upsert(elements: [element])
        }
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
        case .groupResize(let fromRects, _, let fromTextStates, _):
            applyGroupResizeApply(rects: fromRects, textStates: fromTextStates)
        case .insert(let snapshots):
            removeElements(snapshots: snapshots)
        case .delete(let snapshots):
            addElements(snapshots: snapshots)
        case .editTextContent(let id, let fromContent, _):
            applyTextContent(elementID: id, content: fromContent)
        case .resizeText(let id, let fromFontSize, _, let fromWrapWidth, _, let fromOrigin, _):
            applyTextResizeState(
                elementID: id,
                fontSize: fromFontSize,
                wrapWidth: fromWrapWidth,
                origin: fromOrigin
            )
        }
    }

    func performRedo() {
        guard let command = commandHistory.popRedo() else { return }
        switch command {
        case .move(let ids, let delta):
            applyMoveDelta(elementIDs: ids, dx: delta.width, dy: delta.height)
        case .resize(let id, _, let toRect):
            applyResizeRect(elementID: id, rect: toRect)
        case .groupResize(_, let toRects, _, let toTextStates):
            applyGroupResizeApply(rects: toRects, textStates: toTextStates)
        case .insert(let snapshots):
            addElements(snapshots: snapshots)
        case .delete(let snapshots):
            removeElements(snapshots: snapshots)
        case .editTextContent(let id, _, let toContent):
            applyTextContent(elementID: id, content: toContent)
        case .resizeText(let id, _, let toFontSize, _, let toWrapWidth, _, let toOrigin):
            applyTextResizeState(
                elementID: id,
                fontSize: toFontSize,
                wrapWidth: toWrapWidth,
                origin: toOrigin
            )
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
        for i in placedImages.indices {
            if elementIDs.contains(placedImages[i].id) {
                placedImages[i].worldRect.origin.x += dx
                placedImages[i].worldRect.origin.y += dy
            }
        }
        for i in visibleImages.indices {
            if elementIDs.contains(visibleImages[i].id) {
                visibleImages[i].worldRect.origin.x += dx
                visibleImages[i].worldRect.origin.y += dy
            }
        }
        for i in placedTexts.indices {
            if elementIDs.contains(placedTexts[i].id) {
                placedTexts[i].worldRect.origin.x += dx
                placedTexts[i].worldRect.origin.y += dy
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
        // Text elements don't support resize in v1; their world size is
        // re-derived from screen rendering each frame, so any rect we wrote
        // here would be overwritten on next layout.
        if placedTexts.contains(where: { $0.id == elementID }) { return }
        if let idx = placedImages.firstIndex(where: { $0.id == elementID }) {
            placedImages[idx].worldRect = rect
        }
        if let idx = visibleImages.firstIndex(where: { $0.id == elementID }) {
            visibleImages[idx].worldRect = rect
        }

        enqueueStoreMutation { store in
            let fetched = await store.elements(for: [elementID])
            if var element = fetched[elementID] {
                element.header.bounds = CMWorldRect(
                    origin: SIMD2<Double>(Double(rect.origin.x), Double(rect.origin.y)),
                    size: SIMD2<Double>(Double(rect.width), Double(rect.height))
                )
                if case .image(let url, _) = element.payload {
                    element.payload = .image(
                        url: url,
                        size: SIMD2<Double>(Double(rect.width), Double(rect.height))
                    )
                }
                await store.upsert(elements: [element])
            }
        }
    }

    /// Batch-apply multiple resize rects in a single store mutation (used by group resize + undo/redo).
    private func applyResizeRects(_ rects: [UUID: CGRect]) {
        // Filter out text elements — see applyResizeRect for rationale.
        let textIDs = Set(placedTexts.map(\.id))
        let imageRects = rects.filter { !textIDs.contains($0.key) }
        guard !imageRects.isEmpty else { return }

        // Update in-memory arrays synchronously
        for (id, rect) in imageRects {
            if let idx = placedImages.firstIndex(where: { $0.id == id }) {
                placedImages[idx].worldRect = rect
            }
            if let idx = visibleImages.firstIndex(where: { $0.id == id }) {
                visibleImages[idx].worldRect = rect
            }
        }

        // Single batched store mutation
        let ids = Array(imageRects.keys)
        enqueueStoreMutation { store in
            let fetched = await store.elements(for: ids)
            var updated: [CMCanvasElement] = []
            for (id, rect) in imageRects {
                if var element = fetched[id] {
                    element.header.bounds = CMWorldRect(
                        origin: SIMD2<Double>(Double(rect.origin.x), Double(rect.origin.y)),
                        size: SIMD2<Double>(Double(rect.width), Double(rect.height))
                    )
                    if case .image(let url, _) = element.payload {
                        element.payload = .image(
                            url: url,
                            size: SIMD2<Double>(Double(rect.width), Double(rect.height))
                        )
                    }
                    updated.append(element)
                }
            }
            await store.upsert(elements: updated)
        }
    }

    /// Restore a text element's content (used by undo/redo of
    /// `.editTextContent`). Updates the in-memory PlacedText and syncs the
    /// store. The view's `onGeometryChange` will re-derive worldRect.size
    /// after the content change re-renders, so we don't need to mutate it
    /// here.
    private func applyTextContent(elementID: UUID, content: String) {
        guard let idx = placedTexts.firstIndex(where: { $0.id == elementID }) else { return }
        placedTexts[idx].content = content
        let placed = placedTexts[idx]
        let element = fallbackTextElement(for: placed)
        enqueueStoreMutation { store in
            await store.upsert(elements: [element])
        }
    }

    private func addElements(snapshots: [PlacedElementSnapshot]) {
        for snap in snapshots {
            switch snap.element.payload {
            case .image:
                if let url = snap.url {
                    placedImages.append(PlacedImage(
                        id: snap.id, url: url,
                        worldRect: snap.worldRect, zIndex: snap.zIndex
                    ))
                }
            case .text(let content, _, let fontSize, _, let wrapWidth):
                placedTexts.append(PlacedText(
                    id: snap.id,
                    content: content,
                    worldRect: snap.worldRect,
                    zIndex: snap.zIndex,
                    fontSize: CGFloat(fontSize),
                    color: DesignSystem.Colors.primary,
                    wrapWidth: wrapWidth.map { CGFloat($0) }
                ))
            default:
                break
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
        let imagesByID: [UUID: PlacedImage] = Dictionary(
            uniqueKeysWithValues: placedImages
                .filter { targetIDs.contains($0.id) }
                .map { ($0.id, $0) }
        )
        let textsByID: [UUID: PlacedText] = Dictionary(
            uniqueKeysWithValues: placedTexts
                .filter { targetIDs.contains($0.id) }
                .map { ($0.id, $0) }
        )
        guard !imagesByID.isEmpty || !textsByID.isEmpty else { return }

        let store = canvasStore
        let allIDs = Array(imagesByID.keys) + Array(textsByID.keys)
        Task { @MainActor in
            let elementsByID = await store.elements(for: allIDs)
            var snapshots: [PlacedElementSnapshot] = []

            for (id, placed) in imagesByID {
                let authElement = elementsByID[id]
                let element = authElement ?? fallbackImageElement(for: placed)
                let worldRect: CGRect
                let zIndex: Int
                if let authElement {
                    let bounds = authElement.header.bounds
                    worldRect = CGRect(
                        x: CGFloat(bounds.origin.x), y: CGFloat(bounds.origin.y),
                        width: CGFloat(bounds.size.x), height: CGFloat(bounds.size.y)
                    )
                    zIndex = authElement.header.zIndex
                } else {
                    worldRect = placed.worldRect
                    zIndex = placed.zIndex
                }
                snapshots.append(PlacedElementSnapshot(
                    id: id, url: placed.url,
                    worldRect: worldRect, zIndex: zIndex, element: element
                ))
            }

            for (id, placed) in textsByID {
                let authElement = elementsByID[id]
                let element = authElement ?? fallbackTextElement(for: placed)
                let worldRect: CGRect
                let zIndex: Int
                if let authElement {
                    let bounds = authElement.header.bounds
                    worldRect = CGRect(
                        x: CGFloat(bounds.origin.x), y: CGFloat(bounds.origin.y),
                        width: CGFloat(bounds.size.x), height: CGFloat(bounds.size.y)
                    )
                    zIndex = authElement.header.zIndex
                } else {
                    worldRect = placed.worldRect
                    zIndex = placed.zIndex
                }
                snapshots.append(PlacedElementSnapshot(
                    id: id, url: nil,
                    worldRect: worldRect, zIndex: zIndex, element: element
                ))
            }

            commandHistory.push(.delete(snapshots: snapshots))
            removeElements(snapshots: snapshots)
        }
    }

    /// Used only if the store has no record of the element (shouldn't happen
    /// in normal flow, but keeps delete resilient to a store/view desync).
    private func fallbackImageElement(for placed: PlacedImage) -> CMCanvasElement {
        let rect = placed.worldRect
        let header = CMElementHeader(
            id: placed.id,
            type: .image,
            transform: CMAffineTransform2D(),
            bounds: CMWorldRect(
                origin: SIMD2<Double>(Double(rect.origin.x), Double(rect.origin.y)),
                size: SIMD2<Double>(Double(rect.size.width), Double(rect.size.height))
            ),
            layerId: UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID(),
            zIndex: placed.zIndex
        )
        let payload = CMCanvasElementPayload.image(
            url: placed.url,
            size: SIMD2<Double>(Double(rect.size.width), Double(rect.size.height))
        )
        return CMCanvasElement(header: header, payload: payload)
    }

    private func fallbackTextElement(for placed: PlacedText) -> CMCanvasElement {
        let rect = placed.worldRect
        let header = CMElementHeader(
            id: placed.id,
            type: .text,
            transform: CMAffineTransform2D(),
            bounds: CMWorldRect(
                origin: SIMD2<Double>(Double(rect.origin.x), Double(rect.origin.y)),
                size: SIMD2<Double>(Double(rect.size.width), Double(rect.size.height))
            ),
            layerId: UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID(),
            zIndex: placed.zIndex
        )
        let payload = CMCanvasElementPayload.text(
            content: placed.content,
            fontName: defaultTextFontName,
            fontSize: Double(placed.fontSize),
            color: defaultTextColorHex,
            wrapWidth: placed.wrapWidth.map { Double($0) }
        )
        return CMCanvasElement(header: header, payload: payload)
    }

    private func removeElements(snapshots: [PlacedElementSnapshot]) {
        let idsToRemove = Set(snapshots.map { $0.id })
        placedImages.removeAll { idsToRemove.contains($0.id) }
        visibleImages.removeAll { idsToRemove.contains($0.id) }
        placedTexts.removeAll { idsToRemove.contains($0.id) }
        selection.selectedIDs.subtract(idsToRemove)
        if let editing = editingTextID, idsToRemove.contains(editing) {
            editingTextID = nil
        }
        pendingTextInserts.subtract(idsToRemove)

        enqueueStoreMutation { store in
            await store.delete(elementIDs: Array(idsToRemove))
        }
    }

    // MARK: - Snapshot / Load Elements (Backend Bridge)

    private func applyElements(_ elements: [CMCanvasElement]) {
        placedImages.removeAll()
        placedTexts.removeAll()
        editingTextID = nil
        pendingTextInserts.removeAll()
        nextZIndex = 0
        for el in elements {
            let b = el.header.bounds
            let rect = CGRect(
                x: CGFloat(b.origin.x), y: CGFloat(b.origin.y),
                width: CGFloat(b.size.x), height: CGFloat(b.size.y)
            )
            let z = el.header.zIndex
            switch el.payload {
            case .image(let url, _):
                placedImages.append(PlacedImage(id: el.id, url: url, worldRect: rect, zIndex: z))
                nextZIndex = max(nextZIndex, z + 1)
            case .text(let content, _, let fontSize, _, let wrapWidth):
                placedTexts.append(PlacedText(
                    id: el.id,
                    content: content,
                    worldRect: rect,
                    zIndex: z,
                    fontSize: CGFloat(fontSize),
                    color: DesignSystem.Colors.primary,
                    wrapWidth: wrapWidth.map { CGFloat($0) }
                ))
                nextZIndex = max(nextZIndex, z + 1)
            default:
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

    private func visibleQueryMargin() -> Double {
        let zoomAwareMargin = Double(256 * max(scale, 0.25))
        return min(maxVisibleQueryMargin, max(minVisibleQueryMargin, zoomAwareMargin))
    }

    private func refreshVisibleElements() async {
        guard canvasSize != .zero else { return }
        let viewport = currentViewportRect()
        let placements = await canvasStore.imagePlacements(in: viewport, margin: visibleQueryMargin(), limit: nil)
        let items: [PlacedImage] = placements.map { placement in
            let bounds = placement.bounds
            let rect = CGRect(
                x: CGFloat(bounds.origin.x),
                y: CGFloat(bounds.origin.y),
                width: CGFloat(bounds.size.x),
                height: CGFloat(bounds.size.y)
            )
            return PlacedImage(id: placement.id, url: placement.url, worldRect: rect, zIndex: placement.zIndex)
        }
        visibleImages = items
        stickyDetailImageIDs = Set(computeImageRenderPlan(previousDetailIDs: stickyDetailImageIDs).detailItems.map(\.id))
    }

    // MARK: - Image Insertion

    private func insertImagesAtCenter(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let center = CGPoint(x: canvasSize.width / 2.0, y: canvasSize.height / 2.0)
        insertImages(atScreenPoint: center, urls: urls)
    }

    private func insertImages(atScreenPoint point: CGPoint, urls: [URL]) {
        let worldCenter = screenToWorld(point)
        insertionTask = Task(priority: .userInitiated) {
            let prepared = await ImageImportPreparationPipeline.shared.prepare(urls: urls)
            guard !Task.isCancelled, !prepared.isEmpty else { return }
            await applyPreparedImages(prepared, near: worldCenter)
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

    @MainActor
    private func applyPreparedImages(_ preparedImages: [PreparedImportedImage], near center: CGPoint) async {
        let insertionSpacing: CGFloat = 24
        let sizes = preparedImages.map { worldSizeForPixelSize($0.pixelSize) }
        let rects = batchInsertionRects(
            near: CGPoint(x: center.x, y: center.y),
            sizes: sizes,
            spacing: insertionSpacing
        )

        var snapshots: [PlacedElementSnapshot] = []
        snapshots.reserveCapacity(preparedImages.count)

        for (index, preparedImage) in preparedImages.enumerated() {
            let rect = rects[index]
            let zIndex = nextZIndex + index
            let header = CMElementHeader(
                id: UUID(),
                type: .image,
                transform: CMAffineTransform2D(),
                bounds: CMWorldRect(
                    origin: SIMD2<Double>(Double(rect.origin.x), Double(rect.origin.y)),
                    size: SIMD2<Double>(Double(rect.size.width), Double(rect.size.height))
                ),
                layerId: UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID(),
                zIndex: zIndex
            )
            let payload = CMCanvasElementPayload.image(
                url: preparedImage.url,
                size: SIMD2<Double>(Double(rect.size.width), Double(rect.size.height))
            )
            let element = CMCanvasElement(header: header, payload: payload)
            snapshots.append(PlacedElementSnapshot(
                id: header.id,
                url: preparedImage.url,
                worldRect: rect,
                zIndex: zIndex,
                element: element
            ))
        }

        guard !snapshots.isEmpty else { return }

        commandHistory.push(.insert(snapshots: snapshots))
        nextZIndex += snapshots.count

        let chunks = snapshots.chunked(into: insertionChunkSize)
        for (chunkIndex, chunk) in chunks.enumerated() {
            guard !Task.isCancelled else { break }

            placedImages.append(contentsOf: chunk.map {
                PlacedImage(id: $0.id, url: $0.url!, worldRect: $0.worldRect, zIndex: $0.zIndex)
            })

            let chunkElements = chunk.map(\.element)
            await canvasStore.upsert(elements: chunkElements)

            if chunkIndex == chunks.count - 1 || chunkIndex.isMultiple(of: 2) {
                await refreshVisibleElements()
            }
            await Task.yield()
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
            if !intersectsPlacedImages(candidateRects) {
                return candidateRects
            }
        }

        // Fall back to a finer-grained local search before moving the whole batch
        // outside the currently occupied canvas region.
        let fineStepX = max(24, spacing)
        let fineStepY = max(24, spacing)
        for offset in candidateBatchOffsets(stepX: fineStepX, stepY: fineStepY, maxRadius: 64) {
            let candidateRects = templateRects.map { $0.offsetBy(dx: offset.width, dy: offset.height) }
            if !intersectsPlacedImages(candidateRects) {
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

    private func intersectsPlacedImages(_ rects: [CGRect]) -> Bool {
        guard let batchBounds = union(of: rects) else { return false }
        let nearbyRects = placedImages
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
        guard let occupiedBounds = union(of: placedImages.map(\.worldRect)) else { return templateRects }

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
            if !intersectsPlacedImages(candidateRects) {
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

    /// Current visible viewport expressed as a world-space CGRect.
    private func viewportCGRect() -> CGRect {
        guard scale > 0, canvasSize != .zero else { return .zero }
        let worldMinX = (-offset.width) / scale
        let worldMinY = (-offset.height) / scale
        return CGRect(x: worldMinX, y: worldMinY,
                      width: canvasSize.width / scale,
                      height: canvasSize.height / scale)
    }

    /// World-space rects for every element (images + texts) on the canvas.
    private func allElementRects() -> [CGRect] {
        var rects = placedImages.map(\.worldRect)
        rects.append(contentsOf: placedTexts.map(\.worldRect))
        return rects
    }

    /// Animate the viewport so the center of all canvas content is centered
    /// on screen, preserving the current zoom level.
    private func jumpToContentCenter() {
        guard canvasSize != .zero, scale > 0 else { return }
        let allRects = allElementRects()
        let centerX: CGFloat
        let centerY: CGFloat
        if let bounds = union(of: allRects) {
            centerX = bounds.midX
            centerY = bounds.midY
        } else {
            centerX = 0
            centerY = 0
        }
        withAnimation(.easeInOut(duration: 0.4)) {
            offset = CGSize(
                width: canvasSize.width / 2 - centerX * scale,
                height: canvasSize.height / 2 - centerY * scale
            )
        } completion: {
            scheduleRefreshVisibleElements()
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

    // MARK: - Text Insertion / Edit

    /// Place a new text element at the given world point and immediately
    /// enter edit mode. The element starts with empty content; if the user
    /// commits without typing, it's removed silently (no history entry).
    private func insertText(at worldPoint: CGPoint) {
        // Commit any in-flight edit on a different text first so two
        // unfinished drafts can't coexist.
        if let prior = editingTextID {
            commitTextEdit(id: prior)
        }

        let id = UUID()
        let text = PlacedText(
            id: id,
            content: "",
            // Origin is provisional — real size lands once the view measures.
            worldRect: CGRect(origin: worldPoint, size: .zero),
            zIndex: nextZIndex,
            fontSize: defaultTextFontSize,
            color: DesignSystem.Colors.primary
        )
        placedTexts.append(text)
        nextZIndex += 1
        pendingTextInserts.insert(id)
        selection.clearSelection()
        editingTextID = id
        // Auto-swap back to pointer so the next canvas tap doesn't try to
        // place yet another draft on top of the one we just created. The
        // skip flag stops the activeTool onChange from committing the new
        // draft we're still editing.
        skipNextToolChangeCommit = true
        activeTool = .pointer
    }

    /// Commits the active text edit for `id`. Handles two paths:
    ///
    /// - **Newly placed** (id ∈ `pendingTextInserts`): empty content is
    ///   discarded silently; non-empty content pushes an `.insert` command
    ///   so the placement can be undone.
    /// - **Re-edit** of an existing text (id ∉ `pendingTextInserts`):
    ///   non-empty content syncs to the store and pushes an
    ///   `.editTextContent` command if the content actually changed;
    ///   clearing all content pushes a `.delete` command so undo can
    ///   restore the element.
    ///
    /// Idempotent for newly-placed ids — pendingTextInserts.remove is the
    /// re-entrancy guard. For re-edits, the original-content snapshot is
    /// scoped to `editingTextID == id` so a re-fire after the first
    /// commit (e.g. focus loss after a selection-change commit) sees a
    /// nil original and skips the duplicate push.
    private func commitTextEdit(id: UUID) {
        let wasNewlyPlaced = pendingTextInserts.contains(id)
        pendingTextInserts.remove(id)
        let wasCurrentEdit = (editingTextID == id)
        if wasCurrentEdit { editingTextID = nil }
        let originalContent = wasCurrentEdit ? editingTextOriginalContent : nil
        if wasCurrentEdit { editingTextOriginalContent = nil }

        guard let idx = placedTexts.firstIndex(where: { $0.id == id }) else { return }
        let placed = placedTexts[idx]
        let trimmed = placed.content.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            placedTexts.remove(at: idx)
            if wasNewlyPlaced {
                // Empty draft — discard silently, no history entry.
                return
            }
            // Existing text whose content was cleared during re-edit. Push a
            // `.delete` so undo can restore the element with its prior
            // content. We rebuild the snapshot's element from the original
            // content (not the cleared current) so the restored text isn't
            // empty when the user undoes.
            var restored = placed
            if let originalContent {
                restored.content = originalContent
            }
            let element = fallbackTextElement(for: restored)
            let snapshot = PlacedElementSnapshot(
                id: id, url: nil,
                worldRect: restored.worldRect, zIndex: restored.zIndex, element: element
            )
            commandHistory.push(.delete(snapshots: [snapshot]))
            enqueueStoreMutation { store in
                await store.delete(elementIDs: [id])
            }
            return
        }

        let element = fallbackTextElement(for: placed)
        if wasNewlyPlaced {
            let snapshot = PlacedElementSnapshot(
                id: id, url: nil,
                worldRect: placed.worldRect, zIndex: placed.zIndex, element: element
            )
            commandHistory.push(.insert(snapshots: [snapshot]))
        } else if let originalContent, originalContent != placed.content {
            // Re-edit produced a real content change — record it for undo.
            commandHistory.push(.editTextContent(
                elementID: id,
                fromContent: originalContent,
                toContent: placed.content
            ))
        }
        // Always upsert — covers both new placements and re-edit content
        // changes (history-tracked or not).
        enqueueStoreMutation { store in
            await store.upsert(elements: [element])
        }
    }

    // MARK: - Models

    private struct ImageRenderPlan {
        let detailItems: [PlacedImage]
        let overviewItems: [PlacedImage]
    }
}

#Preview {
    BoardCanvasView(commandHistory: CanvasCommandHistory())
}

private struct PreparedImportedImage {
    let url: URL
    let pixelSize: CGSize?
}

private actor ImageImportPreparationPipeline {
    static let shared = ImageImportPreparationPipeline()

    private let limiter = AsyncLimiter(limit: 4)

    func prepare(urls: [URL]) async -> [PreparedImportedImage] {
        await withTaskGroup(of: (Int, PreparedImportedImage?).self) { group in
            for (index, sourceURL) in urls.enumerated() {
                group.addTask { [limiter] in
                    await limiter.withPermit {
                        await Task.detached(priority: .utility) {
                            guard let copiedURL = Self.sandboxCopyIfNeeded(from: sourceURL) else {
                                return (index, nil)
                            }
                            let pixelSize = Self.imagePixelSize(at: copiedURL)
                            return (index, PreparedImportedImage(url: copiedURL, pixelSize: pixelSize))
                        }.value
                    }
                }
            }

            var orderedResults = Array<PreparedImportedImage?>(repeating: nil, count: urls.count)
            for await (index, prepared) in group {
                orderedResults[index] = prepared
            }
            return orderedResults.compactMap { $0 }
        }
    }

    nonisolated private static func sandboxCopyIfNeeded(from url: URL) -> URL? {
        if url.isFileURL, url.path.contains(Bundle.main.bundleIdentifier ?? "") {
            return url
        }

        let accessGranted = url.startAccessingSecurityScopedResource()
        defer {
            if accessGranted {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let fileManager = FileManager.default
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return url
        }

        let directory = appSupport.appendingPathComponent("ImportedImages", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let ext = url.pathExtension.isEmpty ? "dat" : url.pathExtension
            let destination = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
            do {
                try fileManager.copyItem(at: url, to: destination)
                return destination
            } catch {
                if let data = try? Data(contentsOf: url) {
                    try data.write(to: destination, options: [.atomic])
                    return destination
                }
            }
        } catch {
            return nil
        }

        return nil
    }

    nonisolated private static func imagePixelSize(at url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        guard let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else {
            return nil
        }
        return CGSize(width: width, height: height)
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }

        var chunks: [[Element]] = []
        chunks.reserveCapacity((count + size - 1) / size)

        var index = startIndex
        while index < endIndex {
            let nextIndex = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            chunks.append(Array(self[index..<nextIndex]))
            index = nextIndex
        }
        return chunks
    }
}
