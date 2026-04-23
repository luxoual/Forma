# Frontend Architecture Documentation (Dev A)

⚠️ This document is maintained by **Dev A (Frontend/Canvas)**.

The purpose of this file is to document **UI, canvas interaction, and visual component architecture** as they become stable during development.

This file should reflect the **actual implemented system**, not speculative designs.

---

# Current Status

Frontend architecture is **actively developing** with core canvas and UI systems implemented.

---

# System Areas

## Infinite Canvas System

Decision Status: **Implemented (MVP)**

### Core Architecture

**File:** `BoardCanvasView.swift`

The canvas system is implemented as a standalone, reusable SwiftUI component that provides pan/zoom navigation and image placement on an infinite 2D plane.

**World Coordinate System:**
- World space uses `CGFloat` coordinates with origin at (0, 0)
- Items are positioned using world coordinates independent of screen/viewport
- World units are arbitrary but consistent (currently ~1 unit per screen point at 1.0 scale)

**Camera/Transform Model:**
- `offset: CGSize` - Translation from world origin to screen space (in screen points)
- `scale: CGFloat` - Uniform scale factor (zoom level)
- Bounds: `minScale = 0.05`, `maxScale = 8.0`
- Transform: `screenPoint = worldPoint * scale + offset`

**Initial View:**
- On `.onAppear`, offset is set to `(screenWidth/2, screenHeight/2)` to center world origin
- Note: Canvas view may not update immediately; visible after first pan gesture

**Coordinate Conversion:**
Implemented via `screenToWorld(_:)` helper:
```swift
func screenToWorld(_ p: CGPoint) -> CGPoint {
    CGPoint(x: (p.x - offset.width) / scale, 
            y: (p.y - offset.height) / scale)
}
```

**Rendering Strategy:**
- Canvas rendered using SwiftUI `Canvas` for grid background
- Items rendered as SwiftUI views in a `ZStack` with `.zIndex()` for layering
- Transform applied via `.position()` and `.frame()` modifiers
- Currently no visibility culling (all items rendered); acceptable for MVP with small item counts

**Grid Visualization:**
- World-aligned grid with configurable spacing (`gridSpacingWorld = 128.0`)
- Grid lines drawn at world coordinates, transformed to screen space
- Grid can be toggled via `showGrid` state
- Red origin crosshair removed (was causing render timing issues)

---

### Gesture System

Three simultaneous gestures are attached to the canvas ZStack:

**Drag Gesture (Tool-Routed):**
- `DragGesture(minimumDistance: 8)` — routed through the active `CanvasToolBehavior`
- On first `.onChanged`: async hit-test via tool behavior determines `DragMode` (`.pan`, `.moveItem`, `.none`)
- Mode is cached in `currentDragMode` for the gesture's duration
- `.pan` mode: updates `offset` by accumulating translation (canvas panning)
- `.moveItem` mode: updates `selection.dragOffset` in world space (item move with live visual feedback)
- On `.onEnded`: if `.moveItem`, calls `commitMove()` to persist positions; resets all drag state

**Tap Routing (Native Hit-Testing):**
- Taps are routed via per-view `.onTapGesture`, not a parent `SpatialTapGesture`:
  - Each `FileImageView` has `.onTapGesture { ... tappedItem(id:) }` attached **before** `.position(...)` so the tappable frame tracks the item
  - The background `Canvas` grid has `.onTapGesture { ... tappedEmpty() }`
- This lets SwiftUI's native hit-testing arbitrate taps — the topmost child wins and no parent gesture fires alongside. Prior architecture used `.simultaneousGesture(SpatialTapGesture())` on the outer ZStack, which caused tap-passthrough (e.g. tapping the trash button in the selection action bar also tapped the image beneath it). SwiftUI has no `stopPropagation` equivalent for simultaneous gestures; moving tap routing onto the children is the idiomatic fix.
- The `DragGesture(minimumDistance: 8)` on the ZStack still handles drag-mode routing; taps (< 8pt movement) never fire it, so the two systems don't overlap.

**Pinch Zoom (UIKit Bridge):**

**File:** `PinchGestureView.swift`

- Replaces the earlier `MagnificationGesture` approach, which only zoomed around view center. Exposes the pinch centroid so zoom pivots where the fingers are (matches Apple Freeform).
- `UIViewRepresentable` wrapping a `UIPinchGestureRecognizer`; installed on the hosting ancestor via the shared `GestureInstallerView` (see below).
- Emits **per-tick scale deltas** (not cumulative) plus the **live centroid** in installer-local coordinates. `.began`/`.ended` emit delta = 1.0; only `.changed` emits real deltas.
- Centroid is reported in the installer's coordinate space (not `recognizer.view` / window space) so it matches the canvas's `.position(...)` space — important if the canvas is ever inset by a toolbar or safe area.
- Attached via `.background(PinchGestureView(onPinch:))` on the canvas ZStack; routed through `handlePinch(phase:scaleDelta:anchor:)`.
- Zoom math is extracted into a **pure static function**, `BoardCanvasView.zoomAnchoredOffset(anchor:oldOffset:oldScale:newScale:)`, which preserves `worldPoint = (anchor - offset) / scale` across the scale change. Testable without a live view.

**Two-Finger Pan (UIKit Bridge):**

**File:** `TwoFingerPanView.swift`

