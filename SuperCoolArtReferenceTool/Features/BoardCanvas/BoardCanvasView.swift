import SwiftUI
import UniformTypeIdentifiers
import ImageIO
import simd

struct BoardCanvasView: View {
    typealias ImportHandler = ([URL]) -> Void
    private let onInsertURLs: ImportHandler

    // View transform (world -> screen)
    @State private var camera = CanvasCamera()

    // Gesture state
    @State private var dragStartOffset: CGSize? = nil
    @State private var isInteracting: Bool = false
    @State private var interactionEndTask: Task<Void, Never>? = nil

    // Grid options
    @Binding private var showGrid: Bool
    @Binding private var canvasColor: Color
    @State private var gridSpacingWorld: CGFloat = 128.0
    /// Hardware Shift state at touch-down, for shift-tap-to-extend. Stays
    /// false on a device with no keyboard, which is the touch-only path.
    @State private var keyModifiers = KeyModifierMonitor()

    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Whole environment, needed to resolve `canvasColor` to concrete RGB —
    /// it can be an adaptive color, and the starting color for new text is
    /// derived from how light or dark the canvas actually renders.
    @Environment(\.self) private var environment

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
    /// `.group` (the default; Figma convention — keep editing the just-placed text but
    /// stop routing subsequent canvas taps through the text tool), the
    /// resulting `onChange(of: activeTool)` would otherwise commit the
    /// brand-new draft.
    /// Set right before the programmatic write, consumed on the next firing.
    @State private var skipNextToolChangeCommit: Bool = false
    /// Snapshot of the text content captured at the moment a re-edit begins.
    /// Used to push an `.editTextContent` command on commit if the content
    /// actually changed. Nil for newly-placed texts (those use the
    /// `.insert` command path instead) and when no re-edit is active.
    @State private var editingTextOriginalContent: String? = nil
    @State private var placedFrames: [PlacedFrame] = []
    @State private var assetNames: [UUID: String] = [:]
    @State private var outlineRebuildTask: Task<Void, Never>? = nil

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
    // Color hex round-trips through CMCanvasElementPayload.text: it is
    // written from `PlacedText.colorHex` and read back into it, with
    // `PlacedText.color` deriving the render color (see TextColorMemory for
    // where the default for *new* text comes from).
    private let defaultTextFontSize: CGFloat = 24
    private let defaultTextFontName: String = "system"

    /// Last text color picked on *this board*, as `#RRGGBB`, or nil when
    /// nothing has been picked yet. Owned by `ContentView` (which persists it
    /// to the manifest) so it travels with the board rather than the app:
    /// a dark board and a light board want different text, and picking on one
    /// shouldn't change the other.
    @Binding private var lastTextColorHex: String?

    /// Original per-element colors captured when a color edit begins, held
    /// until the edit coalesces into a single history command. Nil when no
    /// edit is in flight.
    @State private var textColorEditOriginals: [UUID: String]? = nil
    /// Debounce for the above. The system `ColorPicker` publishes a new
    /// color on every frame of a spectrum drag; without coalescing, one
    /// visit to the picker would push dozens of undo steps.
    @State private var textColorCommitTask: Task<Void, Never>? = nil
    /// Same coalescing as the two above, for the frame color picker.
    @State private var frameFillEditOriginals: [UUID: String?]? = nil
    @State private var frameFillCommitTask: Task<Void, Never>? = nil
    private let defaultFramePadding: CGFloat = 40

    // Zoom bounds
    private let minScale: CGFloat = 0.05
    private let maxScale: CGFloat = 8.0

    // Active tool from toolbar
    @Binding private var activeTool: CanvasTool
    // Home-button trigger: fires zoomToFitContent when set to a non-nil UUID
    @Binding private var homeTrigger: UUID?
    // Selection state
    @State private var selection = CanvasSelectionState()
    @State private var currentDragMode: DragMode? = nil
    @State private var dragStartWorldPos: CGPoint? = nil

    // Undo/redo. `commandHistory` registers into the window's `UndoManager`
    // (found by `WindowUndoManagerReader` below), which is what gives us the
    // menu bar's Edit > Undo/Redo, the three-finger gestures, ⌘Z, and the
    // Undo/Redo pill.
    var commandHistory: CanvasCommandHistory

    /// Feeds the asset outliner shown in `CanvasHUDView`.
    private let outliner: AssetOutlinerModel

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
    init(activeTool: Binding<CanvasTool> = .constant(.group), externalInsertURLs: Binding<[URL]?> = .constant(nil), showGrid: Binding<Bool> = .constant(true), canvasColor: Binding<Color> = .constant(.white), lastTextColorHex: Binding<String?> = .constant(nil), snapshotTrigger: Binding<UUID?> = .constant(nil), loadElements: Binding<[CMCanvasElement]?> = .constant(nil), commandHistory: CanvasCommandHistory, outliner: AssetOutlinerModel, homeTrigger: Binding<UUID?> = .constant(nil), markCleanTrigger: Binding<UUID?> = .constant(nil), onInsertURLs: @escaping ImportHandler = { _ in }, onSnapshot: (([CMCanvasElement], Bool) -> Void)? = nil) {
        let store = LocalBoardStore()
        self._canvasStore = State(initialValue: store)
        self._activeTool = activeTool
        self._externalInsertURLs = externalInsertURLs
        self._showGrid = showGrid
        self._canvasColor = canvasColor
        self._lastTextColorHex = lastTextColorHex
        self.commandHistory = commandHistory
        self.outliner = outliner
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
                CanvasGridView(
                    showGrid: showGrid,
                    scale: camera.scale,
                    offset: camera.offset,
                    gridSpacing: gridSpacingWorld,
                    safeAreaInsets: geo.safeAreaInsets
                )
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
                    CanvasOverviewLayer(
                        items: overviewItems(renderPlan.overviewItems),
                        scale: camera.scale,
                        offset: camera.offset
                    )
                }

                frameLayer()
                imageLayer(renderPlan: renderPlan)
                textLayer()
                frameTitleLayer()

                marqueeLayer()

                // Solo-text selection chrome — rendered externally at
                // screen coordinates so the resize handles stay at a
                // constant 10pt size regardless of canvas zoom (the text
                // body itself uses .scaleEffect for visual zoom, so any
                // overlay drawn inside that scaled view shrinks with
                // text — bad for touch targets on iPad). Symmetric with
                // how image group selection already renders chrome
                // outside the per-image view.
                selectedTextChromeLayer()

                // Editing border for the active text — rendered externally
                // for the same reason as the selection chrome above. The
                // 1.5pt stroke would otherwise scale with the text via
                // scaleEffect and become invisible at low zoom levels
                // when the text has been size-resized up.
                editingTextBorderLayer()

                selectedFrameBorderLayer()

                // Floating action bar beneath the current selection.
                selectionActionBarLayer()