- Provides always-available two-finger panning regardless of active tool so Group-tool marquee doesn't block canvas navigation.
- `UIViewRepresentable` wrapping a `UIPanGestureRecognizer` (min/max touches = 2); installed on the hosting ancestor via the shared `GestureInstallerView`.
- Emits **per-tick translation deltas** (not cumulative + baseline); `handleTwoFingerPan(phase:delta:)` just adds the delta to current `offset`.
- Recognizer config: `cancelsTouchesInView = false`, `delaysTouchesBegan/Ended = false`, delegate returns `true` for `shouldRecognizeSimultaneouslyWith` so SwiftUI gestures still observe touches.

**Delta-Based Composition (why both bridges emit deltas):**

Pinch and two-finger-pan fire simultaneously and both write `offset`. An earlier cumulative-plus-frozen-baseline design had a race: whichever handler ran second read a stale baseline captured before the other handler's writes. Switching both bridges to emit per-tick deltas and having each handler read/write current `offset`/`scale` every frame eliminates the race — there's no baseline to clobber. Partial ends (pinch ends before pan, or vice versa) are free for the same reason.

**Shared Gesture Installer:**

**File:** `GestureInstallerView.swift`

- `GestureInstallerView` + `GestureInstallerCoordinator` protocol — shared infrastructure for any `UIViewRepresentable` gesture bridge that needs to install a recognizer on the SwiftUI hosting ancestor.
- Responsibilities: walks the responder chain (`responder.next`) to find the first `UIViewController.view`, installs the coordinator's recognizer there on `didMoveToWindow`/`didMoveToSuperview`, relocates on re-parenting, and guarantees `isUserInteractionEnabled = false` on the installer itself so it never shadows hit-testing.
- Consumers (pinch + two-finger pan today) conform their `Coordinator` to `GestureInstallerCoordinator` and expose their recognizer via `installedRecognizer`.
- Teardown: each bridge's `dismantleUIView(_:coordinator:)` calls `Coordinator.detach()`, which removes the recognizer from its host view, clears target/delegate, and replaces the event closure with a no-op — prevents duplicate recognizers and retention cycles if the canvas remounts (e.g. `RootView` toggling `showCanvas`).

**Flag for future — camera model tipping point:**

`offset` and `scale` currently live on `BoardCanvasView` as `@State` and are mutated directly from two gesture handlers plus read from several places (`Canvas` grid closure, every visible-image `.position(...)`, `screenToWorld`, marquee/bbox mapping). When a **third** write site appears (e.g. a programmatic "fit to selection" action, or a new gesture bridge), lift both into an `@Observable CanvasCamera` with `zoom(by:around:)` and `pan(by:)` methods. `zoomAnchoredOffset` moves in as an instance method at that point. Do not do this refactor pre-emptively — it's a cross-cutting change and the single-caller benefit today is small.

Related coordinate-space subtlety to watch: `PinchGestureView` reports its centroid in installer-local coordinates; `TwoFingerPanView` uses `recognizer.view` (the hosting ancestor). These coincide today because the installer is mounted as a `.background` of the canvas ZStack, but would drift if the canvas becomes inset. Prefer installer-local coordinates for any new recognizer that reports points.

---

### Image Placement System

**Placement Logic:**

Images are placed via `insertImages(atScreenPoint:urls:)`:

1. **File Security:** Files are copied to `Application Support/ImportedImages/` via `makeSandboxCopyIfNeeded(from:)` to ensure sandbox access. This is called once inside `insertImages(atScreenPoint:urls:)` — callers pass raw URLs
2. **Size Calculation:** 
   - Pixel dimensions read via `CGImageSource` 
   - Scaled to world units preserving aspect ratio
   - Max dimension: 512 world units, min: 64 world units
3. **Anti-Overlap:** `firstNonOverlappingRect(near:size:)` nudges placement diagonally if overlapping existing items (max 64 attempts, 24pt nudge)
4. **Z-Ordering:** Auto-incrementing `nextZIndex` ensures new items appear on top

**Placement Sources:**
- Drop gesture (drag files onto canvas)
- File picker via toolbar "Add Item" button
- External binding: `@Binding var externalInsertURLs: [URL]?`

**Data Model:**

Private `PlacedImage` struct within `BoardCanvasView`:
```swift
struct PlacedImage: Identifiable {
    let id: UUID
    let url: URL          // Local file URL
    var worldRect: CGRect // Position/size in world coordinates
    var zIndex: Int       // Render order
}
```

**Image Rendering:**
- `FileImageView` (private nested view) loads images asynchronously from file URLs
- Uses `.resizable()`, `.scaledToFill()` with `.clipped()`
- Shows `ProgressView` placeholder during load
- Transform applied: frame size scaled by `scale`, position calculated from world center

---

### Drop Handling

**Supported Types:**
- `UTType.image` (PNG, JPEG, etc.)
- `UTType.gif`

**Implementation:**
- `CanvasDropDelegate` (file-scope struct) conforms to `DropDelegate`
- Validates providers have allowed types
- Loads file URLs asynchronously via `loadURLsFromProviders`
- Handles both file representations and data→temp file fallback

**File Loading:**

Async loading via `NSItemProvider` extensions (file-scope):
- `loadFileURLCompat(for:)` - tries file representation
- `loadDataAsTempFileCompat(for:)` - fallback to data, writes temp file

**Code Duplication Note:**
File loading logic is duplicated between `BoardCanvasView.swift` and `InsertFileControl.swift`. Should be extracted to shared utility file (e.g., `FileImportHelpers.swift`).

---

### Integration Points

**RootView (App Router):**

**File:** `RootView.swift`

Lightweight root view that routes between the landing screen and the canvas.

- Shows `FilePickerView` on launch; transitions to `ContentView` once files are selected
- Uses `@State private var showCanvas: Bool` to control which screen is displayed
- Observes `openHandler.importedElements` via `onChange(of:)` so `.refboard` cold launches navigate directly to canvas
- `ContentView` receives selected URLs as a `let initialURLs: [URL]` (not a binding)

**Observable App Open Handler:**

- `AppOpenHandler` is an `@Observable @MainActor final class` (migrated from `ObservableObject` + `@Published`)
- Injected through the environment at the app root via `.environment(openHandler)` and read via `@Environment(AppOpenHandler.self)` in `RootView` / `ContentView`

**ContentView:**
- Hosts `BoardCanvasView` in a `ZStack`
- Overlays `CanvasOverlayLayout` which places `CanvasToolbar` (centered) and `CanvasSettingsButton` (bottom corner) on the configured side
- Manages `@State private var urlsToInsert: [URL]?` binding for file picker integration
- On `.onAppear`, forwards `initialURLs` to `urlsToInsert` for the canvas to consume
- Presents `.fileImporter` when toolbar "Add Item" is tapped
- Presents `.sheet` with `CanvasSettingsView` when settings button is tapped

**File Picker Integration:**
- Toolbar's `onAddItem` callback sets `importerMode = .images` (board import sets `.board`)
- `.fileImporter` presentation is driven by `@State private var importerPresented: Bool`; changes to `importerMode` toggle `importerPresented` via `.onChange(of:)`, and clearing `importerPresented` resets `importerMode` — avoids inline `Binding(get:set:)` closures
- A latched `lastImporterMode` lets the result handler know which mode was active even after the mode binding clears
- `.fileImporter` allows multiple selection of `.image` and `.gif` types (images mode) or a single `.refboard` (board mode)
- Selected URLs are passed to `BoardCanvasView` via `externalInsertURLs` binding
- `BoardCanvasView` watches binding with `.onChange`, calls `insertImagesAtCenter()`
- Binding is cleared after processing to reset state

---

### Performance Considerations

**Current Approach (MVP):**
- All placed items rendered every frame
- No spatial indexing or visibility culling
- Acceptable for small boards (<100 items)

**Future Optimization Paths:**
- Implement visibility culling based on transformed viewport bounds
- Use `CMTileKey` system (defined in `CanvasModels.swift` by Dev B) for spatial indexing
- Consider render caching for static content
- Investigate Metal-based rendering for large item counts

---

## Canvas UI Overlay System

Decision Status: **Implemented**

### Canvas Toolbar (HUD)

**Status: Implemented**

**File:** `CanvasToolbar.swift`

The Canvas Toolbar provides tool selection and canvas actions through a persistent left-side overlay.

**Components:**

- `CanvasToolbar`: Main toolbar view component
- `ToolbarButton`: Private reusable button component with active state support
- `CanvasTool`: Enum defining available tools (`.pointer`, `.group`) — lives in its own file `CanvasTool.swift`

**Visual Design:**