                // Group bounding box with resize handles
                groupSelectionOverlayLayer()
            }
            .overlay {
                if placedImages.isEmpty && placedTexts.isEmpty && placedFrames.isEmpty {
                    EmptyCanvasOverlay()
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
            .background { outlinerSync }
            .onAppear {
                canvasSize = geo.size
                // Center the canvas on world origin (0, 0) on first appearance
                if camera.offset == .zero {
                    camera.offset = CGSize(width: geo.size.width / 2, height: geo.size.height / 2)
                }
                // If elements were already applied AND no pending load is in flight
                // (elementsToLoad non-nil means the deferred DispatchQueue handler
                // will snap after it fires — gating here avoids a redundant double call).
                if elementsToLoad == nil && (!placedImages.isEmpty || !placedTexts.isEmpty) {
                    zoomToFitContent(animated: false)
                } else {
                    scheduleRefreshVisibleElements()
                }
            }
            .onDisappear {
                refreshTask?.cancel()
                interactionEndTask?.cancel()
                insertionTask?.cancel()
                // The window's undo manager outlives this view. Leaving our
                // actions in it would let a three-finger swipe on the file
                // picker try to edit a board that's no longer on screen.
                commandHistory.clear()
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
                    Task { @MainActor in
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
                // Same reasoning for a color pick still inside its coalescing
                // window — flush it so the store write happens before, not
                // after, the snapshot reads the store.
                commitTextColorEdit()
                commitFrameFillEdit()
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
                Task { @MainActor in
                    await canvasStore.markClean()
                    markCleanTrigger = nil
                }
            }
            .onChange(of: elementsToLoad) { oldValue, newValue in
                if let els = newValue {
                    applyElements(els)
                    commandHistory.clear()
                    selection.clearSelection()
                    // Defer one run-loop tick so every onAppear handler has
                    // fired and canvasSize is guaranteed non-zero before we
                    // try to center on content. DispatchQueue.main.async is
                    // intentional: Task{} uses Swift concurrency's cooperative
                    // scheduler and doesn't drain the run loop; .main.async does.
                    DispatchQueue.main.async {
                        if !els.isEmpty {
                            zoomToFitContent(animated: false)
                        }
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
                // flips activeTool back to the default tool while keeping
                // focus on the just-placed draft.
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
            .onChange(of: homeTrigger) { _, newValue in
                guard newValue != nil else { return }
                zoomToFitContent()
                Task { @MainActor in homeTrigger = nil }
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
                            dragStartOffset = camera.offset

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
                                    let resizeIDs = selectionRoots(selection.selectedIDs)
                                    var startRects: [UUID: CGRect] = [:]
                                    for img in placedImages where resizeIDs.contains(img.id) {
                                        startRects[img.id] = img.worldRect
                                    }
                                    for frame in placedFrames where resizeIDs.contains(frame.id) {
                                        startRects[frame.id] = frame.worldRect
                                    }
                                    var startTextStates: [UUID: TextResizeSnapshot] = [:]
                                    for txt in placedTexts where resizeIDs.contains(txt.id) {
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
                                HitTestItem(id: $0.id, worldRect: visibleWorldRect(id: $0.id, rect: $0.worldRect), zIndex: $0.zIndex)
                            }
                            items.append(contentsOf: placedTexts.map {
                                HitTestItem(id: $0.id, worldRect: visibleWorldRect(id: $0.id, rect: $0.worldRect), zIndex: $0.zIndex)
                            })
                            // A frame's body only counts once the frame is
                            // selected (Figma convention). Otherwise a drag on
                            // bare frame area draws a marquee, and the frame
                            // is grabbed by its name pill.
                            items.append(contentsOf: placedFrames
                                .filter { selection.selectedIDs.contains($0.id) }
                                .map {
                                    HitTestItem(id: $0.id, worldRect: visibleWorldRect(id: $0.id, rect: $0.worldRect), zIndex: $0.zIndex, isFrame: true)
                                })
                            items.append(contentsOf: frameTitleHitItems())
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
                            // Dragged items come to the front, frames with
                            // their contents (see `raiseToTop`).
                            if mode == .moveItem {
                                raiseToTop(selection.selectedIDs)
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
            .background(KeyModifierObserverView(monitor: keyModifiers))
            .background(TwoFingerPanView(onPan: handleTwoFingerPan))
            .background(PinchGestureView(onPinch: handlePinch))
            .background(WindowUndoManagerReader { commandHistory.attach($0) })
        }
    }

    /// During a drag, lift the selected roots out of their old containers.
    /// Descendants still clip to the moving frame they travel with.
    private func frameClipRect(for id: UUID) -> CGRect? {
        let moving = selection.isDragging ? expandedElementIDs(for: selection.selectedIDs) : []
        let ancestors = FrameGeometry.ancestors(of: parentFrameID(for: id), in: placedFrames)
        var clip: CGRect?
        for frame in ancestors {
            if moving.contains(id) && !moving.contains(frame.id) { break }
            let rect = moving.contains(frame.id)
                ? frame.worldRect.offsetBy(dx: selection.dragOffset.width, dy: selection.dragOffset.height)
                : frame.worldRect
            clip = clip.map { $0.intersection(rect) } ?? rect
        }
        return clip
    }

    private func screenFrameClipRect(for id: UUID) -> CGRect? {
        frameClipRect(for: id).map { rect in
            guard !rect.isNull else { return CGRect.null }
            return CGRect(x: rect.minX * camera.scale + camera.offset.width,
                          y: rect.minY * camera.scale + camera.offset.height,
                          width: rect.width * camera.scale, height: rect.height * camera.scale)
        }
    }

    private func visibleWorldRect(id: UUID, rect: CGRect) -> CGRect {
        frameClipRect(for: id).map { rect.intersection($0) } ?? rect
    }

    private func overviewItems(_ items: [PlacedImage]) -> [PlacedImage] {
        let moving = selection.isDragging ? expandedElementIDs(for: selection.selectedIDs) : []
        return items.compactMap { item in
            var visible = item
            if moving.contains(item.id) {
                visible.worldRect = visible.worldRect.offsetBy(dx: selection.dragOffset.width, dy: selection.dragOffset.height)
            }
            visible.worldRect = visibleWorldRect(id: item.id, rect: visible.worldRect)
            return visible.worldRect.isNull || visible.worldRect.isEmpty ? nil : visible
        }
    }

    /// Keeps the shared `AssetOutlinerModel` current. The outliner itself is
    /// drawn by `CanvasHUDView` up in `ContentView`. Lives on an invisible
    /// background view so `body`'s modifier chain stays small enough for the
    /// compiler to type-check.
    ///
    /// The tree is rebuilt only when the board's contents change, not on
    /// every redraw: pans, zooms, and drags redraw constantly but don't touch
    /// these arrays.
    private var outlinerSync: some View {
        Color.clear
            .onChange(of: placedImages) { scheduleOutlineRebuild() }
            .onChange(of: placedTexts) { scheduleOutlineRebuild() }
            .onChange(of: placedFrames) { scheduleOutlineRebuild() }
            .onChange(of: assetNames) { scheduleOutlineRebuild() }
            .onChange(of: expandedElementIDs(for: selection.selectedIDs), initial: true) { _, ids in
                outliner.selectedIDs = ids
            }
            .onAppear {
                outliner.nodes = assetOutlineNodes()
                outliner.onSelect = { selectAssetFromOutliner($0) }
                outliner.onFocus = { focusAssetFromOutliner($0) }
                outliner.onRename = { renameAsset(id: $0, title: $1) }
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func frameLayer() -> some View {
        // Unpicked frames follow the canvas color (see `FrameFill`).
        let defaultFill = FrameFill.defaultHex(onCanvas: canvasColor.resolve(in: environment))
        let sortedFrames = placedFrames.sorted { $0.zIndex < $1.zIndex }
        let highlightedIDs = expandedElementIDs(for: selection.selectedIDs)
        let movingIDs = selection.isDragging ? expandedElementIDs(for: selection.selectedIDs) : []
        ForEach(sortedFrames, id: \.id) { frame in
            let isSelected = highlightedIDs.contains(frame.id)
            let liveDX = (movingIDs.contains(frame.id)) ? selection.dragOffset.width * camera.scale : 0
            let liveDY = (movingIDs.contains(frame.id)) ? selection.dragOffset.height * camera.scale : 0
            let screenRect = CGRect(
                x: frame.worldRect.origin.x * camera.scale + camera.offset.width + liveDX,
                y: frame.worldRect.origin.y * camera.scale + camera.offset.height + liveDY,
                width: frame.worldRect.width * camera.scale,
                height: frame.worldRect.height * camera.scale
            )

            CanvasPlacedFrameView(
                screenRect: screenRect,
                fill: Color(hex: frame.fillHex ?? defaultFill) ?? .clear,
                isSelected: isSelected,
                zIndex: frame.zIndex
            )
            // `CanvasPlacedFrameView` ends in `.position`, which fills the
            // canvas, so this mask is in canvas coordinates, the same space
            // `screenFrameClipRect` returns. No local conversion needed.
            .mask(FrameClipShape(boundary: screenFrameClipRect(for: frame.id)))
        }
    }

    /// Measured on-screen width of each frame's name pill, so a drag that
    /// starts on a pill can grab its frame (see `frameTitleHitItems`).
    @State private var frameTitleWidths: [UUID: CGFloat] = [:]

    /// One hit target per frame name pill, in world space. They rank as
    /// topmost non-frame items, because the pill is drawn above everything
    /// and is where the user sees the frame's handle.
    private func frameTitleHitItems() -> [HitTestItem] {
        let scale = camera.scale
        return placedFrames.compactMap { frame in
            guard let width = frameTitleWidths[frame.id], scale > 0 else { return nil }
            let rect = CGRect(
                x: frame.worldRect.minX,
                y: frame.worldRect.minY - (frameTitleRowHeight + 4) / scale,
                width: width / scale,
                height: frameTitleRowHeight / scale
            )
            return HitTestItem(id: frame.id, worldRect: rect, zIndex: .max)
        }
    }

    /// Height of the strip above each frame that holds its name pill.
    private let frameTitleRowHeight: CGFloat = 30

    /// Every frame's name pill, drawn above all items so a pill is never
    /// hidden behind an image and always takes the tap. Each pill sits just
    /// above its frame, flush with the frame's left edge.
    @ViewBuilder
    private func frameTitleLayer() -> some View {
        let movingIDs = selection.isDragging ? expandedElementIDs(for: selection.selectedIDs) : []
        ForEach(placedFrames) { frame in
            let liveDX = movingIDs.contains(frame.id) ? selection.dragOffset.width * camera.scale : 0
            let liveDY = movingIDs.contains(frame.id) ? selection.dragOffset.height * camera.scale : 0
            let minX = frame.worldRect.minX * camera.scale + camera.offset.width + liveDX
            let minY = frame.worldRect.minY * camera.scale + camera.offset.height + liveDY
            let rowWidth = max(frame.worldRect.width * camera.scale, FrameTitlePill.minWidth)

            FrameTitlePill(
                title: frame.title,
                isSelected: selection.selectedIDs.contains(frame.id),
                onSelect: { handleItemTap(frame.id, refreshAfterSelection: false) },
                onRename: { renameAsset(id: frame.id, title: $0) }
            )
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                frameTitleWidths[frame.id] = width
            }
            // Offer the pill the frame's width (or the minimum), pinned to
            // the frame's left edge. Long names truncate instead of running
            // past the frame.
            .frame(width: rowWidth, height: frameTitleRowHeight, alignment: .bottomLeading)
            .position(x: minX + rowWidth / 2, y: minY - frameTitleRowHeight / 2 - 4)
            .zIndex(Double(Int.max - 3))
        }
    }

    @ViewBuilder
    private func imageLayer(renderPlan: ImageRenderPlan) -> some View {
        let selectedIDs = selection.selectedIDs
        let highlightedIDs = expandedElementIDs(for: selectedIDs)
        let movingIDs = selection.isDragging ? expandedElementIDs(for: selectedIDs) : []
        ForEach(renderPlan.detailItems) { item in
            let isSelected = highlightedIDs.contains(item.id)
            let isBeingResized = selection.isResizing && selection.resizeElementID == item.id

            let liveRect: CGRect = {
                if isBeingResized {
                    return selection.resizeCurrentRect ?? item.worldRect
                } else {
                    return item.worldRect
                }
            }()

            let liveDX = (movingIDs.contains(item.id)) ? selection.dragOffset.width * camera.scale : 0
            let liveDY = (movingIDs.contains(item.id)) ? selection.dragOffset.height * camera.scale : 0

            let multiSelected = highlightedIDs.count > 1
            let scaledWidth = liveRect.width * camera.scale
            let scaledHeight = liveRect.height * camera.scale
            let maxDimensionPoints = max(scaledWidth, scaledHeight)
            let position = screenPosition(for: liveRect, dx: liveDX, dy: liveDY)
            let targetMaxPixelSize = FileImageView.requestedThumbnailPixelSize(
                screenMaxDimensionPoints: maxDimensionPoints,
                displayScale: displayScale,
                isInteracting: isInteracting
            )
            CanvasPlacedImageItemView(
                url: item.url,
                targetMaxPixelSize: targetMaxPixelSize,
                isInteracting: isInteracting,
                size: CGSize(width: scaledWidth, height: scaledHeight),
                position: position,
                clipRect: screenFrameClipRect(for: item.id),
                isSelected: isSelected,
                isMultiSelected: multiSelected,
                activeHandle: selection.resizeHandle,
                zIndex: item.zIndex,
                onTap: { handleItemTap(item.id, refreshAfterSelection: true) }
            )
        }
    }

    @ViewBuilder
    private func textLayer() -> some View {
        let selectedIDs = selection.selectedIDs
        let highlightedIDs = expandedElementIDs(for: selectedIDs)
        let movingIDs = selection.isDragging ? expandedElementIDs(for: selectedIDs) : []
        // Keyed by the text's id, with a binding per element. Keying by array
        // index re-bound views to different texts whenever one was removed,
        // and a stale index binding can crash.
        ForEach($placedTexts) { $placed in
            let isSelected = highlightedIDs.contains(placed.id)
            let isMultiSelected = highlightedIDs.count > 1
            let liveDX = (movingIDs.contains(placed.id)) ? selection.dragOffset.width * camera.scale : 0
            let liveDY = (movingIDs.contains(placed.id)) ? selection.dragOffset.height * camera.scale : 0
            let id = placed.id
            let isEditing = editingTextID == id
            let isOnlySelected = selectedIDs.count == 1 && selectedIDs.contains(id)
            let position = screenPosition(for: placed.worldRect, dx: liveDX, dy: liveDY)

            CanvasPlacedTextItemView(
                placed: $placed,
                scale: camera.scale,
                position: position,
                clipRect: screenFrameClipRect(for: placed.id),
                isEditing: isEditing,
                isSelected: isSelected,
                isMultiSelected: isMultiSelected,
                onCommitEdit: { commitTextEdit(id: id) },
                onTap: { handleTextTap(id, currentContent: placed.content, isOnlySelected: isOnlySelected) }
            )
        }
    }

    private func selectionActionBarLayer() -> some View {
        SelectionActionBarLayer(
            boundingBox: selectionBoundingBox(),
            scale: camera.scale,
            offset: camera.offset,
            isInteracting: isSelectionActionBarInteracting,
            textColorHex: selectionTextColorHex(),
            onPickTextColor: applyTextColor(hex:),
            frameFillHex: selectionFrameFillHex(),
            onPickFrameFill: applyFrameFill(hex:),
            onCreateFrame: selectionActionBarCreateFrameAction,
            onRemoveFrame: selectedFrameID == nil ? nil : { removeSelectedFrame() },
            onDelete: { deleteSelection() }
        )
        .zIndex(Double(Int.max - 1))
    }

    private var selectionActionBarCreateFrameAction: (() -> Void)? {
        canCreateFrameFromSelection() ? { createFrameFromSelection() } : nil
    }

    private var isSelectionActionBarInteracting: Bool {
        isInteracting ||
        selection.isDragging ||
        selection.isResizing ||
        selection.isTextResizing ||
        selection.isGroupResizing ||
        selection.isMarqueeing
    }

    @ViewBuilder
    private func selectedTextChromeLayer() -> some View {
        if selection.selectedIDs.count == 1,
           let selectedID = selection.selectedIDs.first,
           let placed = placedTexts.first(where: { $0.id == selectedID }),
           editingTextID != selectedID,
           !selection.isDragging,
           !selection.isMarqueeing {
            let screenRect = CGRect(
                x: placed.worldRect.origin.x * camera.scale + camera.offset.width,
                y: placed.worldRect.origin.y * camera.scale + camera.offset.height,
                width: placed.worldRect.width * camera.scale,
                height: placed.worldRect.height * camera.scale
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
    }

    @ViewBuilder
    private func editingTextBorderLayer() -> some View {
        if let editingID = editingTextID,
           let placed = placedTexts.first(where: { $0.id == editingID }) {
            let screenRect = CGRect(
                x: placed.worldRect.origin.x * camera.scale + camera.offset.width,
                y: placed.worldRect.origin.y * camera.scale + camera.offset.height,
                width: placed.worldRect.width * camera.scale,
                height: placed.worldRect.height * camera.scale
            )
            CanvasScreenRectBorderView(
                screenRect: screenRect,
                lineWidth: 1.5,
                color: DesignSystem.Colors.tertiary
            )
            .zIndex(Double(Int.max - 2))
        }
    }

    @ViewBuilder
    private func selectedFrameBorderLayer() -> some View {
        if selection.selectedIDs.count == 1,
           let selectedID = selection.selectedIDs.first,
           let frame = placedFrames.first(where: { $0.id == selectedID }),
           !selection.isDragging,
           !selection.isMarqueeing {
            let worldRect = selection.isGroupResizing
                ? (selection.groupResizeBBoxCurrent ?? frame.worldRect)
                : frame.worldRect
            let screenRect = CGRect(
                x: worldRect.origin.x * camera.scale + camera.offset.width,
                y: worldRect.origin.y * camera.scale + camera.offset.height,
                width: worldRect.width * camera.scale,
                height: worldRect.height * camera.scale
            )
            GroupSelectionOverlay(activeHandle: selection.resizeHandle)
                .frame(width: screenRect.width, height: screenRect.height)
                .position(x: screenRect.midX, y: screenRect.midY)
                .allowsHitTesting(false)
                .zIndex(Double(Int.max - 2))
        }
    }

    @ViewBuilder
    private func marqueeLayer() -> some View {
        if selection.isMarqueeing, let worldRect = selection.marqueeWorldRect {
            let screenRect = CGRect(
                x: worldRect.origin.x * camera.scale + camera.offset.width,
                y: worldRect.origin.y * camera.scale + camera.offset.height,
                width: worldRect.width * camera.scale,
                height: worldRect.height * camera.scale
            )
            MarqueeOverlayView(screenRect: screenRect)
                .allowsHitTesting(false)
                .zIndex(Double(Int.max - 1))
        }
    }

    @ViewBuilder
    private func groupSelectionOverlayLayer() -> some View {
        if selection.selectedIDs.count > 1, !selection.isDragging {
            let bbox: CGRect? = selection.isGroupResizing
                ? (selection.groupResizeBBoxCurrent ?? groupBoundingBox())
                : groupBoundingBox()
            if let bbox {
                let screenRect = CGRect(
                    x: bbox.origin.x * camera.scale + camera.offset.width,
                    y: bbox.origin.y * camera.scale + camera.offset.height,
                    width: bbox.width * camera.scale,
                    height: bbox.height * camera.scale
                )
                GroupSelectionOverlay(activeHandle: selection.resizeHandle)
                    .frame(width: screenRect.width, height: screenRect.height)
                    .position(x: screenRect.midX, y: screenRect.midY)
                    .allowsHitTesting(false)
                    .zIndex(Double(Int.max))
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
            try? await Task.sleep(for: .milliseconds(150))
            isInteracting = false
        }
    }

    private func handlePinch(phase: PinchGestureView.Phase, scaleDelta: CGFloat, anchor: CGPoint) {
        switch phase {
        case .began:
            startInteraction()
        case .changed:
            let newScale = clamp(camera.scale * scaleDelta, minScale, maxScale)
            // Clamp can cancel the delta; skip to avoid unnecessary offset churn.
            guard newScale != camera.scale else { return }
            // Pivot-preserving zoom: keep the world point currently under `anchor`
            // pinned to the same screen position after the scale change. Reading
            // `camera.offset`/`camera.scale` fresh every tick is what lets this
            // compose with the simultaneous two-finger pan (no frozen baselines).
            camera.offset = CanvasCamera.zoomAnchoredOffset(
                anchor: anchor,
                oldOffset: camera.offset,
                oldScale: camera.scale,
                newScale: newScale
            )
            camera.scale = newScale
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
            camera.offset = CGSize(width: camera.offset.width + delta.width,
                                   height: camera.offset.height + delta.height)
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
        let frameIDs = Set(placedFrames.map(\.id))
        // Solo text selection — corners scale font (Freeform-style),
        // left/right edges set wrap width. Top/bottom never hit since
        // the visual overlay doesn't render those handles for text, but
        // the gesture drag also rejects them defensively below.
        if selection.selectedIDs.count == 1,
           let selectedID = selection.selectedIDs.first,
           textIDs.contains(selectedID),
           let text = placedTexts.first(where: { $0.id == selectedID }) {
            let textScreenRect = CGRect(
                x: text.worldRect.origin.x * camera.scale + camera.offset.width,
                y: text.worldRect.origin.y * camera.scale + camera.offset.height,
                width: text.worldRect.width * camera.scale,
                height: text.worldRect.height * camera.scale
            )
            if let handle = hitTestHandleOnRect(screenPoint: screenPoint, screenRect: textScreenRect),
               handle != .topCenter && handle != .bottomCenter {
                return .singleTextItem(handle: handle, text: text)
            }
            return nil
        }
        // Solo frame selection resizes its boundary without changing descendants.
        if selection.selectedIDs.count == 1,
           let selectedID = selection.selectedIDs.first,
           frameIDs.contains(selectedID),
           let frame = placedFrames.first(where: { $0.id == selectedID }) {
            let frameScreenRect = CGRect(
                x: frame.worldRect.origin.x * camera.scale + camera.offset.width,
                y: frame.worldRect.origin.y * camera.scale + camera.offset.height,
                width: frame.worldRect.width * camera.scale,
                height: frame.worldRect.height * camera.scale
            )
            if let handle = hitTestHandleOnRect(screenPoint: screenPoint, screenRect: frameScreenRect) {
                return .group(handle: handle, bbox: frame.worldRect)
            }
            return nil
        }
        // (Mixed/pure-text multi-selections fall through to the group
        // path below — text scales uniformly with the bbox, same as
        // images. Single-text selections were already handled above.)
        if selection.selectedIDs.count == 1,
           let selectedID = selection.selectedIDs.first,
           !frameIDs.contains(selectedID),
           let item = visibleImages.first(where: { $0.id == selectedID }) {
            let itemScreenRect = CGRect(
                x: item.worldRect.origin.x * camera.scale + camera.offset.width,
                y: item.worldRect.origin.y * camera.scale + camera.offset.height,
                width: item.worldRect.width * camera.scale,
                height: item.worldRect.height * camera.scale
            )
            if let handle = hitTestHandleOnRect(screenPoint: screenPoint, screenRect: itemScreenRect) {
                return .singleItem(handle: handle, item: item)
            }
        } else if selection.selectedIDs.count > 1, let bbox = groupBoundingBox() {
            let bboxScreenRect = CGRect(
                x: bbox.origin.x * camera.scale + camera.offset.width,
                y: bbox.origin.y * camera.scale + camera.offset.height,
                width: bbox.width * camera.scale,
                height: bbox.height * camera.scale
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
        let selectedIDs = expandedElementIDs(for: selection.selectedIDs)
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
                x: item.worldRect.origin.x * camera.scale + camera.offset.width,
                y: item.worldRect.origin.y * camera.scale + camera.offset.height,
                width: item.worldRect.width * camera.scale,
                height: item.worldRect.height * camera.scale
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
            camera.offset = CGSize(
                width: start.width + value.translation.width,
                height: start.height + value.translation.height
            )
            scheduleRefreshVisibleElements()
        case .moveItem:
            let worldDX = value.translation.width / camera.scale
            let worldDY = value.translation.height / camera.scale
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
        minDimension: CGFloat? = nil,
        lockAspectRatio: Bool = true
    ) -> CGRect? {
        let worldDX = translation.width / camera.scale
        let worldDY = translation.height / camera.scale
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

            if lockAspectRatio {
                if rawW / max(aspect, 0.001) > rawH {
                    rawH = rawW / aspect
                } else {
                    rawW = rawH * aspect
                }
            }

            rawW = max(rawW, minDim)
            rawH = max(rawH, lockAspectRatio ? minDim / max(aspect, 0.001) : minDim)

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

        execute(.resize(elementID: elementID, fromRect: startRect, toRect: newRect))
        selection.clearResize()
    }

    // MARK: - Group Resize Logic

    /// World-space union of every currently selected item's rect. Returns nil
    /// if no items are selected. Unlike `groupBoundingBox()` this works for
    /// any non-empty selection (single or multi).
    private func selectionBoundingBox() -> CGRect? {
        var rects = placedImages.filter { selection.selectedIDs.contains($0.id) }.map(\.worldRect)
        rects.append(contentsOf: placedTexts.filter { selection.selectedIDs.contains($0.id) }.map(\.worldRect))
        rects.append(contentsOf: placedFrames.filter { selection.selectedIDs.contains($0.id) }.map(\.worldRect))
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    private func groupBoundingBox() -> CGRect? {
        guard selection.selectedIDs.count > 1 else { return nil }
        var rects = placedImages.filter { selection.selectedIDs.contains($0.id) }.map(\.worldRect)
        rects.append(contentsOf: placedTexts.filter { selection.selectedIDs.contains($0.id) }.map(\.worldRect))
        rects.append(contentsOf: placedFrames.filter { selection.selectedIDs.contains($0.id) }.map(\.worldRect))
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
              let newBBox = computeResizedRect(handle: handle, startRect: bboxStart, translation: translation, lockAspectRatio: selectedFrameID == nil) else { return }
        selection.groupResizeBBoxCurrent = newBBox

        // Only explicitly selected elements resize. A frame never scales its descendants.
        if let startRects = selection.groupResizeStartRects {
            for (id, originalRect) in startRects {
                let rect = scaledRect(original: originalRect, bboxStart: bboxStart, bboxCurrent: newBBox)
                if let idx = placedImages.firstIndex(where: { $0.id == id }) {
                    placedImages[idx].worldRect = rect
                }
                if let idx = visibleImages.firstIndex(where: { $0.id == id }) {
                    visibleImages[idx].worldRect = rect
                }
                if let idx = placedFrames.firstIndex(where: { $0.id == id }) {
                    placedFrames[idx].worldRect = rect
                }
            }
        }

        // Text uses a different render path (font size + frame), so mutate
        // its state directly and let onGeometryChange re-derive worldRect.size.
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

        execute(.groupResize(
            fromRects: startRects, toRects: toRects,
            fromTextStates: startTextStates, toTextStates: toTextStates
        ))
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
        // Rect-backed elements: images and frames. Text is handled via
        // `textStates` because its size is content-derived.
        let textIDs = Set(placedTexts.map(\.id))
        let rectBackedRects = rects.filter { !textIDs.contains($0.key) }

        for (id, rect) in rectBackedRects {
            if let idx = placedImages.firstIndex(where: { $0.id == id }) {
                placedImages[idx].worldRect = rect
            }
            if let idx = visibleImages.firstIndex(where: { $0.id == id }) {
                visibleImages[idx].worldRect = rect
            }
            if let idx = placedFrames.firstIndex(where: { $0.id == id }) {
                placedFrames[idx].worldRect = rect
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
        let rectBackedIDs = Array(rectBackedRects.keys)
        enqueueStoreMutation { store in
            var updated: [CMCanvasElement] = []
            updated.reserveCapacity(rectBackedIDs.count + textElements.count)

            // Images/frames: fetch authoritative elements, mutate bounds
            // and, for images, payload size.
            if !rectBackedIDs.isEmpty {
                let fetched = await store.elements(for: rectBackedIDs)
                for (id, rect) in rectBackedRects {
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
            let worldDX = translation.width / camera.scale
            let newWrap = max(minTextWrapWidth, baseWidth + worldDX)
            placedTexts[idx].wrapWidth = newWrap
            // Origin unchanged — left edge is anchor.
        } else if handle == .leftCenter {
            // Left edge drag → set wrap width AND shift origin so the right
            // edge stays anchored (Figma convention).
            let baseWidth = startWrapWidth ?? startRect.width
            let worldDX = translation.width / camera.scale
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

        // The live drag already mutated `placedTexts`; running the command
        // re-applies the same values and does the store upsert.
        execute(.resizeText(
            elementID: id,
            fromFontSize: startFontSize, toFontSize: toFontSize,
            fromWrapWidth: startWrapWidth, toWrapWidth: toWrapWidth,
            fromOrigin: startRect.origin, toOrigin: toOrigin
        ))
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
            let ids = Set(headers.filter { header in
                let bounds = header.bounds
                let worldRect = CGRect(x: bounds.origin.x, y: bounds.origin.y,
                                       width: bounds.size.x, height: bounds.size.y)
                // A frame is big and usually under whatever you're boxing,
                // so touching it isn't enough: the box must hold the whole
                // frame. Images and text only need to be touched.
                if header.type == .frame {
                    return rect.contains(worldRect)
                }
                return visibleWorldRect(id: header.id, rect: worldRect).intersects(rect)
            }.map { $0.id })
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
        execute(.move(
            elementIDs: idsToMove,
            delta: CGSize(width: dx, height: dy),
            memberships: dropMemberships(for: idsToMove, delta: CGSize(width: dx, height: dy))
        ))
    }

    /// Which frame a dragged selection lands in. The whole selection moves
    /// as one, so it gets one answer: the innermost frame under the finger
    /// where the drag ended (Figma's rule). Deciding per item split a
    /// selection that straddled a frame edge, with some items leaving the
    /// frame and others staying.
    ///
    /// Nil when there's no finger position (shouldn't happen for a drag),
    /// which falls back to `applyMoveDelta`'s per-item check.
    private func dropMemberships(for ids: Set<UUID>, delta: CGSize) -> [FrameMembership]? {
        guard let start = dragStartWorldPos else { return nil }
        let finger = CGPoint(x: start.x + delta.width, y: start.y + delta.height)
        // Frames being dragged can't receive the drop. Every other frame
        // stays put, so their current rects are where they'll be after.
        let target = FrameGeometry.dropTarget(
            at: finger, frames: placedFrames, excluding: expandedElementIDs(for: ids)
        )
        return selectionRoots(ids).map { FrameMembership(elementID: $0, parentID: target) }
    }

    // MARK: - Undo / Redo

    /// Run `command` on the board, then register its reverse so the user can
    /// undo it. Use this when the command *is* the edit.
    private func execute(_ command: CanvasCommand) {
        recordUndo(reverse: perform(command))
    }

    /// Register the *reverse* of an edit that other code has already applied
    /// (chunked image insertion, text commit, the color picker's first frame).
    /// Note the argument is the opposite of `execute`'s: you pass what undo
    /// should run, not what just happened.
    private func recordUndo(reverse: CanvasCommand) {
        commandHistory.registerUndo(reverse) { command in
            perform(command)
        }
    }

    /// Apply `command` to the board and hand back the command that reverses
    /// it. `UndoManager` runs this for undo *and* redo: undoing runs the
    /// stored command and registers what comes back as the redo.
    ///
    /// Every case but `.setTextColors` carries both sides, so the reverse is
    /// just the same case with from/to swapped. `.setTextColors` carries only
    /// the target colors (see its doc comment), so the reverse is read from
    /// the live board before the change lands.
    @discardableResult
    private func perform(_ command: CanvasCommand) -> CanvasCommand {
        // Land any in-flight color pick first, so an undo mid-drag reverses
        // it rather than racing the debounce.
        commitTextColorEdit()
        commitFrameFillEdit()
        switch command {
        case .move(let ids, let delta, let memberships):
            let previous = applyMoveDelta(
                elementIDs: ids, dx: delta.width, dy: delta.height, memberships: memberships
            )
            return .move(elementIDs: ids, delta: CGSize(width: -delta.width, height: -delta.height), memberships: previous)
        case .resize(let id, let fromRect, let toRect):
            applyResizeRect(elementID: id, rect: toRect)
            return .resize(elementID: id, fromRect: toRect, toRect: fromRect)
        case .groupResize(let fromRects, let toRects, let fromTextStates, let toTextStates):
            applyGroupResizeApply(rects: toRects, textStates: toTextStates)
            return .groupResize(
                fromRects: toRects, toRects: fromRects,
                fromTextStates: toTextStates, toTextStates: fromTextStates
            )
        case .insert(let snapshots):
            addElements(snapshots: snapshots)
            return .delete(snapshots: snapshots)
        case .delete(let snapshots):
            removeElements(snapshots: snapshots)
            return .insert(snapshots: snapshots)
        case .createFrame(let frameSnapshot, let beforeChildSnapshots, let afterChildSnapshots, let actionName):
            applyElementSnapshots(afterChildSnapshots)
            addElements(snapshots: [frameSnapshot])
            return .dissolveFrame(
                frameSnapshot: frameSnapshot,
                groupedChildSnapshots: afterChildSnapshots,
                ungroupedChildSnapshots: beforeChildSnapshots,
                actionName: actionName
            )
        case .dissolveFrame(let frameSnapshot, let groupedChildSnapshots, let ungroupedChildSnapshots, let actionName):
            removeElements(snapshots: [frameSnapshot])
            applyElementSnapshots(ungroupedChildSnapshots)
            return .createFrame(
                frameSnapshot: frameSnapshot,
                beforeChildSnapshots: ungroupedChildSnapshots,
                afterChildSnapshots: groupedChildSnapshots,
                actionName: actionName
            )
        case .editTextContent(let id, let fromContent, let toContent):
            applyTextContent(elementID: id, content: toContent)
            return .editTextContent(elementID: id, fromContent: toContent, toContent: fromContent)
        case .resizeText(let id, let fromFontSize, let toFontSize, let fromWrapWidth, let toWrapWidth, let fromOrigin, let toOrigin):
            applyTextResizeState(
                elementID: id,
                fontSize: toFontSize,
                wrapWidth: toWrapWidth,
                origin: toOrigin
            )
            return .resizeText(
                elementID: id,
                fromFontSize: toFontSize, toFontSize: fromFontSize,
                fromWrapWidth: toWrapWidth, toWrapWidth: fromWrapWidth,
                fromOrigin: toOrigin, toOrigin: fromOrigin
            )
        case .renameAsset(let id, let name):
            // A frame's name is its payload title, not a header label, so it
            // takes its own path. Same command either way, so frame renames
            // undo like image and text renames.
            if let index = placedFrames.firstIndex(where: { $0.id == id }) {
                let previous = placedFrames[index].title
                placedFrames[index].title = name ?? previous
                writeFramePayloads([placedFrames[index]])
                return .renameAsset(elementID: id, name: previous)
            }
            let previous = assetNames[id]
            assetNames[id] = name
            enqueueStoreMutation { store in
                guard var element = await store.elements(for: [id])[id] else { return }
                element.header.displayName = name
                await store.upsert(elements: [element])
            }
            return .renameAsset(elementID: id, name: previous)
        case .setTextColors(let hexes):
            let previous = placedTexts.reduce(into: [UUID: String]()) { acc, placed in
                if hexes[placed.id] != nil { acc[placed.id] = placed.colorHex }
            }
            applyTextColors(hexes)
            return .setTextColors(hexes: previous)
        case .setFrameFills(let fills):
            var previous: [UUID: String?] = [:]
            for frame in placedFrames where fills.keys.contains(frame.id) {
                previous[frame.id] = frame.fillHex
            }
            applyFrameFills(fills)
            return .setFrameFills(fills: previous)
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

    private func parentFrameID(for id: UUID) -> UUID? {
        placedImages.first(where: { $0.id == id })?.parentFrameID ??
        placedTexts.first(where: { $0.id == id })?.parentFrameID ??
        placedFrames.first(where: { $0.id == id })?.parentFrameID
    }

    private func applyMoveDelta(
        elementIDs: Set<UUID>, dx: CGFloat, dy: CGFloat,
        memberships: [FrameMembership]? = nil
    ) -> [FrameMembership] {
        let expandedIDs = expandedElementIDs(for: elementIDs)
        // Children travelling with a selected ancestor keep that relationship.
        let roots = selectionRoots(elementIDs)
        let previous = roots.map { FrameMembership(elementID: $0, parentID: parentFrameID(for: $0)) }
        for i in placedImages.indices where expandedIDs.contains(placedImages[i].id) {
            placedImages[i].worldRect.origin.x += dx
            placedImages[i].worldRect.origin.y += dy
        }
        for i in visibleImages.indices where expandedIDs.contains(visibleImages[i].id) {
            visibleImages[i].worldRect.origin.x += dx
            visibleImages[i].worldRect.origin.y += dy
        }
        for i in placedTexts.indices where expandedIDs.contains(placedTexts[i].id) {
            placedTexts[i].worldRect.origin.x += dx
            placedTexts[i].worldRect.origin.y += dy
        }
        for i in placedFrames.indices where expandedIDs.contains(placedFrames[i].id) {
            placedFrames[i].worldRect.origin.x += dx
            placedFrames[i].worldRect.origin.y += dy
        }
        let assignments = memberships ?? roots.compactMap { id -> FrameMembership? in
            let rect = placedImages.first(where: { $0.id == id })?.worldRect ??
                placedTexts.first(where: { $0.id == id })?.worldRect ??
                placedFrames.first(where: { $0.id == id })?.worldRect
            guard let rect else { return nil }
            return FrameMembership(elementID: id, parentID: FrameGeometry.dropTarget(
                at: CGPoint(x: rect.midX, y: rect.midY), frames: placedFrames, excluding: expandedIDs
            ))
        }
        for assignment in assignments {
            if let i = placedImages.firstIndex(where: { $0.id == assignment.elementID }) {
                placedImages[i].parentFrameID = assignment.parentID
            }
            if let i = visibleImages.firstIndex(where: { $0.id == assignment.elementID }) {
                visibleImages[i].parentFrameID = assignment.parentID
            }
            if let i = placedTexts.firstIndex(where: { $0.id == assignment.elementID }) {
                placedTexts[i].parentFrameID = assignment.parentID
            }
            if let i = placedFrames.firstIndex(where: { $0.id == assignment.elementID }) {
                placedFrames[i].parentFrameID = assignment.parentID
            }
        }
        enqueueStoreMutation { store in
            let fetched = await store.elements(for: Array(expandedIDs))
            let updated = fetched.values.map { stored in
                var element = stored
                element.header.bounds.origin.x += Double(dx)
                element.header.bounds.origin.y += Double(dy)
                if let assignment = assignments.first(where: { $0.elementID == element.id }) {
                    element.header.parentID = assignment.parentID
                }
                return element
            }
            await store.upsert(elements: updated)
        }
        return previous
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

    // MARK: - Frame Color

    /// Frames directly in the selection (not frames that are only selected
    /// because an ancestor is).
    private func selectedFramesForFill() -> [PlacedFrame] {
        placedFrames.filter { selection.selectedIDs.contains($0.id) }
    }

    /// Fill to show in the action bar's frame color well, or nil when no
    /// frame is selected (which hides it). Unpicked frames report the
    /// canvas-derived default, since that's what's on screen.
    private func selectionFrameFillHex() -> String? {
        guard let frame = selectedFramesForFill().first else { return nil }
        return frame.fillHex ?? FrameFill.defaultHex(onCanvas: canvasColor.resolve(in: environment))
    }

    /// Paint every selected frame with `hex`. Works like `applyTextColor`:
    /// the canvas updates on every picker frame, one undo step is registered
    /// on the first real change, and the store write waits until picking
    /// stops.
    private func applyFrameFill(hex: String) {
        let targets = selectedFramesForFill()
        guard !targets.isEmpty else { return }

        if frameFillEditOriginals == nil {
            guard targets.contains(where: { $0.fillHex != hex }) else { return }
            var originals: [UUID: String?] = [:]
            for frame in targets { originals[frame.id] = frame.fillHex }
            frameFillEditOriginals = originals
            recordUndo(reverse: .setFrameFills(fills: originals))
        }

        let ids = Set(targets.map(\.id))
        for idx in placedFrames.indices where ids.contains(placedFrames[idx].id) {
            placedFrames[idx].fillHex = hex
        }

        frameFillCommitTask?.cancel()
        frameFillCommitTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            commitFrameFillEdit()
        }
    }

    /// Close out a frame color edit by writing the changed frames to the
    /// store. The undo step was already registered by `applyFrameFill`.
    private func commitFrameFillEdit() {
        frameFillCommitTask?.cancel()
        frameFillCommitTask = nil
        guard let originals = frameFillEditOriginals else { return }
        frameFillEditOriginals = nil

        let changed = placedFrames.filter { frame in
            guard let original = originals[frame.id] else { return false }
            return original != frame.fillHex
        }
        guard !changed.isEmpty else { return }
        writeFramePayloads(changed)
    }

    /// Set per-frame fills (used by undo/redo of `.setFrameFills`).
    private func applyFrameFills(_ fills: [UUID: String?]) {
        var touched: [PlacedFrame] = []
        for idx in placedFrames.indices {
            guard let fill = fills[placedFrames[idx].id] else { continue }
            placedFrames[idx].fillHex = fill
            touched.append(placedFrames[idx])
        }
        guard !touched.isEmpty else { return }
        writeFramePayloads(touched)
    }

    /// Save each frame's title and fill to the store, leaving the rest of
    /// its stored record alone.
    ///
    /// The canvas's copy of a frame doesn't track everything the store
    /// does. Its `zIndex`, for one, goes stale when a tap or drag raises the
    /// frame in the store (`moveToTop`). Rebuilding the whole record from
    /// the canvas copy would undo that. So this fetches the stored element
    /// and swaps only the payload, falling back to a rebuilt element only
    /// if the store has no record of the frame.
    private func writeFramePayloads(_ frames: [PlacedFrame]) {
        let payloads = Dictionary(uniqueKeysWithValues: frames.map {
            ($0.id, CMCanvasElementPayload.frame(title: $0.title, fillColor: $0.fillHex))
        })
        let fallbacks = Dictionary(uniqueKeysWithValues: frames.map { ($0.id, fallbackFrameElement(for: $0)) })
        enqueueStoreMutation { store in
            let stored = await store.elements(for: Array(payloads.keys))
            let updated = payloads.compactMap { id, payload -> CMCanvasElement? in
                guard var element = stored[id] else { return fallbacks[id] }
                element.payload = payload
                return element
            }
            await store.upsert(elements: updated)
        }
    }

    // MARK: - Text Color

    /// Text elements in the current selection, in `placedTexts` order.
    private func selectedTexts() -> [PlacedText] {
        placedTexts.filter { selection.selectedIDs.contains($0.id) }
    }

    /// Color to show in the action bar's color controls, or nil when the
    /// selection holds no text (which hides them). A mixed-color multi-select
    /// reports the first element's color — the picker paints uniformly, so
    /// there's nothing better to show, and the swap is what the user asked for.
    private func selectionTextColorHex() -> String? {
        selectedTexts().first?.colorHex
    }

    /// Apply `hex` to every selected text element, registering one undo step
    /// for the whole picker session.
    ///
    /// Called straight from the picker binding, so it can fire many times a
    /// second while the user drags in the system color picker. The canvas
    /// updates live on every call (that's the point — you want to see the
    /// color you're scrubbing through), but the store write is deferred to
    /// `commitTextColorEdit` once the picking stops.
    ///
    /// The undo step is registered on the first frame that actually changes
    /// a color, not at commit. A three-finger swipe can arrive during the
    /// 400 ms debounce and go straight to `UndoManager` without passing
    /// through our code, so the step has to already be there. Undo only
    /// needs the originals, which we have on frame one; the redo side is
    /// read from the live board at undo time (see `perform(_:)`).
    private func applyTextColor(hex: String) {
        let targets = selectedTexts()
        guard !targets.isEmpty else { return }

        // Capture the pre-edit colors on the first call of an edit only, so a
        // whole picker session undoes back to where it started rather than to
        // the previous frame's color.
        if textColorEditOriginals == nil {
            // Opening the picker can publish the color that's already
            // applied. Don't start a session (or burn an undo step) for that.
            // (Scrubbing away and back to the original before the debounce
            // lands still leaves a no-op step — `UndoManager` can't pop one
            // entry selectively. Rare enough to live with.)
            guard targets.contains(where: { $0.colorHex != hex }) else { return }
            let originals = Dictionary(
                uniqueKeysWithValues: targets.map { ($0.id, $0.colorHex) }
            )
            textColorEditOriginals = originals
            recordUndo(reverse: .setTextColors(hexes: originals))
        }

        let ids = Set(targets.map(\.id))
        for idx in placedTexts.indices where ids.contains(placedTexts[idx].id) {
            placedTexts[idx].colorHex = hex
        }

        textColorCommitTask?.cancel()
        textColorCommitTask = Task { @MainActor in
            // Long enough to swallow a continuous spectrum drag, short enough
            // that a deliberate second pick reads as its own undo step.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            commitTextColorEdit()
        }
    }

    /// Close out a color edit: record the color as most-recently-used and
    /// sync the affected elements to the store. No-ops when nothing actually
    /// changed (e.g. the user re-picked the color already applied). The undo
    /// step was already registered by `applyTextColor`.
    private func commitTextColorEdit() {
        textColorCommitTask?.cancel()
        textColorCommitTask = nil
        guard let originals = textColorEditOriginals else { return }
        textColorEditOriginals = nil

        let changed = placedTexts.filter { placed in
            guard let original = originals[placed.id] else { return false }
            return original != placed.colorHex
        }
        guard let toHex = changed.first?.colorHex else { return }

        lastTextColorHex = TextColorMemory.recording(toHex, into: lastTextColorHex)

        let elements = changed.map(fallbackTextElement(for:))
        enqueueStoreMutation { store in
            await store.upsert(elements: elements)
        }
    }

    /// Restore per-element text colors (used by undo/redo of `.setTextColors`).
    /// Takes a hex per element because undo of a mixed-color selection has to
    /// put each element back to its own original.
    private func applyTextColors(_ hexes: [UUID: String]) {
        var touched: [PlacedText] = []
        for idx in placedTexts.indices {
            guard let hex = hexes[placedTexts[idx].id] else { continue }
            placedTexts[idx].colorHex = hex
            touched.append(placedTexts[idx])
        }
        guard !touched.isEmpty else { return }

        let elements = touched.map(fallbackTextElement(for:))
        enqueueStoreMutation { store in
            await store.upsert(elements: elements)
        }
    }

    private func applyElementSnapshots(_ snapshots: [PlacedElementSnapshot]) {
        guard !snapshots.isEmpty else { return }

        for snap in snapshots {
            assetNames[snap.id] = snap.element.header.displayName
            switch snap.element.payload {
            case .image:
                if let index = placedImages.firstIndex(where: { $0.id == snap.id }),
                   let url = snap.url {
                    placedImages[index] = PlacedImage(
                        id: snap.id,
                        url: url,
                        worldRect: snap.worldRect,
                        zIndex: snap.zIndex,
                        parentFrameID: snap.element.header.parentID
                    )
                }
                if let index = visibleImages.firstIndex(where: { $0.id == snap.id }),
                   let url = snap.url {
                    visibleImages[index] = PlacedImage(
                        id: snap.id,
                        url: url,
                        worldRect: snap.worldRect,
                        zIndex: snap.zIndex,
                        parentFrameID: snap.element.header.parentID
                    )
                }
            case .text(let content, _, let fontSize, let colorHex, let wrapWidth):
                if let index = placedTexts.firstIndex(where: { $0.id == snap.id }) {
                    placedTexts[index] = PlacedText(
                        id: snap.id,
                        content: content,
                        worldRect: snap.worldRect,
                        zIndex: snap.zIndex,
                        fontSize: CGFloat(fontSize),
                        colorHex: colorHex,
                        wrapWidth: wrapWidth.map { CGFloat($0) },
                        parentFrameID: snap.element.header.parentID
                    )
                }
            case .frame(let title, let fillColor):
                if let index = placedFrames.firstIndex(where: { $0.id == snap.id }) {
                    placedFrames[index] = PlacedFrame(
                        id: snap.id,
                        title: title,
                        worldRect: snap.worldRect,
                        zIndex: snap.zIndex,
                        parentFrameID: snap.element.header.parentID,
                        fillHex: fillColor
                    )
                }
            default:
                break
            }
            nextZIndex = max(nextZIndex, snap.zIndex + 1)
        }

        let elements = snapshots.map(\.element)
        enqueueStoreMutation { store in
            await store.upsert(elements: elements)
        }
    }

    private func addElements(snapshots: [PlacedElementSnapshot]) {
        for snap in snapshots {
            assetNames[snap.id] = snap.element.header.displayName
            switch snap.element.payload {
            case .image:
                if let url = snap.url {
                    placedImages.append(PlacedImage(
                        id: snap.id, url: url,
                        worldRect: snap.worldRect, zIndex: snap.zIndex,
                        parentFrameID: snap.element.header.parentID
                    ))
                }
            case .text(let content, _, let fontSize, let colorHex, let wrapWidth):
                placedTexts.append(PlacedText(
                    id: snap.id,
                    content: content,
                    worldRect: snap.worldRect,
                    zIndex: snap.zIndex,
                    fontSize: CGFloat(fontSize),
                    colorHex: colorHex,
                    wrapWidth: wrapWidth.map { CGFloat($0) },
                    parentFrameID: snap.element.header.parentID
                ))
            case .frame(let title, let fillColor):
                placedFrames.append(PlacedFrame(
                    id: snap.id,
                    title: title,
                    worldRect: snap.worldRect,
                    zIndex: snap.zIndex,
                    parentFrameID: snap.element.header.parentID,
                    fillHex: fillColor
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
        // Land any color pick still in its debounce window first, then wait
        // for queued store writes below. The snapshots are read from the
        // store, and undo restores exactly what they captured.
        commitTextColorEdit()
        commitFrameFillEdit()
        let targetIDs = expandedElementIDs(for: selection.selectedIDs)
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
        let framesByID: [UUID: PlacedFrame] = Dictionary(
            uniqueKeysWithValues: placedFrames
                .filter { targetIDs.contains($0.id) }
                .map { ($0.id, $0) }
        )
        guard !imagesByID.isEmpty || !textsByID.isEmpty || !framesByID.isEmpty else { return }

        let store = canvasStore
        let allIDs = Array(imagesByID.keys) + Array(textsByID.keys) + Array(framesByID.keys)
        let pendingMutation = storeMutationTask
        Task { @MainActor in
            _ = await pendingMutation?.result
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

            for (id, placed) in framesByID {
                let authElement = elementsByID[id]
                let element = authElement ?? fallbackFrameElement(for: placed)
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

            execute(.delete(snapshots: snapshots))
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
            zIndex: placed.zIndex,
            parentID: placed.parentFrameID,
            displayName: assetNames[placed.id]
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
            zIndex: placed.zIndex,
            parentID: placed.parentFrameID,
            displayName: assetNames[placed.id]
        )
        let payload = CMCanvasElementPayload.text(
            content: placed.content,
            fontName: defaultTextFontName,
            fontSize: Double(placed.fontSize),
            color: placed.colorHex,
            wrapWidth: placed.wrapWidth.map { Double($0) }
        )
        return CMCanvasElement(header: header, payload: payload)
    }

    private func fallbackFrameElement(for placed: PlacedFrame) -> CMCanvasElement {
        let rect = placed.worldRect
        let header = CMElementHeader(
            id: placed.id,
            type: .frame,
            transform: CMAffineTransform2D(),
            bounds: CMWorldRect(
                origin: SIMD2<Double>(Double(rect.origin.x), Double(rect.origin.y)),
                size: SIMD2<Double>(Double(rect.size.width), Double(rect.size.height))
            ),
            layerId: UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID(),
            zIndex: placed.zIndex,
            parentID: placed.parentFrameID,
            displayName: assetNames[placed.id]
        )
        return CMCanvasElement(header: header, payload: .frame(title: placed.title, fillColor: placed.fillHex))
    }

    private func snapshot(for placed: PlacedImage) -> PlacedElementSnapshot {
        PlacedElementSnapshot(
            id: placed.id,
            url: placed.url,
            worldRect: placed.worldRect,
            zIndex: placed.zIndex,
            element: fallbackImageElement(for: placed)
        )
    }

    private func snapshot(for placed: PlacedText) -> PlacedElementSnapshot {
        PlacedElementSnapshot(
            id: placed.id,
            url: nil,
            worldRect: placed.worldRect,
            zIndex: placed.zIndex,
            element: fallbackTextElement(for: placed)
        )
    }

    private func snapshot(for placed: PlacedFrame) -> PlacedElementSnapshot {
        PlacedElementSnapshot(
            id: placed.id,
            url: nil,
            worldRect: placed.worldRect,
            zIndex: placed.zIndex,
            element: fallbackFrameElement(for: placed)
        )
    }

    private func removeElements(snapshots: [PlacedElementSnapshot]) {
        let idsToRemove = Set(snapshots.map { $0.id })
        for id in idsToRemove { assetNames[id] = nil }
        placedImages.removeAll { idsToRemove.contains($0.id) }
        visibleImages.removeAll { idsToRemove.contains($0.id) }
        placedTexts.removeAll { idsToRemove.contains($0.id) }
        placedFrames.removeAll { idsToRemove.contains($0.id) }
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
        assetNames = Dictionary(uniqueKeysWithValues: elements.compactMap { element in
            element.header.displayName.map { (element.id, $0) }
        })
        placedImages.removeAll()
        placedTexts.removeAll()
        placedFrames.removeAll()
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
                placedImages.append(PlacedImage(id: el.id, url: url, worldRect: rect, zIndex: z, parentFrameID: el.header.parentID))
                nextZIndex = max(nextZIndex, z + 1)
            case .text(let content, _, let fontSize, let colorHex, let wrapWidth):
                placedTexts.append(PlacedText(
                    id: el.id,
                    content: content,
                    worldRect: rect,
                    zIndex: z,
                    fontSize: CGFloat(fontSize),
                    colorHex: colorHex,
                    wrapWidth: wrapWidth.map { CGFloat($0) },
                    parentFrameID: el.header.parentID
                ))
                nextZIndex = max(nextZIndex, z + 1)
            case .frame(let title, let fillColor):
                placedFrames.append(PlacedFrame(
                    id: el.id,
                    title: title,
                    worldRect: rect,
                    zIndex: z,
                    parentFrameID: el.header.parentID,
                    fillHex: fillColor
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
        let s = Double(camera.scale)
        let off = camera.offset
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
            try? await Task.sleep(for: isInteracting ? .milliseconds(80) : .milliseconds(40))
            await refreshVisibleElements()
        }
    }

    private func visibleQueryMargin() -> Double {
        let zoomAwareMargin = Double(256 * max(camera.scale, 0.25))
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
            return PlacedImage(id: placement.id, url: placement.url, worldRect: rect, zIndex: placement.zIndex, parentFrameID: nil)
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
        CGPoint(x: (p.x - camera.offset.width) / camera.scale,
                y: (p.y - camera.offset.height) / camera.scale)
    }

    private func screenPosition(for rect: CGRect, dx: CGFloat, dy: CGFloat) -> CGPoint {
        CGPoint(
            x: (rect.midX * camera.scale) + camera.offset.width + dx,
            y: (rect.midY * camera.scale) + camera.offset.height + dy
        )
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

        // Insertion below is chunked, so it can't go through `execute`;
        // register the reverse by hand.
        recordUndo(reverse: .delete(snapshots: snapshots))
        nextZIndex += snapshots.count

        let chunks = snapshots.chunked(into: insertionChunkSize)
        for (chunkIndex, chunk) in chunks.enumerated() {
            guard !Task.isCancelled else { break }

            placedImages.append(contentsOf: chunk.map {
                PlacedImage(id: $0.id, url: $0.url!, worldRect: $0.worldRect, zIndex: $0.zIndex, parentFrameID: nil)
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
        guard camera.scale > 0, canvasSize != .zero else { return .zero }
        let worldMinX = (-camera.offset.width) / camera.scale
        let worldMinY = (-camera.offset.height) / camera.scale
        return CGRect(x: worldMinX, y: worldMinY,
                      width: canvasSize.width / camera.scale,
                      height: canvasSize.height / camera.scale)
    }

    /// World-space rects for every element (images, texts, frames) on the canvas.
    private func allElementRects() -> [CGRect] {
        var rects = placedImages.map(\.worldRect)
        rects.append(contentsOf: placedTexts.map(\.worldRect))
        rects.append(contentsOf: placedFrames.map(\.worldRect))
        return rects
    }

    /// Screen-space margin left around content when fitting, per edge. Keeps
    /// the outermost elements clear of the toolbar and the screen edges rather
    /// than flush against them.
    private var fitPadding: CGFloat { 64 }

    /// Zoom that fits `bounds` (world space) inside the current canvas with
    /// `fitPadding` on every edge, clamped to the canvas zoom range.
    ///
    /// Capped at 1.0 so fitting only ever zooms *out*: a board holding one
    /// small image would otherwise be magnified past its native size on every
    /// home press, which just blurs the reference art.
    private func fitScale(for bounds: CGRect) -> CGFloat {
        let available = CGSize(
            width: max(canvasSize.width - fitPadding * 2, 1),
            height: max(canvasSize.height - fitPadding * 2, 1)
        )
        // A degenerate extent on one axis (zero-width/height rect) must not
        // divide; fall back to the other axis, and to the current scale when
        // both are degenerate.
        var candidates: [CGFloat] = []
        if bounds.width > 0 { candidates.append(available.width / bounds.width) }
        if bounds.height > 0 { candidates.append(available.height / bounds.height) }
        guard let fit = candidates.min() else { return camera.scale }
        return clamp(min(fit, 1.0), minScale, maxScale)
    }

    /// Fit every element on the canvas into the viewport, centered. Pass
    /// `animated: false` for instant repositioning (e.g. on board load);
    /// `true` for the home button's eased zoom-and-pan.
    private func zoomToFitContent(animated: Bool = true) {
        guard let bounds = union(of: allElementRects()) else { return }
        zoomCamera(toFit: bounds, animated: animated)
    }

    /// Center `bounds` (world space) in the viewport at the zoom that fits
    /// it. Shared by the home button and the outliner's jump-to-item.
    private func zoomCamera(toFit bounds: CGRect, animated: Bool = true) {
        guard canvasSize != .zero, camera.scale > 0 else { return }
        let targetScale = fitScale(for: bounds)
        // Offset must be derived from the *target* scale, not the current one,
        // or the content lands off-center by the zoom delta.
        let target = CGSize(
            width: canvasSize.width / 2 - bounds.midX * targetScale,
            height: canvasSize.height / 2 - bounds.midY * targetScale
        )
        if animated && !reduceMotion {
            withAnimation(.easeInOut(duration: 0.4)) {
                camera.scale = targetScale
                camera.offset = target
            } completion: {
                scheduleRefreshVisibleElements()
            }
        } else {
            camera.scale = targetScale
            camera.offset = target
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
            // New text picks up the last color the user chose, so setting a
            // color once carries forward instead of having to be re-picked
            // for every element. Before anything has been picked, it starts
            // in whichever of near-black / white the canvas can actually show.
            colorHex: TextColorMemory.currentHex(
                lastTextColorHex,
                onCanvas: canvasColor.resolve(in: environment)
            )
        )
        placedTexts.append(text)
        nextZIndex += 1
        pendingTextInserts.insert(id)
        selection.clearSelection()
        editingTextID = id
        // Auto-swap back to the default tool so the next canvas tap doesn't
        // try to place yet another draft on top of the one we just created.
        // The skip flag stops the activeTool onChange from committing the
        // new draft we're still editing.
        skipNextToolChangeCommit = true
        activeTool = .group
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
            recordUndo(reverse: .insert(snapshots: [snapshot]))
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
            recordUndo(reverse: .delete(snapshots: [snapshot]))
        } else if let originalContent, originalContent != placed.content {
            // Re-edit produced a real content change — undo puts the
            // original content back.
            recordUndo(reverse: .editTextContent(
                elementID: id,
                fromContent: placed.content,
                toContent: originalContent
            ))
        }
        // Always upsert — covers both new placements and re-edit content
        // changes (history-tracked or not).
        enqueueStoreMutation { store in
            await store.upsert(elements: [element])
        }
    }

    private func selectionContainsFrame() -> Bool {
        let frameIDs = Set(placedFrames.map(\.id))
        return !selection.selectedIDs.isDisjoint(with: frameIDs)
    }

    private func selectionRoots(_ ids: Set<UUID>) -> Set<UUID> {
        let parents = Dictionary(uniqueKeysWithValues: ids.compactMap { id in
            parentFrameID(for: id).map { (id, $0) }
        })
        return FrameGeometry.selectionRoots(ids, parents: parents, frames: placedFrames)
    }

    private func expandedElementIDs(for ids: Set<UUID>) -> Set<UUID> {
        let frameLookup = Dictionary(uniqueKeysWithValues: placedFrames.map { ($0.id, $0) })
        guard !frameLookup.isEmpty else { return ids }

        var expanded = ids
        var queue = Array(ids)
        while let nextID = queue.popLast() {
            guard frameLookup[nextID] != nil else { continue }
            let childIDs = directChildIDs(of: nextID)
            for childID in childIDs where expanded.insert(childID).inserted {
                queue.append(childID)
            }
        }
        return expanded
    }

    private func directChildIDs(of frameID: UUID) -> [UUID] {
        var ids: [UUID] = placedFrames.filter { $0.parentFrameID == frameID }.map(\.id)
        ids.append(contentsOf: placedImages.filter { $0.parentFrameID == frameID }.map(\.id))
        ids.append(contentsOf: placedTexts.filter { $0.parentFrameID == frameID }.map(\.id))
        return ids
    }

    private func canCreateFrameFromSelection() -> Bool {
        selection.selectedIDs.count >= 1
    }

    private func createFrameFromSelection() {
        let selectedIDs = selectionRoots(selection.selectedIDs)
        guard !selectedIDs.isEmpty else { return }

        var rects: [CGRect] = []
        rects.append(contentsOf: placedImages.filter { selectedIDs.contains($0.id) }.map(\.worldRect))
        rects.append(contentsOf: placedTexts.filter { selectedIDs.contains($0.id) }.map(\.worldRect))
        rects.append(contentsOf: placedFrames.filter { selectedIDs.contains($0.id) }.map(\.worldRect))
        guard let contentBounds = union(of: rects) else { return }

        let selectedFrames = placedFrames.filter { selectedIDs.contains($0.id) }
        let selectedImages = placedImages.filter { selectedIDs.contains($0.id) }
        let selectedTexts = placedTexts.filter { selectedIDs.contains($0.id) }
        let beforeChildSnapshots =
            selectedImages.map(snapshot(for:)) +
            selectedTexts.map(snapshot(for:)) +
            selectedFrames.map(snapshot(for:))
        let parentCandidates = Set(
            selectedFrames.map(\.parentFrameID) +
            selectedImages.map(\.parentFrameID) +
            selectedTexts.map(\.parentFrameID)
        )
        // If everything selected sits in the same frame, the new frame goes
        // inside that frame too, so grouping items within a frame nests
        // instead of pulling them out. A mixed selection lands at top level.
        let commonParentFrameID = parentCandidates.count == 1 ? parentCandidates.first ?? nil : nil
        let parentFrameID = commonParentFrameID.flatMap { parentID in
            placedFrames.contains(where: { $0.id == parentID }) ? parentID : nil
        }

        let frameRect = contentBounds.insetBy(dx: -defaultFramePadding, dy: -defaultFramePadding)
        let minSelectedZ = rects.isEmpty
            ? nextZIndex
            : (
                selectedFrames.map(\.zIndex) +
                selectedImages.map(\.zIndex) +
                selectedTexts.map(\.zIndex)
            ).min() ?? nextZIndex
        let frame = PlacedFrame(
            id: UUID(),
            title: "Frame \(placedFrames.count + 1)",
            worldRect: frameRect,
            zIndex: minSelectedZ - 1,
            parentFrameID: parentFrameID
        )

        placedFrames.append(frame)
        for index in placedFrames.indices where selectedIDs.contains(placedFrames[index].id) {
            placedFrames[index].parentFrameID = frame.id
        }
        for index in placedImages.indices where selectedIDs.contains(placedImages[index].id) {
            placedImages[index].parentFrameID = frame.id
        }
        for index in placedTexts.indices where selectedIDs.contains(placedTexts[index].id) {
            placedTexts[index].parentFrameID = frame.id
        }

        let frameElement = fallbackFrameElement(for: frame)
        let frameSnapshot = snapshot(for: frame)
        let afterChildSnapshots =
            placedImages.filter { selectedIDs.contains($0.id) }.map(snapshot(for:)) +
            placedTexts.filter { selectedIDs.contains($0.id) }.map(snapshot(for:)) +
            placedFrames.filter { selectedIDs.contains($0.id) }.map(snapshot(for:))
        selection.selectedIDs = [frame.id]
        nextZIndex = max(nextZIndex, frame.zIndex + 1)
        recordUndo(reverse: .dissolveFrame(
            frameSnapshot: frameSnapshot,
            groupedChildSnapshots: afterChildSnapshots,
            ungroupedChildSnapshots: beforeChildSnapshots
        ))

        enqueueStoreMutation { store in
            var updates = afterChildSnapshots.map(\.element)
            updates.append(frameElement)
            await store.upsert(elements: updates)
        }
    }

    private func selectAssetFromOutliner(_ id: UUID) {
        selection.select(id)
    }

    /// Select an item from the outliner and move the camera to it, the way
    /// the home button does for the whole board.
    private func focusAssetFromOutliner(_ id: UUID) {
        selection.select(id)
        let rect = placedImages.first(where: { $0.id == id })?.worldRect
            ?? placedTexts.first(where: { $0.id == id })?.worldRect
            ?? placedFrames.first(where: { $0.id == id })?.worldRect
        guard let rect else { return }
        zoomCamera(toFit: rect)
    }

    private var selectedFrameID: UUID? {
        guard selection.selectedIDs.count == 1, let id = selection.selectedIDs.first,
              placedFrames.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    private func removeSelectedFrame() {
        guard let id = selectedFrameID, let frame = placedFrames.first(where: { $0.id == id }) else { return }
        let childIDs = Set(directChildIDs(of: id))
        let children = placedImages.filter { childIDs.contains($0.id) }.map(snapshot(for:)) +
            placedTexts.filter { childIDs.contains($0.id) }.map(snapshot(for:)) +
            placedFrames.filter { childIDs.contains($0.id) }.map(snapshot(for:))
        let released = children.map { child in
            var element = child.element
            element.header.parentID = frame.parentFrameID
            return PlacedElementSnapshot(id: child.id, url: child.url, worldRect: child.worldRect,
                                         zIndex: child.zIndex, element: element)
        }
        execute(.dissolveFrame(frameSnapshot: snapshot(for: frame),
                               groupedChildSnapshots: children, ungroupedChildSnapshots: released,
                               actionName: "Remove Frame"))
        selection.selectedIDs = childIDs
    }

    private func renameAsset(id: UUID, title: String) {
        let current = placedFrames.first(where: { $0.id == id })?.title ?? assetNames[id]
        guard current != title else { return }
        execute(.renameAsset(elementID: id, name: title))
    }

    private func handleItemTap(_ id: UUID, refreshAfterSelection: Bool) {
        let behavior = toolBehavior(for: activeTool)
        let shouldRaise = behavior.tappedItem(
            id: id, extending: keyModifiers.isShiftDown, selection: selection
        )
        if shouldRaise {
            raiseToTop([id])
        } else if refreshAfterSelection {
            Task { await refreshVisibleElements() }
        }
    }

    /// Bring `ids` to the front, each together with everything inside it.
    ///
    /// Two things went wrong when this was just `store.moveToTop(ids)`:
    /// - A raised frame went above its own contents in the store. Frames are
    ///   opaque, so after a save and reopen the frame covered its children.
    /// - Only the store changed. The canvas's copies kept their old
    ///   `zIndex`, and any later write built from them (frame create, undo)
    ///   put the old stacking order back.
    ///
    /// So the new order is worked out here, a frame first and then its
    /// contents, and written to both the canvas and the store. Ancestors and
    /// siblings keep their relative order. The store write goes through
    /// `enqueueStoreMutation` so it can't interleave with other writes.
    private func raiseToTop(_ ids: Set<UUID>) {
        var zByID: [UUID: Int] = [:]
        for image in placedImages { zByID[image.id] = image.zIndex }
        for text in placedTexts { zByID[text.id] = text.zIndex }
        for frame in placedFrames { zByID[frame.id] = frame.zIndex }
        func byZ(_ a: UUID, _ b: UUID) -> Bool { (zByID[a] ?? 0) < (zByID[b] ?? 0) }

        var order: [UUID] = []
        func visit(_ id: UUID) {
            order.append(id)
            for child in directChildIDs(of: id).sorted(by: byZ) { visit(child) }
        }
        for root in selectionRoots(ids).sorted(by: byZ) { visit(root) }
        guard !order.isEmpty else { return }

        var newZ: [UUID: Int] = [:]
        for (offset, id) in order.enumerated() { newZ[id] = nextZIndex + offset }
        nextZIndex += order.count

        for i in placedImages.indices { if let z = newZ[placedImages[i].id] { placedImages[i].zIndex = z } }
        for i in visibleImages.indices { if let z = newZ[visibleImages[i].id] { visibleImages[i].zIndex = z } }
        for i in placedTexts.indices { if let z = newZ[placedTexts[i].id] { placedTexts[i].zIndex = z } }
        for i in placedFrames.indices { if let z = newZ[placedFrames[i].id] { placedFrames[i].zIndex = z } }

        enqueueStoreMutation { store in
            let stored = await store.elements(for: Array(newZ.keys))
            let updated = stored.values.map { element -> CMCanvasElement in
                var element = element
                element.header.zIndex = newZ[element.id] ?? element.header.zIndex
                return element
            }
            await store.upsert(elements: updated)
        }
    }

    private func handleTextTap(_ id: UUID, currentContent: String, isOnlySelected: Bool) {
        if isOnlySelected {
            selection.clearSelection()
            editingTextOriginalContent = currentContent
            editingTextID = id
            return
        }
        handleItemTap(id, refreshAfterSelection: false)
    }

    /// Rebuild the outliner tree shortly after the board's contents change.
    /// Several changes in a row (an undo touching images and frames, every
    /// frame of a live resize) collapse into one rebuild.
    private func scheduleOutlineRebuild() {
        outlineRebuildTask?.cancel()
        outlineRebuildTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            outliner.nodes = assetOutlineNodes()
        }
    }

    private func assetOutlineNodes() -> [AssetOutlineNode] {
        // Looked up once per sort comparison, so build it once up front
        // rather than scanning all three arrays every time.
        var zIndexByID: [UUID: Int] = [:]
        for image in placedImages { zIndexByID[image.id] = image.zIndex }
        for text in placedTexts { zIndexByID[text.id] = text.zIndex }
        for frame in placedFrames { zIndexByID[frame.id] = frame.zIndex }

        let framesByParent = Dictionary(grouping: placedFrames, by: \.parentFrameID)
        let imagesByParent = Dictionary(grouping: placedImages, by: \.parentFrameID)
        let textsByParent = Dictionary(grouping: placedTexts, by: \.parentFrameID)

        func nodes(parentID: UUID?) -> [AssetOutlineNode] {
            var frameNodes = (framesByParent[parentID] ?? []).map { frame in
                AssetOutlineNode(
                    id: frame.id,
                    title: frame.title,
                    subtitle: frame.worldRect.debugSizeLabel,
                    kind: .frame,
                    children: nodes(parentID: frame.id)
                )
            }

            let imageNodes = (imagesByParent[parentID] ?? []).map { image in
                AssetOutlineNode(
                    id: image.id,
                    title: assetNames[image.id] ?? image.url.deletingPathExtension().lastPathComponent,
                    subtitle: image.worldRect.debugSizeLabel,
                    kind: .image,
                    children: []
                )
            }

            let textNodes = (textsByParent[parentID] ?? []).map { text in
                AssetOutlineNode(
                    id: text.id,
                    title: assetNames[text.id] ?? (text.content.isEmpty ? "Text" : text.content),
                    subtitle: text.worldRect.debugSizeLabel,
                    kind: .text,
                    children: []
                )
            }

            frameNodes.append(contentsOf: imageNodes)
            frameNodes.append(contentsOf: textNodes)
            return frameNodes.sorted { lhs, rhs in
                if lhs.kind != rhs.kind {
                    return outlineRank(for: lhs.kind) < outlineRank(for: rhs.kind)
                }
                return (zIndexByID[lhs.id] ?? .min) > (zIndexByID[rhs.id] ?? .min)
            }
        }

        return nodes(parentID: nil)
    }

    private func outlineRank(for kind: AssetOutlineNode.Kind) -> Int {
        switch kind {
        case .frame:
            return 0
        case .image:
            return 1
        case .text:
            return 2
        }
    }

    // MARK: - Models

    private struct ImageRenderPlan {
        let detailItems: [PlacedImage]
        let overviewItems: [PlacedImage]
    }
}

#Preview {
    BoardCanvasView(commandHistory: CanvasCommandHistory(), outliner: AssetOutlinerModel())
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

private extension CGRect {
    var debugSizeLabel: String {
        "\(Int(width.rounded())) × \(Int(height.rounded()))"
    }
}