- **Position**: Centered vertically on left side (16pt leading padding)
- **Fixed width**: 68pt (44pt button + 12pt padding each side)
- **Styling**: 
  - Background: `DesignSystem.Colors.primary` (#191919)
  - Inactive icons: `DesignSystem.Colors.secondary` (#535353)
  - Active state: `DesignSystem.Colors.tertiary` (#86B8FE) background with primary-colored icon
  - Corner radius: 12pt (toolbar container), 8pt (active button indicator)
  - Shadow: `color: .black.opacity(0.3), radius: 8, x: 2, y: 2`
- **Touch targets**: 44pt × 44pt (Apple's recommended minimum)
- **Spacing**: 12pt between buttons, dividers at 8pt total height (1pt line + 4pt padding each side)

**Tool Groups:**

1. **Selection Tools** (mutually exclusive, with active state):
   - Pointer tool (`arrow.up.left`) - default
   - Group tool (`rectangle.dashed`)

2. **History Actions** (single-action buttons, no active state):
   - Undo (`arrow.uturn.backward`)
   - Redo (`arrow.uturn.forward`)

3. **Content Actions**:
   - Add new item (`plus`)

**Active State Animation:**

Uses SwiftUI's `matchedGeometryEffect` to create smooth transitions between active tools:

```swift
@Namespace private var toolNamespace

// In ToolbarButton, applied to active tool background
.matchedGeometryEffect(id: "activeButton", in: toolNamespace)
.animation(.smooth(duration: 0.3), value: isActive)
```

**Integration:**

- `ContentView` manages `@State private var activeTool: CanvasTool = .pointer`
- Toolbar binds via `@Binding var activeTool: CanvasTool`
- `ContentView` passes `$activeTool` to `BoardCanvasView` so the canvas knows which tool is active
- Callbacks for actions: `onUndo`, `onRedo`, `onAddItem`
- `onAddItem` opens `.fileImporter` for selecting images/GIFs

---

### Tool Behavior System

**Status: Implemented**

**File:** `CanvasToolBehavior.swift`

A protocol-based abstraction that lets each toolbar tool define its own gesture handling.

**Architecture:**

```
CanvasTool (enum)              -- toolbar identity, UI selection
    |
    v
CanvasToolBehavior (protocol)  -- gesture interpretation per tool
    ├── PointerToolBehavior    -- tap=select, drag-on-item=move, drag-on-empty=pan
    └── GroupToolBehavior      -- tap=toggle selection, drag-on-item=group move, drag-on-empty=marquee select
```

**Protocol:**

```swift
struct HitTestItem { let id: UUID; let worldRect: CGRect; let zIndex: Int }

protocol CanvasToolBehavior {
    func dragBegan(worldStart: CGPoint, items: [HitTestItem], selection: CanvasSelectionState) -> DragMode

    @MainActor
    func tappedItem(id: UUID, store: LocalBoardStore, selection: CanvasSelectionState) async

    @MainActor
    func tappedEmpty(selection: CanvasSelectionState)
}
```

Tap methods are split so the view layer can call the right one based on which `.onTapGesture` fired. `tappedItem` receives the `UUID` directly (hit-testing already done by SwiftUI) instead of doing a world-point lookup. Both tap methods are `@MainActor` so implementations can mutate `CanvasSelectionState` directly without `MainActor.run` trampolines.

`dragBegan` is **synchronous** — it hit-tests against in-memory `placedImages` (mapped to `HitTestItem`) instead of querying the async store. This eliminates a race where quick drags could end before the async mode decision completed. The `moveToTop` z-order persistence is fired as a non-blocking side effect after mode is set.

**DragMode enum:** `.pan`, `.moveItem`, `.resizeItem`, `.marqueeSelect`, `.none`

**Gesture Routing:**

A single `DragGesture(minimumDistance: 8)` on the canvas ZStack delegates to the active tool's behavior:
1. On first `.onChanged` event: handle hit-test first (resize), then tool behavior → cache `DragMode` for gesture duration
2. Mode decision is synchronous — no async gap between first event and mode being set
3. Subsequent `.onChanged`: `applyDrag()` routes to pan, move, resize, or marquee based on cached mode
4. `.onEnded`: commits the appropriate action (move, resize, group resize, or marquee select)

**Pointer Tool Behavior:**
- Drag on item → select it, bring to top, enter `.moveItem` mode
- Drag on empty canvas → `.pan` mode (normal canvas pan)
- Tap on item → select it
- Tap on empty → clear selection

**Group Tool Behavior:**
- Drag on selected item → `.moveItem` mode (group move)
- Drag on unselected item → add to selection via `extending: true`, `.moveItem` mode
- Drag on empty canvas → `.marqueeSelect` mode (draws selection rectangle)
- Tap on item → toggle selection membership (`extending: true`)
- Tap on empty → clear selection

**Factory:** `toolBehavior(for: CanvasTool) -> CanvasToolBehavior` maps enum to concrete behavior.

**Adding New Tools:**
1. Add case to `CanvasTool` enum
2. Create a struct conforming to `CanvasToolBehavior`
3. Add mapping in `toolBehavior(for:)` factory

---

### Selection & Move System

**Status: Implemented**

**Files:** `CanvasSelectionState.swift`, `HandlePosition.swift`, `SelectionOverlay.swift`, `MarqueeOverlayView.swift`, `BoardCanvasView.swift`

**Selection State:**

`CanvasSelectionState` is an `@Observable` class owned as `@State` in `BoardCanvasView`:
- `selectedIDs: Set<UUID>` — currently selected element IDs
- `dragOffset: CGSize` — world-space offset during active drag-move
- `isDragging: Bool` — whether a move drag is in progress
- `select(_:extending:)` — select an item (`extending: true` toggles membership for multi-select)
- `clearSelection()` — deselect all

**Marquee State** (in `CanvasSelectionState`):
- `marqueeStartWorld: CGPoint?` — world-space anchor of the marquee drag
- `marqueeCurrentWorld: CGPoint?` — world-space current corner
- `marqueeWorldRect: CGRect?` — computed normalized rect
- `isMarqueeing: Bool` — computed from `marqueeStartWorld != nil`
- `clearMarquee()` — resets marquee state

**Visual Indicators:**

**Files:** `SelectionOverlay.swift` (views), `HandlePosition.swift` (data model)

- `ResizeHandleView` — shared 10×10pt rounded rectangle handle with white fill and tertiary border, used by both overlay types
- `SelectionOverlay` — solid blue border + 8 handles, shown on single-selected items
- `GroupSelectionOverlay` — dashed blue border + 8 handles, shown on the group bounding box when multiple items are selected
- When multi-selected, individual items show a light semi-transparent border instead of full handles
- `MarqueeOverlayView` — dashed rectangle with semi-transparent fill, shown during marquee drag

- `HandlePosition` enum (in `HandlePosition.swift`) defines `.topLeft`, `.topCenter`, `.topRight`, `.leftCenter`, `.rightCenter`, `.bottomLeft`, `.bottomCenter`, `.bottomRight`
- Extracted to its own file to avoid coupling `CanvasSelectionState` to the view layer
- Each handle has helper properties: `anchorPosition` (opposite handle), `isCorner`, `isLeftSide`, `isTopSide`

**Move Interaction:**

1. User drags a selected item → `applyDrag()` sets `selection.dragOffset` in world space
2. During drag, selected items render with a live offset: `position + (dragOffset * scale)` — no store updates per frame
3. On drag end, `commitMove()` pushes a `.move` command to history, then applies via `applyMoveDelta()`

**Resize Interaction:**

**Status: Implemented (single + group)**

`hitTestHandle(screenPoint:)` is a pure query returning a `HandleHitResult` enum (`.singleItem` or `.group`). The call site in the gesture handler sets up the appropriate resize state based on the result.

**Single-item resize** (1 item selected):
1. `hitTestHandle` checks screen-space distance to 8 handles on the item (hit radius: 30pt)
2. If hit → `.resizeItem` drag mode, populates single resize state
3. During drag, `applyResize(translation:)` delegates to `computeResizedRect()` (shared pure function)
4. Live rect stored in `selection.resizeCurrentRect`
5. `commitResize()` skips no-op resizes, pushes `.resize` command

**Group resize** (2+ items selected):
1. `hitTestHandle` checks handles on the group bounding box
2. If hit → `.resizeItem` drag mode, snapshots all selected items' rects into `groupResizeStartRects`
3. During drag, `applyGroupResize(translation:)` delegates to `computeResizedRect()` on the group bbox
4. Each item's live rect is computed via `scaledRect(original:bboxStart:bboxCurrent:)`:
   - `scaleX = bboxCurrent.width / bboxStart.width`
   - `scaleY = bboxCurrent.height / bboxStart.height`
   - Position and size scaled relative to bbox origin
5. `commitGroupResize()` pushes `.groupResize(fromRects:toRects:)` command, applies all rects in a single batch via `applyResizeRects(_:)`

**Shared resize math:** `computeResizedRect(handle:startRect:translation:) -> CGRect?`
- Corner handles: aspect-ratio-locked resize, opposite corner pinned
- Edge handles: single-axis stretch, opposite edge pinned
- Minimum dimension enforced (`minImageDimensionWorld = 64`)
- Used by both single and group resize paths

**Single Resize State** (in `CanvasSelectionState`):
- `resizeHandle: HandlePosition?` — which handle is being dragged (shared with group resize)
- `resizeStartRect: CGRect?` — element's world rect at drag start
- `resizeCurrentRect: CGRect?` — live rect during drag
- `resizeElementID: UUID?` — element being resized
- `isResizing: Bool` — computed from `resizeHandle != nil`
- `clearResize()` — resets all single resize state

**Group Resize State** (in `CanvasSelectionState`):
- `groupResizeStartRects: [UUID: CGRect]?` — original rects of all selected items
- `groupResizeBBoxStart: CGRect?` — group bounding box at resize start
- `groupResizeBBoxCurrent: CGRect?` — live bounding box during resize
- `isGroupResizing: Bool` — computed from `groupResizeStartRects != nil`
- `clearGroupResize()` — resets all group resize state

**Performance:**

Store updates are serialized via `enqueueStoreMutation()` — each mutation cancels any in-flight task and awaits its completion before running. This prevents stale writes from rapid undo/redo or overlapping operations. Each mutation uses batched `elements(for:)` + `upsert(elements:)` calls (2 actor round-trips, not 2N).

---

### Command History (Undo/Redo)

**Status: Implemented**

**Files:** `CanvasCommandHistory.swift`, `BoardCanvasView.swift`, `ContentView.swift`

A command pattern for reversible canvas operations. Each user action (move, resize, insert) is recorded as a lightweight command that can be undone and redone.

**Architecture:**

```
CanvasCommand (enum)         — describes a reversible operation
CanvasCommandHistory         — @Observable class with undo/redo stacks
BoardCanvasView              — executes commands via helper methods
ContentView                  — triggers undo/redo from toolbar
```

**Command Types:**

| Command | Data Stored | Undo | Redo |
|---------|-------------|------|------|
| `.move` | `elementIDs: Set<UUID>`, `delta: CGSize` | Move by -delta | Move by +delta |
| `.resize` | `elementID: UUID`, `fromRect`, `toRect` | Restore fromRect | Restore toRect |
| `.groupResize` | `fromRects: [UUID: CGRect]`, `toRects: [UUID: CGRect]` | Restore all fromRects | Apply all toRects |
| `.insert` | `snapshots: [PlacedElementSnapshot]` | Remove elements | Re-add elements |
| `.delete` | `snapshots: [PlacedElementSnapshot]` | Re-add elements | Remove elements |

`PlacedElementSnapshot` captures everything needed to fully add/remove an element: `id`, `url`, `worldRect`, `zIndex`, and the full `CMCanvasElement`.

**History Management:**

- `CanvasCommandHistory` is an `@Observable @MainActor` class owned as `@State` in `ContentView` and passed to `BoardCanvasView` (required init parameter, no default)
- `push(_:)` — appends to undo stack, clears redo stack
- `popUndo()` / `popRedo()` — moves commands between stacks
- `canUndo` / `canRedo` — computed properties for UI state
- `clear()` — wipes both undo and redo stacks; called after a board import so stale commands from the previous board can't resurrect removed assets via redo

**Integration:**

- Toolbar undo/redo buttons fire UUID trigger bindings (`undoTrigger`, `redoTrigger`)
- `BoardCanvasView` observes triggers via `.onChange` and calls `performUndo()` / `performRedo()`
- Each method pops a command and dispatches to shared helpers: `applyMoveDelta()`, `applyResizeRect()`, `applyResizeRects(_:)` (batched group resize), `addElements()`, `removeElements()`

**Adding New Undoable Operations:**

1. Add a case to `CanvasCommand` enum
2. Push the command in the action's commit function
3. Add undo/redo handling in `performUndo()` / `performRedo()`

---

### Selection Action Bar

**Status: Implemented**

**File:** `CanvasSelectionActionBar.swift`

Floating action bar that appears next to the current canvas selection, hosting selection-scoped actions (currently: delete). Chosen over a context menu after trials with `.contextMenu(menuItems:preview:)` — the default preview couldn't elevate the whole group, and a custom preview couldn't blur non-source items. An action bar gives Figma-style affordances that scale to more actions without preview constraints.

**Visual Design:**
- Horizontal `HStack` containing a 44×44pt trash `Button` with `.buttonStyle(.plain)`
- Trash icon: `DesignSystem.Colors.destructive` (#FE8686)
- Background: `DesignSystem.Colors.primary`, 10pt corner radius, 4pt horizontal padding
- Shadow: `color: .black.opacity(0.3), radius: 8, x: 2, y: 2`
- `.accessibilityLabel("Delete")` on the button

**Positioning (in `BoardCanvasView`):**
- Rendered inside the canvas ZStack only when `selectionBoundingBox()` returns non-nil **and** no gesture is active (`!isDragging && !isResizing && !isGroupResizing && !isMarqueeing`)
- Screen position: `x = bbox.midX * scale + offset.width`, `y = bbox.maxY * scale + offset.height + 24` — centered under the selection bounding box
- `.zIndex(Double(Int.max))` so it always sits above canvas items

**Delete Flow:**
- `deleteSelection()` fetches authoritative `CMCanvasElement`s from `LocalBoardStore` via `elements(for:)` before snapshotting — avoids fabricating elements from the view's `placedImages` cache, which could be stale
- Snapshots feed a `.delete(snapshots:)` command pushed onto `CanvasCommandHistory`, then `removeElements()` applies the change
- Fallback path: `fallbackElement(for:)` handles rare view/store desync

---

### Canvas Settings Button

**Status: Implemented**

**File:** `CanvasSettingsButton.swift`

A standalone settings button positioned dynamically at the bottom corner of the canvas (left or right based on user preference), separate from the main toolbar but matching its visual styling.

**Visual Design:**

- **Position**: Bottom corner with 16pt padding from edges - dynamically switches sides based on `toolbarSide` setting
- **Fixed width**: 68pt (matches toolbar width)
- **Styling**:
  - Background: `DesignSystem.Colors.primary` (#191919)
  - Icon: `gearshape.fill` SF Symbol (size 20pt, medium weight)
  - Icon color: `DesignSystem.Colors.secondary` (#535353)
  - Corner radius: 12pt (matches toolbar container)
  - Padding: 12pt (matches toolbar padding)
  - Shadow: `color: .black.opacity(0.3), radius: 8, x: 2, y: 2`
- **Touch target**: 44pt × 44pt

**Integration:**

- Positioned dynamically with `CanvasToolbar` in `ContentView`
- Position controlled by `toolbarSide` setting (`.left` or `.right`)
- Opens `.sheet` with `CanvasSettingsView` when tapped
- `@State private var showingSettings` controls sheet presentation
- Callback: `onTap: () -> Void`

**Settings Sheet:**

- **File:** `CanvasSettingsView.swift`
- Navigation-based settings interface with full dark theme styling
- **Functional Settings:**
  - **Canvas Color Picker** - Changes the canvas background color via a custom pill-shaped color swatch that opens the system color picker
  - **Show Grid Toggle** - Controls canvas grid visibility via binding to `BoardCanvasView`
  - **Toolbar Position Picker** - Switches toolbar and settings button between left/right side
- "Done" button styled with tertiary color to dismiss
- **About Section** - Version info display

**Settings Functionality:**

1. **Canvas Color:**
   - Binding: `@Binding var canvasColor: Color`
   - Connected to `BoardCanvasView.canvasColor` binding, applied as `.background(canvasColor)` on the canvas ZStack
   - Custom pill-shaped UI: a `RoundedRectangle` (48×28pt) filled with the current color, with an invisible `ColorPicker` scaled on top (`.opacity(0.015)`, `.scaleEffect(2.0)`)
   - Pill set to `.allowsHitTesting(false)` so taps pass through to the picker; hit area constrained to pill shape via `.contentShape(RoundedRectangle)` on the container
   - `supportsOpacity: false` — solid colors only
   - Default: `.white`

2. **Grid Toggle:**
   - Binding: `@Binding var showGrid: Bool`
   - Connected to `BoardCanvasView.showGrid` binding
   - Instantly shows/hides grid lines on canvas
   - Default: `true`

3. **Toolbar Position:**
   - Enum: `ToolbarSide` (`.left` or `.right`)
   - Controls position of both `CanvasToolbar` and `CanvasSettingsButton`
   - `ContentView` uses conditional layout (`leftSideLayout` or `rightSideLayout`)
   - Default: `.left`
   - Changes apply immediately, persists during session

**Dynamic UI Layout:**

**File:** `CanvasOverlayLayout.swift`

A single reusable view that positions both the `CanvasToolbar` (vertically centered) and the `CanvasSettingsButton` (bottom corner) on the configured side:
- Takes `side: ToolbarSide` and derives `edge: Edge.Set` and `frameAlignment: Alignment`
- `ContentView` instantiates `CanvasOverlayLayout(side: toolbarSide, ...)` once instead of branching between `leftSideLayout`/`rightSideLayout` computed properties
- Both elements maintain 16pt padding from edges

**Visual Styling:**

Settings sheet fully integrated with design system:
- Background: `DesignSystem.Colors.primary` + black
- Navigation bar: Dark with primary background
- Primary labels: `DesignSystem.Colors.text` (white)
- Secondary text/values: `DesignSystem.Colors.secondary` (gray)
- Interactive accents: `DesignSystem.Colors.tertiary` (blue toggles, picker tint, Done button)
- Section rows use dark backgrounds
- Dark color scheme applied to navigation

---

### Design System

**Status: Implemented**

**Files:** `DesignSystem.swift`, `Colors.swift`

Central design token system for consistent styling across the application.

**Color Palette:**

```swift
DesignSystem.Colors.primary     // #191919 (25, 25, 25) - Dark gray
DesignSystem.Colors.secondary   // #535353 (83, 83, 83) - Medium gray
DesignSystem.Colors.tertiary    // #86B8FE (134, 184, 254) - Light blue
DesignSystem.Colors.text        // #FFFFFF (255, 255, 255) - White
DesignSystem.Colors.destructive // #FE8686 (254, 134, 134) - Red (same S/L as tertiary)
```

**Usage:**
- Backgrounds: `primary` (toolbars, settings, UI containers)
- Secondary text/values: `secondary` (subtle information, picker options)
- Interactive accents: `tertiary` (active states, toggles, buttons)
- Primary text: `text` (main labels, readable content)
- Destructive actions: `destructive` (delete buttons, destructive confirmations)

**Usage Guidance (important):**

**Always prefer a `DesignSystem.Colors` token over a hard-coded color** (`.red`, `Color(red:…)`, hex literals, system semantic colors). New UI should pull from the palette so the app stays visually coherent and themeable.

If a color you need isn't in the palette:
1. Stop — don't reach for `.red`, `.orange`, `Color(hex:)`, etc. as a shortcut.
2. Decide whether it's a **new semantic token** (e.g. `destructive`, `warning`, `success`) or a one-off tint. Semantic tokens belong in `Colors.swift`.
3. Pick a hue that matches the palette's saturation/lightness so it sits with the existing colors (e.g. `destructive` #FE8686 matches `tertiary`'s S/L with a red hue).
4. Add it to `DesignSystem.Colors` with a doc comment describing intent, then consume it by name.

This applies to any other design primitive that lives (or should live) in the design system — spacing, corner radii, shadows, typography. If you find yourself hard-coding the same value in two places, it's a candidate for a `DesignSystem` token.

**Color Hierarchy:**
- **White** - Primary labels and important text for maximum readability
- **Gray** - Secondary info, values, less prominent text
- **Blue** - Interactive elements, active states, call-to-action buttons
- **Dark Gray** - All backgrounds and containers

**Structure:**
- `DesignSystem` enum acts as namespace
- `Colors` nested enum contains static color definitions
- Extensible for future design tokens (typography, spacing, shadows, etc.)

---

### File Import Controls

**Status: Implemented (Standalone)**

**File:** `InsertFileControl.swift`

Reusable SwiftUI component for importing files via file picker or drag-and-drop.

**Features:**
- Button interface with "Insert File" label and tray icon
- SwiftUI `.fileImporter` for manual file selection
- `.onDrop` support for drag-and-drop with visual feedback
- Border highlight when drop is targeted
- Supports `UTType.image` and `UTType.gif`
- Multiple file selection enabled
- Async file loading with automatic fallback from file representation → data representation → temp file

**API:**
```swift
InsertFileControl(onImportURLs: ([URL]) -> Void)
```

**Integration Status:**
- Component exists and is functional in isolation
- **Not currently used** in main canvas flow (toolbar uses direct `.fileImporter` instead)
- Could be used in future file-picking contexts

**Technical Notes:**
- Accessibility labels and hints included
- File loading helpers handle async provider resolution

**Code Duplication:**
File loading logic (`loadURLs(from:preferredTypes:)`) is duplicated between `InsertFileControl.swift` and `BoardCanvasView.swift`. Candidate for extraction to shared utility file.

---

### Other UI Components

**FilePickerView (Landing Page)**

**Status: Implemented**

**Files:** `FilePickerView.swift`, `RecentBoardsManager.swift`

The app's landing screen with three entry paths to the canvas and a recent boards section.

**Entry Paths:**

1. **"New Board" (primary CTA)** — filled tertiary button, presents a `.fileExporter` for `Untitled Board.refboard`. On success, an empty canvas opens with that save location as its `currentBoardURL`, so the back button can write straight to it.
2. **"Open Board" (secondary)** — outlined tertiary button, opens `.fileImporter` for `.refboard` files. Imports via `BoardArchiver.importElements` on a detached task, records in recents, passes elements + URL to `ContentView`
3. **Drag-and-drop** — drop images/GIFs onto the dashed rectangle area. `.contentShape(.rect)` ensures the entire padded area is a valid drop target, not just the icon/text

**Visual Design:**
- Large photo icon (`photo.on.rectangle.angled`, `@ScaledMetric` for Dynamic Type) with `.accessibilityHidden(true)`
- Dashed border rectangle highlights on drag target (`isTargeted` state)
- "New Board" and "Open Board" buttons side-by-side below
- "Recent Boards" section below buttons (up to 5 entries)
- Error alert (`showImportError` bool + `importErrorMessage` string) for failed imports

**Recent Boards:**

`RecentBoardsManager` is an `@Observable @MainActor` class that persists up to 10 recent board entries as JSON in App Support (`recent_boards.json`). Each entry stores:
- `name` — derived from filename
- `filePath` — standardized path string, used as stable `Identifiable.id` and dedup key
- `bookmarkData` — bookmark `Data` created with `.suitableForBookmarkFile` from the fileImporter-vended URL, which preserves the URL's implicit security scope on iOS (the explicit `.withSecurityScope` option is macOS-only). Lets the app reopen files across launches regardless of location.
- `lastOpened` — timestamp for sorting

The landing page displays up to 5 valid entries (list rows with doc icon, name, and relative date). Tapping an entry resolves the bookmark via `resolveURL()`, starts security-scoped access, and imports the board.

Pruning: invalid entries (where `resolveURL()` returns nil) are removed on init. `validEntries(limit:)` does no I/O — it just slices the already-pruned array.

Injection: `RecentBoardsManager` is created as `@State` in `RootView` and injected via `.environment()` to both `FilePickerView` and `ContentView`.

Recording happens on:
- Board open (from file picker or recents) — in `FilePickerView.openBoard(at:)`
- Board import (from canvas toolbar) — in `ContentView`
- Board export (file exporter success) — in `ContentView`
- Board save-on-back — in `ContentView.saveAndGoBack()`

**Callbacks:**
```swift
FilePickerView(
    onNewBoard: (URL) -> Void,
    onBoardSelected: ([CMCanvasElement], URL) -> Void,
    onFilesDropped: ([URL]) -> Void
)
```

`onNewBoard` receives the save URL chosen in the file exporter so `ContentView` can seed `currentBoardURL` for save-on-back.

**Integration:**
- `RootView` hosts `FilePickerView` and routes to `ContentView` based on which callback fires
- `initialBoardURL` is tracked through `RootView` → `ContentView` so save-on-back writes to the correct location

### Canvas Back Button

**Status: Implemented**

**File:** `CanvasOverlayLayout.swift`

A back button positioned in the top corner of the canvas (same side as toolbar, flips with `toolbarSide` setting). Styled to match the toolbar/settings button: 68pt wide, primary background, 12pt corner radius, matching shadow.

**Save-on-back flow:**
1. Back button tap sets `pendingBackNavigation = true` and triggers a canvas snapshot via `snapshotToken`
2. `onSnapshot` callback checks the flag — if pending back, calls `saveAndGoBack(elements:wasDirty:)` instead of presenting the file exporter
3. `saveAndGoBack` writes to `currentBoardURL` via `BoardArchiver.export` on a detached task, flips `markCleanTrigger`, then calls `onBack()` which sets `showCanvas = false` in `RootView`
4. If the export throws, an alert offers "Discard & Leave" or "Stay"; otherwise navigation proceeds

Because "New Board" requires choosing a save location up front, `currentBoardURL` is always set by the time the canvas appears, so the back button always has somewhere to write to.

---

## Future Frontend Work

### Planned Enhancements

1. **Tool Behavior:**
   - ~~Connect `activeTool` state to actual canvas interactions~~ ✅ Done
   - ~~Implement selection via pointer tool~~ ✅ Done
   - ~~Implement selection rectangles / marquee select for group tool~~ ✅ Done
   - ~~Implement group move/resize behavior for group tool~~ ✅ Done

2. **Item Interaction:**
   - ~~Select items on tap~~ ✅ Done
   - ~~Move items by dragging~~ ✅ Done
   - ~~Resize handle visuals~~ ✅ Done
   - ~~Functional resize via corner and edge handle drag~~ ✅ Done
   - ~~Undo/redo for move, resize, insert, and group resize~~ ✅ Done
   - ~~Multi-selection via marquee and toggle-tap~~ ✅ Done
   - ~~Group move (all selected items move together)~~ ✅ Done
   - ~~Group resize (proportional scaling relative to group bounding box)~~ ✅ Done
   - ~~Delete selected items (via floating selection action bar)~~ ✅ Done
   - Rotation gestures

3. **File Import Refactor:**
   - Extract duplicate file loading code into `FileImportHelpers.swift`
   - Consolidate loading logic between `BoardCanvasView` and `InsertFileControl`

4. **Settings Implementation:**
   - Make `CanvasSettingsView` functional
   - Bind grid toggle to `BoardCanvasView.showGrid`
   - Grid spacing slider
   - Add export options

5. **Navigation Flow:**
   - ~~Integrate `FilePickerView` as initial screen~~ ✅ Done
   - ~~Transition from file picker → canvas~~ ✅ Done
   - ~~Back navigation from canvas to landing page (with save-on-back)~~ ✅ Done
   - ~~Recent boards list on landing page~~ ✅ Done
   - **Save-As prompt for new boards on back:** When a user creates a new board (no `currentBoardURL`) and taps back, the app should present a file exporter (like the Export button does) so the user can name and choose a save location before navigating back. Without this, new unsaved boards are silently discarded on back navigation. The flow should be: back tap → snapshot → file exporter → on success, record in recents and navigate back; on cancel, stay on canvas.

6. **Performance:**
   - Implement viewport-based culling
   - Optimize render updates
   - Image caching strategy

---

## Dev A / Dev B Integration Points

**Areas where Dev A (Frontend) interfaces with Dev B (Backend):**

1. **Canvas Models:**
   - Dev A currently uses simplified `PlacedImage` struct
   - Dev B has defined `CMCanvasElement`, `CMElementHeader`, `CMCanvasElementPayload`
   - **Future migration:** Replace `PlacedImage` with `CMCanvasElement` for persistence integration

2. **Coordinate Systems:**
   - Dev A uses `CGFloat` and `CGPoint`/`CGRect`
   - Dev B uses `SIMD2<Double>` and `CMWorldRect`
   - **Integration needed:** Conversion helpers between coordinate systems

3. **Persistence:**
   - Dev A manages `placedImages` in `@State` and syncs to `LocalBoardStore` on insert, move, resize, and delete
   - All store mutations are serialized via `enqueueStoreMutation()` — cancels previous task, awaits completion, then runs
   - Move/resize operations use `elements(for:)` + `upsert(elements:)` for batched updates
   - Marquee select uses `headers(in: CMWorldRect)` for spatial rectangle query
   - Insert undo uses `delete(elementIDs:)` to remove elements from the store
   - Hit testing uses `topmostHeader(at:)` from `LocalBoardStore`
   - `moveToTop(elementIDs:)` used to bring selected items to front on interaction

4. **Tile System:**
   - Dev B has implemented `CMTileKey` spatial indexing
   - Dev A uses it for viewport culling via `headers(in:viewport:margin:)` and hit testing

---

## Notes

- Architecture reflects MVP implementation
- Focus is on core interaction and visual polish
- Performance optimizations deferred until item count becomes a bottleneck
- Clean separation from backend allows independent iteration
