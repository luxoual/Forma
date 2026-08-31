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

Camera state is encapsulated in `@Observable final class CanvasCamera` (`CanvasCamera.swift`), owned as `@State private var camera = CanvasCamera()` inside `BoardCanvasView`.

- `camera.offset: CGSize` — Translation from world origin to screen space (in screen points)
- `camera.scale: CGFloat` — Uniform scale factor (zoom level)
- Bounds: `minScale = 0.05`, `maxScale = 8.0`
- Transform: `screenPoint = worldPoint * camera.scale + camera.offset`

Write sites: pinch gesture, two-finger pan, home button (`zoomToFitContent`), board-load landing snap. All go through `camera.offset` / `camera.scale`. The home button and landing snap write *both* properties — they zoom to fit as well as center.

**Initial View:**
- On `.onAppear`, `camera.offset` is set to `(screenWidth/2, screenHeight/2)` to center on world origin
- If elements are already loaded when `onAppear` fires (race with `ContentView.onAppear`), `zoomToFitContent(animated: false)` runs immediately instead, fitting the content bounding box
- When a board with content is loaded via `elementsToLoad`, `zoomToFitContent(animated: false)` is deferred one run-loop tick via `DispatchQueue.main.async` to guarantee `canvasSize` is set first (see "Landing Snap" under Canvas Navigation Aids below)

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
- Viewport culling via `visibleImages` (tile-indexed spatial query against `LocalBoardStore`); images outside the viewport are not rendered

**Grid Visualization:**
- World-aligned grid with configurable spacing (`gridSpacingWorld = 128.0`)
- Grid lines drawn at world coordinates, transformed to screen space
- Grid can be toggled via `showGrid` state
- Red origin crosshair removed (was causing render timing issues)

**Empty Canvas State:**
- When `placedImages` is empty, a centered overlay shows a `photo.on.rectangle.angled` SF Symbol (80pt) and the text "Drag and drop an image here"
- Both elements are styled with `DesignSystem.Colors.secondary`, `compositingGroup()`, and `.blendMode(.difference)` so they remain visible regardless of canvas background color
- The overlay is hidden automatically as soon as the first image is placed

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
- Zoom math is extracted into a **pure static function**, `CanvasCamera.zoomAnchoredOffset(anchor:oldOffset:oldScale:newScale:)` (lives in `CanvasCamera.swift`), which preserves `worldPoint = (anchor - offset) / scale` across the scale change. Testable without a live view.

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

**Camera model — implemented:**

`offset` and `scale` have been lifted into `@Observable final class CanvasCamera` (`CanvasCamera.swift`). `BoardCanvasView` owns it as `@State private var camera = CanvasCamera()`. `zoomAnchoredOffset` is a static method on `CanvasCamera`.

`viewportCGRect()` and `allElementRects()` remain on `BoardCanvasView` — they need view-local state (`canvasSize`, `placedImages`, `placedTexts`) that belongs on the view.

`zoomToFitContent` and its `fitScale(for:)` helper also remain on the view (they need `canvasSize`, `reduceMotion`, `minScale`/`maxScale`, `scheduleRefreshVisibleElements()`), but write to `camera.offset` / `camera.scale`.

Next step (future PR): the UUID-trigger pattern for `homeTrigger` (and potentially `undoTrigger`/`redoTrigger`) could simplify once the camera is an environment-injected observable — the toolbar could call camera methods directly instead of firing UUID bindings through `ContentView`.

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

Shared file-loading helpers live in `Features/BoardCanvas/Import/ItemProviderHelpers.swift` — `loadURLsFromProviders(_:preferredTypes:)` plus `NSItemProvider` extensions (`loadFileURLCompat(for:)`, `loadDataAsTempFileCompat(for:)`). Both `BoardCanvasView` (drop handler) and `FilePickerView` (landing drop zone) call into this shared helper. The earlier duplicate copy in `InsertFileControl.swift` was deleted along with that unused control.

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
- Wraps `BoardCanvasView` in a `NavigationStack` and attaches `CanvasNavigationToolbar` via `.toolbar { ... }`. The nav bar renders translucent Liquid Glass over the canvas, which extends edge-to-edge underneath.
- Manages `@State private var urlsToInsert: [URL]?` binding for file picker integration
- On `.onAppear`, forwards `initialURLs` to `urlsToInsert` for the canvas to consume
- Presents `.fileImporter` when the toolbar's add button is tapped
- Presents `.sheet` with `CanvasSettingsView` when the toolbar's settings button is tapped

**File Picker Integration:**
- Toolbar's `onAddItem` callback sets `importerPresented = true`
- `.fileImporter` presentation is driven by `@State private var importerPresented: Bool`
- `.fileImporter` allows multiple selection of `.image` and `.gif` types
- Selected URLs are passed to `BoardCanvasView` via `externalInsertURLs` binding
- `BoardCanvasView` watches binding with `.onChange`, calls `insertImagesAtCenter()`
- Binding is cleared after processing to reset state

---

### Performance Considerations

**Current Approach:**
- `visibleImages: [PlacedImage]` is a culled subset of `placedImages` — only images whose world rects intersect the current viewport are rendered as `FileImageView` instances
- `imageRenderPlan()` splits `visibleImages` into `detailItems` (full image) and `overviewItems` (low-detail placeholder rect) based on screen size and LOD thresholds
- `scheduleRefreshVisibleElements()` re-queries `LocalBoardStore.imagePlacements(in:viewport:)` after a 40ms debounce (80ms during active interaction)
- Texts (`placedTexts`) are not culled — they are lightweight SwiftUI views with no image-loading cost

**Future Optimization Paths:**
- Cull text elements by viewport (low priority — texts are cheap)
- Consider Metal-based rendering for extremely large boards (1000+ images)

---

## Canvas Chrome (Native `.toolbar`)

Decision Status: **Implemented (native iPadOS 26 Liquid Glass)**

### Canvas Navigation Toolbar

**Status: Implemented**

**File:** `Features/BoardCanvas/Tools/CanvasNavigationToolbar.swift`

All canvas chrome (back, board name, tools, history, add, settings) now lives in a single native SwiftUI `.toolbar` attached to a `NavigationStack` wrapping `BoardCanvasView`. The earlier floating overlay system (`CanvasOverlayLayout` + `CanvasToolbar` + `CanvasStatusBar` + `CanvasSettingsButton`) has been removed.

Native `.toolbar` gives the per-button press feedback, glass material, group capsules via `ToolbarItemGroup`, separation via `ToolbarSpacer`, and automatic overflow into a `•••` menu when the bar narrows — all behaviors we were previously hand-rolling.

**Structure (`CanvasNavigationToolbar: ToolbarContent`):**

```
[Leading group]                                                [Trailing items]
< (back)  |  BoardName pill   [Pointer | Group | Text | Add] | [Undo | Redo] | [Home | Settings]
```

- **Leading `ToolbarItemGroup(.topBarLeading)`** — back chevron + board name pill share one glass capsule. Board name is a non-interactive glass button (see "Board name pill" below) inside the group, so the group's outer pill is the only glass surface — no nesting.
- **Trailing groups + `ToolbarSpacer(.fixed)`** between them so each group renders as its own glass capsule (tools+add, history, home+settings). The spacer is what visually separates the capsules. Home sits with Settings rather than with Undo/Redo: both are view-level navigation affordances, not edit-history actions.
- **Every button provides a title (via `Label("Title", systemImage:)` or `Button("Title", systemImage:action:)`)** so the system overflow menu can populate its dropdown with real titles when the bar collapses on narrow widths.

**Tools group (active-state indicator + Add):**

```swift
ToolbarItemGroup(placement: .topBarTrailing) {
    toolButton(.pointer, label: "Pointer", icon: "arrow.up.left")
    toolButton(.group,   label: "Group",   icon: "rectangle.dashed")
    toolButton(.text,    label: "Text",    icon: "textformat")
    Button("Add", systemImage: "plus", action: onAddItem)
}

private func toolButton(_ tool: CanvasTool, label: String, icon: String) -> some View {
    let isActive = activeTool == tool
    return Button { activeTool = tool } label: {
        Label(label, systemImage: icon)
    }
    .tint(isActive ? DesignSystem.Colors.tertiary : nil)
    .accessibilityAddTraits(isActive ? [.isSelected] : [])
}
```

Active state is communicated via tertiary `.tint` *and* the `.isSelected` accessibility trait. Color-only would leave VoiceOver users without an indicator. No `matchedGeometryEffect` — the system handles all transitions natively, and discrete buttons participate in the system overflow menu (a segmented `Picker` does not).

Add sits inside the same `ToolbarItemGroup` as the mode tools because it's the other put-stuff-on-the-canvas action — it shares the glass capsule but is not a mode toggle, so it carries no tint and no `.isSelected` trait. Previously it lived next to Settings, which read like a settings affordance.

**Board name pill — disabled-button trick:**

A bare `Text(boardName).glassEffect()` placed in a leading toolbar slot is squeezed by the system to roughly chevron width — it doesn't respect `frame(maxWidth:)` for raw text views. Wrapping the text in a non-interactive glass button makes the system treat it as a real toolbar control, which honors the size:

```swift
Button { } label: {
    Text(boardName)
        .font(.headline)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: 220)
}
.tint(DesignSystem.Colors.tertiary)
.allowsHitTesting(false)              // non-tappable
.accessibilityRemoveTraits(.isButton) // VoiceOver reads it as a label
```

Pre-PR this pill lived in a separate floating `CanvasStatusBar` overlay (now removed).

**Integration (`ContentView`):**

```swift
NavigationStack {
    BoardCanvasView(...)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            CanvasNavigationToolbar(
                boardName: boardName,
                activeTool: $activeTool,
                onBack: handleBack,
                onUndo: { undoTrigger = UUID() },
                onRedo: { redoTrigger = UUID() },
                onHome: { homeTrigger = UUID() },
                onAddItem: openImageImporter,
                onSettings: { showingSettings = true }
            )
        }
}
```

`ContentView` no longer hosts a custom overlay layer; the nav bar renders translucent glass over `BoardCanvasView`, which extends edge-to-edge underneath.

**Settings sheet** is still presented from `ContentView` via `.sheet(isPresented: $showingSettings)` when the gear toolbar item fires. See "Canvas Settings Sheet" below.

---

## Canvas Navigation Aids

### Minimap

**Status: Implemented**

**File:** `Features/BoardCanvas/CanvasMinimapView.swift`

A 160×100pt semi-transparent overlay in the bottom-right corner of the canvas that shows where content is relative to the current viewport.

**Architecture:** Pure stateless view — takes `elementRects: [CGRect]` and `viewportRect: CGRect`, recomputed on every body pass.

```swift
struct CanvasMinimapView: View {
    let elementRects: [CGRect]
    let viewportRect: CGRect
}
```

`BoardCanvasView` feeds it via:
```swift
.overlay(alignment: .bottomTrailing) {
    let rects = allElementRects()   // placedImages + placedTexts worldRects
    if !rects.isEmpty {
        CanvasMinimapView(elementRects: rects, viewportRect: viewportCGRect())
            .padding(16)
    }
}
```

Hidden when the canvas is empty (overlay is conditional on `!rects.isEmpty`).

**Rendering (SwiftUI `Canvas`):**
- `worldExtents()` computes the union of all element rects + viewport, expanded by 12% padding — this is the minimap's world frame
- `project(_:world:into:)` scales any world-space `CGRect` into the minimap's pixel space
- Element rects rendered as white rounded rectangles (min 2×2pt so tiny elements remain visible)
- Viewport rendered as a filled `.white.opacity(0.08)` rect + `DesignSystem.Colors.tertiary` stroke
- `.allowsHitTesting(false)` — decorative only
- `.accessibilityHidden(true)` — no semantic content for VoiceOver

### Home Button

**Status: Implemented**

**File:** `Features/BoardCanvas/Tools/CanvasNavigationToolbar.swift`, `BoardCanvasView.swift`

A house icon (title "Fit to Content") in the home+settings group of the toolbar. It animates the camera so every element on the board is visible at once, centered — a zoom-to-fit, not just a re-center.

**Trigger pattern:** Same UUID-binding pattern as undo/redo. `ContentView` owns `@State private var homeTrigger: UUID?`; tapping the toolbar button sets it to `UUID()`. `BoardCanvasView` observes it via `.onChange(of: homeTrigger)` and calls `zoomToFitContent()`, then clears the trigger.

**`zoomToFitContent(animated: Bool = true)`** (on `BoardCanvasView`):
1. Guards `canvasSize != .zero, camera.scale > 0`
2. `guard let bounds = union(of: allElementRects()) else { return }` — no-op on empty canvas
3. `let targetScale = fitScale(for: bounds)`
4. Computes `target = CGSize(width: canvasSize.width/2 - bounds.midX * targetScale, height: canvasSize.height/2 - bounds.midY * targetScale)`
5. If `animated && !reduceMotion`: `.easeInOut(0.4)` animation writing **both** `camera.scale` and `camera.offset` in one block so zoom and pan ease together; `scheduleRefreshVisibleElements()` in the `completion:` block (deferred so images don't pop mid-animation)
6. Otherwise: instant scale + offset set, immediate refresh

**Offset must be derived from `targetScale`, not `camera.scale`.** The screen-center formula multiplies the content center by the scale it will be rendered at; using the pre-zoom scale lands the content off-center by exactly the zoom delta. This is the easiest thing to get wrong when touching this function.

**`fitScale(for bounds: CGRect) -> CGFloat`:**
- Available viewport is `canvasSize` inset by `fitPadding` (64pt) per edge, so the outermost elements clear the toolbar and screen edges instead of sitting flush against them. Each axis is floored at 1 so a canvas narrower than the padding can't produce a zero or negative extent.
- Fit is `min(availableW / bounds.width, availableH / bounds.height)`, then `clamp(min(fit, 1.0), minScale, maxScale)`.
- **Capped at 1.0 — fit only ever zooms out.** A board holding one small image would otherwise be magnified past native size on every home press, which just blurs the reference art. (Figma/Miro do magnify past 100% on zoom-to-fit; this app deliberately doesn't, because the content is raster reference imagery.) Removing the `min(fit, 1.0)` is the one-line change if that call is ever revisited.
- A degenerate axis (zero-width or zero-height bounding rect) is skipped rather than divided by, falling back to the other axis — and to the current `camera.scale` when both are degenerate.

`@Environment(\.accessibilityReduceMotion) private var reduceMotion` is read on `BoardCanvasView` and passed into the animated path.

### Landing Snap

**Status: Implemented**

When a board with content is opened, the viewport automatically fits the content bounding box instead of defaulting to world origin. Shares `zoomToFitContent(animated: false)` with the home button, so opening a board and pressing Home land on the same camera — including the zoom.

**Timing fix — why `DispatchQueue.main.async`:**

The snap fires from `onChange(of: elementsToLoad)` after `applyElements`. The guard in `zoomToFitContent` requires `canvasSize != .zero`, but `canvasSize` is set in `BoardCanvasView.onAppear`. In some SwiftUI lifecycle orderings, `ContentView.onAppear` (which sets `elementsToLoad`) fires before `BoardCanvasView.onAppear` — so the guard would trip. Wrapping the `zoomToFitContent(animated: false)` call in `DispatchQueue.main.async` defers it past the current run-loop drain, guaranteeing all `onAppear` handlers have fired first.

`DispatchQueue.main.async` is intentional here — a bare `Task { }` uses Swift concurrency's cooperative scheduler and does not drain the run loop, so it doesn't carry the same ordering guarantee.

An additional fallback in `onAppear` itself: if elements were already applied before `canvasSize` was available (the inverse race), the snap fires there instead.

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
    ├── GroupToolBehavior      -- tap=toggle selection, drag-on-item=group move, drag-on-empty=marquee select
    └── TextToolBehavior       -- tap-empty=place text (canvas owns this), tap-item=select, drag-on-item=move, drag-on-empty=pan
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

**Text Tool Behavior:**
- Drag on item → select it, enter `.moveItem` mode (same as pointer)
- Drag on empty canvas → `.pan` mode
- Tap on item → select it (delegates to pointer-style selection)
- Tap on empty → handled by `BoardCanvasView`'s tap handler, NOT by `tappedEmpty`. The behavior's `tappedEmpty` only clears the selection (so the new placement becomes the active focus); the actual `insertText(at:)` placement happens at the canvas level because the world point lives in the view's coordinate space, not in the protocol's interface. After placement, `insertText` programmatically auto-swaps `activeTool = .pointer` (Figma convention) so subsequent canvas taps don't keep dropping new drafts.

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
- `SelectionOverlay` — solid 2pt tertiary border + 8 handles, shown on single-selected items
- `GroupSelectionOverlay` — solid 2pt tertiary border + 8 handles, shown on the group bounding box when multiple items are selected. Same line weight as `SelectionOverlay` so multi-select reads as the same affordance as single-select rather than a different visual language. (Previously dashed; converted to solid as part of the selection-chrome polish pass.)
- When multi-selected, individual items show a light semi-transparent border instead of full handles
- `MarqueeOverlayView` — solid 1.5pt tertiary rectangle with 8%-opacity tertiary fill, shown during marquee drag. (Previously dashed.)

**Hide-inactive-handles during resize:**

Both `SelectionOverlay` and `GroupSelectionOverlay` take an `activeHandle: HandlePosition?` parameter. While the user is dragging one handle, the other seven hide so they don't visually compete with the active gesture; the border stays visible. `CanvasSelectionState.resizeHandle` is the unified "which handle is live" state across single-image, single-text, and group resize alike — the three call sites in `BoardCanvasView` all pass `selection.resizeHandle` through. `nil` means "not resizing" and every handle in the overlay's `handles` set renders.

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

**Files:** `CanvasSelectionActionBar.swift`, `SelectionActionBarLayer.swift`

Floating action bar that appears next to the current canvas selection, hosting selection-scoped actions (currently: delete). Chosen over a context menu after trials with `.contextMenu(menuItems:preview:)` — the default preview couldn't elevate the whole group, and a custom preview couldn't blur non-source items.

**Visual Design (`CanvasSelectionActionBar`):**

```swift
Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
    .labelStyle(.iconOnly)     // visible: just the trash icon
    .buttonStyle(.glass)       // native Liquid Glass
    .tint(.red)
    .controlSize(.large)
```

Title is preserved for VoiceOver but hidden visually via `.labelStyle(.iconOnly)`. The native glass button supplies its own material, press animation, and shape — none of the previous hand-rolled `RoundedRectangle` + shadow chrome.

**Positioning — `SelectionActionBarLayer` (persistent + animated):**

The bar is **permanently mounted** in `BoardCanvasView`'s ZStack via `SelectionActionBarLayer`, not conditionally inserted. Reason: a Liquid Glass backdrop filter on a freshly inserted, top-`zIndex`, `.position()`-ed view captures its backdrop *before* the canvas beneath it has settled in that compositing pass — caches the wrong light/dark variant until an unrelated re-composite forces a re-sample. The "tap again to fix it" behavior. A persistent view with stable identity never takes that bad first sample.

Layer responsibilities:
- **Show/hide** — opacity 1/0 driven by `isVisible = boundingBox != nil && !isInteracting`, where `isInteracting = isDragging || isResizing || isGroupResizing || isMarqueeing`.
- **Position** — `displayCenter = isVisible ? liveCenter : lastCenter`. Parking at `lastCenter` while interacting prevents re-publishing a moving position every gesture frame, which would otherwise spawn a fresh `.snappy` animation per frame on the (invisible) bar — invisible but real frame-budget cost that showed up as text-resize jitter.
- **Position tracking** — `@State private var lastCenter` is updated via `.onChange(of: liveCenter)`, guarded by `isVisible` so it doesn't drift during interactions. Live center comes from `boundingBox.midX/maxY * scale + offset (+ 32pt gap)`.
- **Animation gating** — `transitionAnimation` returns `nil` while interacting, so the bar snaps to/from hidden instantly at drag start/end instead of animating opacity + position for 0.2s on top of the gesture (the source of "first ~0.2s of every drag is jittery" before this fix).

Host wiring (`BoardCanvasView`):

```swift
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
```

**Delete Flow:**
- `deleteSelection()` fetches authoritative `CMCanvasElement`s from `LocalBoardStore` via `elements(for:)` before snapshotting — avoids fabricating elements from the view's `placedImages` cache, which could be stale
- Snapshots feed a `.delete(snapshots:)` command pushed onto `CanvasCommandHistory`, then `removeElements()` applies the change
- Fallback paths: `fallbackImageElement(for:)` and `fallbackTextElement(for:)` handle rare view/store desync (image and text branches)

---

### Text Elements

**Status: Implemented**

**Files:**
- `BoardCanvasView.swift` (`PlacedText` struct, `TextElementView` nested struct, `insertText`/`commitTextEdit`, resize state, render path)
- `Features/BoardCanvas/CanvasTextField.swift` (UIKit-backed editing input)
- `Features/BoardCanvas/CanvasToolBehavior.swift` (`TextToolBehavior`)
- `Features/BoardCanvas/CanvasCommandHistory.swift` (`.editTextContent`, `.resizeText`, augmented `.groupResize`)
- `Persistence/CanvasModels.swift` (`CMCanvasElementPayload.text` + `wrapWidth`)

Text lives alongside images as a parallel `placedTexts: [PlacedText]` array on `BoardCanvasView`, not unified into a single `PlacedItem` enum yet. Unification was deferred until a third element type appears — until then, two arrays + branched paths are simpler than a protocol abstraction.

**Data model — `PlacedText`:**

```swift
private struct PlacedText: Identifiable {
    let id: UUID
    var content: String           // edited live; persisted to store on commit
    var worldRect: CGRect         // origin = anchor; size derives from rendered geometry
    var zIndex: Int
    var fontSize: CGFloat         // base/world units, NOT pre-scaled by canvas zoom
    var color: Color
    var wrapWidth: CGFloat?       // nil = auto-width; set = fixed wrap width (Figma convention)
}
```

`fontSize` is the single authoritative typographic state — corner-drag resize, the future font-size picker, and group resize all mutate this same field. `worldRect.size` is downstream-derived from the rendered geometry (see "scaleEffect rendering" below) — never written to directly except for `worldRect.origin`.

**scaleEffect rendering — why text uses a different visual-scale strategy than images:**

Images render at `worldRect.size * scale` (frame and position both pre-scaled by canvas zoom). Trying the same approach for text caused a sub-pixel layout drift bug: a wrap-locked string that fit on one line at zoom 1 wrapped to two lines at zoom 0.2 because CoreText's hinting at small fonts makes glyphs slightly wider than a linear scale predicts. Layout decisions weren't invariant under zoom.

Fix: text renders at **base/world units** (no `* scale` on font, frame, or wrap width) and then has `.scaleEffect(scale, anchor: .center)` applied at the end. Layout happens once at base scale; scaleEffect only visually scales the result. Wrapping decisions become invariant — the same string fits the same way at every zoom level.

```swift
sizedContent           // base-scale layout: font, frame, wrap all in world units
    .padding(4)
    .overlay { ... }   // multi-select dim border (cosmetic, scales with text)
    .scaleEffect(scale, anchor: .center)
    .onGeometryChange(
        for: CGSize.self,
        of: { CGSize(width: $0.size.width.rounded(),
                     height: $0.size.height.rounded()) }
    ) { rounded in
        // newSize is BASE/world-unit size (scaleEffect doesn't change layout).
        if placed.worldRect.size != rounded { placed.worldRect.size = rounded }
    }
```

`onGeometryChange` is the loop that keeps `worldRect.size` in sync with the actual rendered text — used by hit-testing, marquee, group bbox math.

**Rounding inside `of:` (not the action closure):** during a resize drag, intermediate `fontSize`/`wrapWidth` values hit CoreText sub-pixel hinting, which fluctuates the measured size by fractions of a point per frame. Without filtering, every fluctuation fires `onGeometryChange` → writes the binding → re-renders → re-measures → visible jitter. Rounding inside `of:` means the observer only fires when the *rounded* value changes, so sub-pixel noise doesn't trigger the action at all. The bbox still tracks real drag-driven size changes (which are multi-point deltas).

**Auto-width vs wrap-mode rendering:**

`PlacedText.wrapWidth` toggles between two distinct render paths:

- **Auto-width (`wrapWidth == nil`):** Text grows horizontally with content; only manual newlines (Enter) create line breaks. The editing TextField uses a `ZStack(alignment: .topLeading)` with a hidden sacrificial `Text(content).fixedSize(horizontal: true, vertical: true).opacity(0)` underneath that drives the ZStack's intrinsic width to the longest line. The TextField then fills that exact width and never has to auto-wrap. Without the sacrificial Text, an `axis: .vertical` TextField would wrap content into its `minWidth` while typing and then unwrap on commit when the static Text replaces it — visible jump.
- **Wrap mode (`wrapWidth != nil`):** Explicit `.frame(width: wrapWidth, alignment: .leading)` plus `.fixedSize(horizontal: false, vertical: true)`. Text reflows inside the fixed width; height stays content-derived.

The body splits into `body` → `sizedContent` → `textOrField` so the auto-width path doesn't carry an unconditional `.frame(width:)` modifier. Earlier versions had `.frame(width: placed.wrapWidth.map { $0 * scale })` always in the chain; even when nil it interacted with the trailing `.fixedSize` to produce wrapping at small fonts.

**`CanvasTextField` — UITextView wrapper for editing:**

`File:` `CanvasTextField.swift`

SwiftUI's `TextField` has no API to control caret thickness. The native UIKit caret is a fixed ~2pt regardless of font size, and the surrounding `.scaleEffect` shrinks it to sub-pixel at low zoom. `CanvasTextField` is a `UIViewRepresentable` wrapping `CanvasUITextView` (a `UITextView` subclass) that overrides `caretRect(for:)`:

```swift
override func caretRect(for position: UITextPosition) -> CGRect {
    let original = super.caretRect(for: position)
    let targetVisible: CGFloat = 2.5
    let thickness = targetVisible / max(canvasScale, 0.0001)
    return CGRect(x: original.origin.x, y: original.origin.y,
                  width: thickness, height: original.height)
}
```

Base thickness is `2.5 / canvasScale` so that after `scaleEffect(scale)` brings it down by `scale`, visible thickness lands at exactly 2.5pt at every zoom × font combination. Caret height continues to follow text height — only thickness is held constant.

Other `CanvasTextField` notes:
- `textContainerInset.right = caretThickness` reserves trailing space inside the view bounds so the caret doesn't clip at end-of-text. SwiftUI `TextField` has analogous built-in slack; `UITextView` doesn't unless asked.
- Focus is driven from the `isEditing` flag in `updateUIView` via `becomeFirstResponder()` / `resignFirstResponder()` (guarded by `isFirstResponder` to avoid redundant calls). `@FocusState` isn't needed — the wrapper owns its first-responder lifecycle.
- `Coordinator` implements `UITextViewDelegate.textViewDidChange` to push content into the binding, and `textViewDidEndEditing` to fire `onCommit` (which calls `commitTextEdit(id:)` in the parent).
- `tintColor = DesignSystem.Colors.primary` so caret + selection highlight are dark, contrasting the tertiary-blue editing border (blue-on-blue would blend).
- `textContainerInset = .zero` and `lineFragmentPadding = 0` so editing layout matches the static `Text` used post-commit (no jump).

**Edit lifecycle:**

`@State private var editingTextID: UUID? = nil` on `BoardCanvasView` — the id of the text currently being edited, or nil. `@State private var pendingTextInserts: Set<UUID>` tracks newly-placed drafts. `@State private var editingTextOriginalContent: String?` snapshots content at re-edit start so undo can revert.

Placement (text tool active + tap empty canvas):

```swift
private func insertText(at worldPoint: CGPoint) {
    if let prior = editingTextID { commitTextEdit(id: prior) }
    let id = UUID()
    placedTexts.append(PlacedText(id: id, content: "", worldRect: ..., ...))
    nextZIndex += 1
    pendingTextInserts.insert(id)
    selection.clearSelection()
    editingTextID = id
    skipNextToolChangeCommit = true
    activeTool = .pointer    // Figma auto-swap; the skip flag stops the
                             // resulting onChange(of: activeTool) from
                             // committing the just-placed draft
}
```

Re-edit (tap-once-selects, tap-twice-edits):

```swift
.onTapGesture {
    if selection.selectedIDs.count == 1 && selection.selectedIDs.contains(id) {
        selection.clearSelection()
        editingTextOriginalContent = placed.content   // snapshot for undo
        editingTextID = id
        return
    }
    // ... else delegate to active tool's tappedItem
}
```

Standard across pointer/group/text tools because all three can produce a single-text selection.

`commitTextEdit(id:)` is the shared commit point. Idempotent for newly-placed ids via `pendingTextInserts.remove(id)`. For re-edits, scoped to `editingTextID == id` so a re-fire (selection-change commit followed by focus-loss) sees a nil original on the second pass and skips a duplicate command push.

Commit branches:
- **Newly placed, empty content** → discard silently, no history.
- **Newly placed, non-empty** → push `.insert` command, upsert to store.
- **Re-edit, empty content** → push `.delete` whose snapshot rebuilds the element from the *original* content (so undo restores the pre-clear text), delete from store.
- **Re-edit, content changed** → push `.editTextContent(from, to)`, upsert. Same content as start = no command push.
- **Re-edit, content unchanged** → upsert anyway (idempotent), no command.

**Drag while editing — disabled by design:**

Drag-to-move is disabled when a text element is being edited. The drag handler's first `onChanged` event checks `editingTextID` and the world-rect of the editing text; if the drag started inside it, `currentDragMode` is set to `.none` and the gesture no-ops for the rest of its lifetime (subsequent onChanged events early-return; onEnded skips its commit dispatcher).

This matches the convention used by Apple Notes / Pages / Keynote and by Figma / Miro: editing and moving are mutually exclusive modes. To move an editing text the user must first tap outside (which commits the edit via the existing selection-change / empty-canvas-tap paths), then drag in selection mode.

The convention also sidesteps a fight between SwiftUI's `DragGesture` and UITextView's internal text-selection gestures. UITextView's recognizers grab the live touches; SwiftUI's drag only sees the start and end translations, producing a "first frame / last frame teleport" if we tried to live-track the move. Disabling the move drag while editing leaves UITextView's native text-selection behavior intact as the natural fallback for in-field drags.

**Commit triggers:**

The wrapper's `textViewDidEndEditing` fires `onCommit` when the UITextView resigns first-responder, but UITextView doesn't auto-resign when the user taps another SwiftUI view — only when explicitly told to. Three explicit commit paths cover the gaps:

1. `onChange(of: selection.selectedIDs)` — tapping any other element (image or text) changes selection; the watcher calls `commitTextEdit(editing)` if `selectedIDs` now contains anything other than the editing text. Guarded with `!newIDs.isEmpty` so a `clearSelection()` (e.g. inside `insertText`) doesn't commit-and-remove the brand-new draft in the same render frame (which crashed before the guard was added).
2. `onChange(of: activeTool)` — tapping a different toolbar button commits before swapping. The `skipNextToolChangeCommit` one-shot flag bypasses this for the auto-swap fired by `insertText` itself.
3. Empty-canvas tap handler (`onTapGesture(coordinateSpace: .local)` on the grid Canvas) — calls `commitTextEdit` at the top before deciding whether to place a new text or run the tool's `tappedEmpty`.

The selection-change watcher is the most common path; the other two cover edge cases (tool switch, empty-tap commit).

**Resize semantics — corners scale font, side handles set wrap width:**

Solo-text selection shows handles at the four corners + left/right edge centers (top/bottom hidden — text height is content-derived, no meaningful axis to drag). `SelectionOverlay` accepts a `Set<HandlePosition>` parameter so text passes a restricted set; `TextElementView.textHandles` is `fileprivate` so the canvas-level external chrome can use the same set.

`hitTestHandle` returns a new `.singleTextItem(handle, text)` case for solo-text hits and rejects top/bottom edges. Multi-element selections fall through to the existing `.group` path (now augmented to handle text).

`applyTextResize(translation:)` handles three handle classes:
- **Corner drag (any of 4)** → uniform Freeform-style font scale. Reuses the aspect-locked `computeResizedRect` to derive a width ratio, multiplies the start fontSize by that ratio. If wrapWidth was set, scales it proportionally. Origin tracks the new rect (opposite corner anchored). Min font 8pt floor.

  `computeResizedRect` accepts an optional `minDimension` parameter (default = `minImageDimensionWorld`, 64pt). The text path overrides this to `startRect.width * (minTextFontSize / startFontSize)` so the rect floor matches the text's own font-size minimum. Without the override, the rect would clamp at 64pt before fontSize hit its 8pt floor — visible "snap" when the user shrinks small text.
- **Right-edge drag** → sets `wrapWidth`, left edge anchored. Reference width = existing wrapWidth or current `worldRect.width` (auto-width text). Min wrap width 40pt floor.
- **Left-edge drag** → sets `wrapWidth` AND shifts `origin.x = startRect.maxX - newWrap` so the right edge stays anchored (Figma convention).

Direct mutation of `placed.fontSize` / `wrapWidth` / `origin` during drag is fine: the view re-renders, `onGeometryChange` re-derives `worldRect.size`, and undo captures the start state for reversal.

**`.resizeText` command:**

```swift
case resizeText(
    elementID: UUID,
    fromFontSize: CGFloat, toFontSize: CGFloat,
    fromWrapWidth: CGFloat?, toWrapWidth: CGFloat?,
    fromOrigin: CGPoint, toOrigin: CGPoint
)
```

Captures every piece a single resize gesture can affect, including origin shifts from left-edge drags. `applyTextResizeState(elementID:fontSize:wrapWidth:origin:)` is the shared restore helper used by both commit and undo/redo.

**Group resize includes text:**

Multi-selection containing text now exposes group-resize handles (previously suppressed). Text in the selection scales uniformly with the bbox change: fontSize and wrapWidth both multiply by the **geometric mean** of the bbox width and height ratios (`sqrt(widthRatio * heightRatio)`), and origin tracks the bbox via the same `scaledRect` helper that drives image positioning. Matches Freeform's "everything in the group scales together" feel.

The geometric mean is what makes text scale on top/bottom-edge group drags. A naive width-only ratio (`newBBox.width / bboxStart.width`) would be 1.0 for vertical-only resizes, leaving text size unchanged while images stretched. Geometric mean folds both axes in: corner drags (aspect-locked, widthRatio == heightRatio) collapse to either ratio, and side drags pick up the changed axis through the unchanged one's `1.0` factor.

`.groupResize` command is augmented with `fromTextStates` and `toTextStates` dicts of `TextResizeSnapshot` (fontSize/wrapWidth/origin) parallel to the existing `fromRects`/`toRects` for images. Pure-image groups have empty text dicts; pure-text groups have empty rect dicts. One undo press atomically reverts everything.

Unlike images (which use `scaledRect` during render), text mutates `placedTexts[idx]` directly each frame in `applyGroupResize` because the text render path is font-size + frame, not a worldRect-driven frame. Live mutation is cheap for text; for images it's avoided to skip unnecessary re-renders of large data.

**`applyGroupResizeApply` batches all store writes into one mutation.** Naive separate calls to `applyResizeRects` and `applyTextResizeState` per element would each fire their own `enqueueStoreMutation`, and that helper *cancels* any in-flight mutation — so only the last enqueued upsert in the loop would actually reach the store, silently losing image-rect updates and earlier text updates. The shared restore helper does in-memory mutations synchronously, pre-builds the text `CMCanvasElement`s, then issues a single `enqueueStoreMutation` that fetches every image element + appends every text element + upserts the combined batch. Cancellation only kills work that hasn't been fully prepared yet, so undo/redo of a group resize commits all affected elements atomically.

**External selection chrome — handles + editing border render at canvas level:**

`scaleEffect` shrinks any `.overlay { ... }` inside the text element along with the text. A 10pt selection handle becomes 2pt at zoom 0.2 — invisible and untappable. To keep handles + editing border at touch-friendly screen sizes regardless of zoom, both render externally in `BoardCanvasView`'s body using world-space coordinates × scale (same pattern as image group selection):

```swift
// Solo-text selection handles
if selection.selectedIDs.count == 1, let placed = ..., editingTextID != selectedID, ... {
    let screenRect = CGRect(x: placed.worldRect.origin.x * scale + offset.width, ...)
    SelectionOverlay(handles: TextElementView.textHandles)
        .frame(width: screenRect.width, height: screenRect.height)
        .position(x: screenRect.midX, y: screenRect.midY)
        .allowsHitTesting(false)
}

// Editing border (separate, fires for editingTextID instead of selection)
if let editingID = editingTextID, let placed = ... {
    Rectangle().strokeBorder(DesignSystem.Colors.tertiary, lineWidth: 1.5)
        .frame(...).position(...)
}
```

The multi-select dim border for text-in-group stays inside the scaleEffect — it's a low-priority cosmetic indicator and the group bbox handles already provide the primary affordance, so the visual shrink at low zoom is acceptable.

**Save-on-back race fix:**

`commitTextEdit`'s store upsert runs through `enqueueStoreMutation` (async Task). Pressing the back button while editing fires the snapshot trigger, which previously read `canvasStore.allElements()` before the in-flight commit landed — manifest got written without the typed text.

The `snapshotTrigger` handler now:
1. Calls `commitTextEdit(editing)` synchronously to fire the store upsert.
2. Captures `storeMutationTask` outside the Task so the closure has a stable reference.
3. Awaits `pendingMutation?.result` before reading `allElements()`.

Result: the snapshot includes everything the user just typed, no matter how quickly they pressed back.

**Persistence integration:**

`CMCanvasElementPayload.text` and `BoardArchiver.ManifestPayload.text` mirror `PlacedText`'s fields (content, fontName, fontSize, color, wrapWidth). `wrapWidth` is encoded via `encodeIfPresent` and decoded via `decodeIfPresent` so older `.refboard` files (no `wrapWidth` key in their manifests) load cleanly with `wrapWidth = nil` (auto-width). See `architecture-backend.md` for the Codable evolution details.

**Per-element undo command coverage:**

| Action | Command | Notes |
|--------|---------|-------|
| Tap-create text + commit non-empty content | `.insert` | Fired by `commitTextEdit` for `wasNewlyPlaced && !empty`. |
| Re-edit text content | `.editTextContent(from, to)` | Only when content actually changed (no-op edits skip the push). |
| Re-edit cleared all content | `.delete` | Snapshot's element is rebuilt from original content so undo restores text, not empty. |
| Move text | `.move` | Same command as image move; `applyMoveDelta` walks both arrays. |
| Resize text (corner / side) | `.resizeText` | Captures fontSize + wrapWidth + origin tuple. |
| Group resize incl. text | `.groupResize` | Augmented with text-state dicts alongside image rect dicts. |
| Delete text via action bar | `.delete` | `deleteSelection` snapshots both image and text elements; `applyResizeRects` filters text ids defensively. |

---

### Canvas Settings Sheet

**Status: Implemented (native Liquid Glass material)**

**File:** `Features/BoardCanvas/Settings/CanvasSettingsView.swift`

Settings is now a `ToolbarItem` in `CanvasNavigationToolbar` (the gear button), opening a translucent material sheet over the canvas. The standalone `CanvasSettingsButton.swift` and `CanvasOverlayLayout.swift` have been removed.

**Structure:**

```swift
NavigationStack {
    Form {
        Section("Canvas") {
            ColorPicker("Canvas Color", selection: $canvasColor, supportsOpacity: false)
            Toggle("Show Grid", isOn: $showGrid)
        }
        .listRowBackground(Color.clear)

        Section("About") {
            LabeledContent("Version", value: "1.0.0")
        }
        .listRowBackground(Color.clear)
    }
    .scrollContentBackground(.hidden)        // reveal the sheet glass
    .navigationTitle("Settings")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
}
.tint(DesignSystem.Colors.tertiary)
.presentationBackground(.thinMaterial)       // translucent frosted-glass sheet
.preferredColorScheme(canvasColorScheme)     // match canvas darkness
```

Key decisions:

- **`.presentationBackground(.thinMaterial)`** — gives the sheet a translucent frosted-glass surface that blurs the canvas behind it. A sheet sits behind a dimming scrim, so a true Liquid Glass `.glassEffect()` modifier can't sample the live canvas the way the toolbar buttons can; the material is the correct sheet-level equivalent.
- **`.scrollContentBackground(.hidden)`** + `.listRowBackground(Color.clear)` on each section — strips `Form`'s opaque grouped background and clears row backgrounds so the presentation material shows through everywhere, not just margins.
- **`canvasColorScheme` (light/dark from canvas luminance)** — keeps the panel's text/control color scheme matched to the canvas behind it, so opening Settings over a dark canvas doesn't flash a bright panel. Computed from `Color.Resolved` via `@Environment(\.self)` (Rec. 709 luminance, threshold 0.5):

  ```swift
  private var canvasColorScheme: ColorScheme {
      let rgb = canvasColor.resolve(in: environment)
      let lum = 0.2126 * Double(rgb.red) + 0.7152 * Double(rgb.green) + 0.0722 * Double(rgb.blue)
      return lum < 0.5 ? .dark : .light
  }
  ```

- **Native color well** — replaced the previous invisible-`ColorPicker`-over-a-pill hack with the standard `ColorPicker("Canvas Color", selection:, supportsOpacity: false)`. Version row uses native `LabeledContent`.
- **Single `.tint(DesignSystem.Colors.tertiary)`** at the `NavigationStack` propagates to the toggle, color well, and Done button — no per-element foreground/tint overrides.

**Removed settings:**

The "Toolbar Position" picker (`left` / `right`) and the `ToolbarSide` enum were dropped along with the floating overlay system — the toolbar is now native top-bar and side-of-canvas placement isn't a meaningful knob anymore.

**Functional Settings:**

1. **Canvas Color** — `@Binding var canvasColor: Color`, applied via `.background(canvasColor)` on the canvas ZStack. Default `Color(uiColor: .systemBackground)` for new boards and legacy v1 files with no saved preference, so the canvas adapts to the user's light/dark mode until they pick something explicit. Saved as `#RRGGBB` in the board's manifest once picked — see "Canvas Color Persistence" below.
2. **Show Grid** — `@Binding var showGrid: Bool`, drives the grid `Canvas` layer in `BoardCanvasView`. Default `true`.

---

### Canvas Color Persistence

**Status: Implemented**

**Files:** `ContentView.swift`, `RootView.swift`, `AppOpenHandler.swift`, `FilePickerView.swift`, `DesignSystem/Colors.swift` (frontend side); see `architecture-backend.md` → "Export Package" for the manifest schema.

The canvas color round-trips through the board's `.refboard` manifest. The split-of-concerns: the SwiftUI layer owns the live `Color` and hex-conversion (since resolving an adaptive `Color` to concrete RGB needs an `EnvironmentValues`), the backend layer owns the on-disk representation (`canvasColor: String?` in the manifest, see backend doc).

**Plumbing chain:**

```
manifest.json:canvasColor (String?)
    ↓ BoardArchiver.importElements → ImportResult.canvasColorHex (String?)
    ↓ FilePickerView.onBoardSelected callback (elements, url, hex)  — or AppOpenHandler.importedCanvasColorHex on .onOpenURL
    ↓ RootView.initialCanvasColorHex (String?)
    ↓ ContentView.init(initialCanvasColorHex:)
    ↓ @State canvasColor (Color)  ← initialCanvasColorHex.flatMap(Color.init(hex:)) ?? Color(uiColor: .systemBackground)
    ↓ ColorPicker + .background(canvasColor) on canvas ZStack
```

**`ContentView` state model:**

```swift
@State private var canvasColor: Color              // live, may be adaptive (system bg)
@State private var savedCanvasColorHex: String?    // what gets written to manifest; nil = no preference
@State private var canvasColorDirty = false        // OR'd into the save gate

init(..., initialCanvasColorHex: String? = nil, ...) {
    let initial = initialCanvasColorHex.flatMap(Color.init(hex:))
        ?? Color(uiColor: .systemBackground)
    _canvasColor = State(initialValue: initial)
    _savedCanvasColorHex = State(initialValue: initialCanvasColorHex)
}
```

**Why three pieces of state instead of one:**

1. **`canvasColor`** is what the canvas + ColorPicker bind to. May be an adaptive `Color(uiColor: .systemBackground)` whose resolved RGB depends on the environment's color scheme.
2. **`savedCanvasColorHex`** is the concrete hex that the manifest holds. Seeded from `initialCanvasColorHex` and only mutated when the user actually picks a color (resolved at pick-time, not at save-time):

   ```swift
   .onChange(of: canvasColor) { _, newValue in
       savedCanvasColorHex = canvasColorHexString(from: newValue.resolve(in: environment))
       canvasColorDirty = true
   }
   ```

   Resolving once at pick-time (vs every save) keeps "nil == follow system" stable across element-edit autosaves on boards the user hasn't touched the color on. Without this split, an element-only edit would have baked the current system background into the file, silently breaking the "no preference" contract.

3. **`canvasColorDirty`** flips the save gate. `BoardCanvasView`'s dirty flag only tracks the element store, so a color-only change wouldn't otherwise trigger autosave (`wasDirty` would come back `false` and `saveInPlace` would bail). Both save paths now gate on `wasDirty || canvasColorDirty` and clear `canvasColorDirty` alongside `markCleanTrigger` after a confirmed-successful write.

**Hex helpers (`DesignSystem/Colors.swift`):**

```swift
extension Color {
    nonisolated init?(hex: String) { /* parses #RRGGBB or RRGGBB */ }
}

// Resolved color → "#RRGGBB". Caller resolves Color via env, this just formats.
func canvasColorHexString(from resolved: Color.Resolved) -> String { ... }
```

`init(hex:)` is `nonisolated` because the project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` would otherwise make the synthesized init main-actor-isolated, and `ContentView.init` runs in a non-isolated context.

**Pick-time semantics (caveat):**

The hex is captured at the moment the `.onChange(of: canvasColor)` fires, in whatever color scheme the env is in. If a user picks a color via `ColorPicker`'s "System Colors" tab while in dark mode, the saved hex is the dark-mode resolution of that system color — reopening the board in light mode does not adapt. The contract is "saved color = the color you last had on screen," which matches single-resolved behavior; if we ever want "follow system" as an explicit option, that'd be a separate toggle keeping `savedCanvasColorHex` nil with a sentinel.

**Security-scoped access (Copilot fix):**

`BoardArchiver.importElements` owns its own `startAccessingSecurityScopedResource` / stop pair. `FilePickerView.openBoard` previously wrapped its detached-task body in a second, redundant pair; that wrap has been removed so the archiver remains the single owner of the scope.

---

### Design System

**Status: Implemented**

**Files:** `DesignSystem.swift`, `Colors.swift`

Central design token system for consistent styling across the application.

**Color Palette:**

```swift
DesignSystem.Colors.primary     // #191919 (25, 25, 25)   - Dark gray
DesignSystem.Colors.secondary   // #535353 (83, 83, 83)   - Medium gray
DesignSystem.Colors.tertiary    // #3977F8 (57, 119, 248) - Saturated blue
DesignSystem.Colors.text        // #FFFFFF (255, 255, 255) - White
DesignSystem.Colors.destructive // #FE8686 (254, 134, 134) - Red
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

### Other UI Components

**FilePickerView (Landing Page)**

**Status: Implemented**

**Files:** `FilePickerView.swift`, `RecentBoardsList.swift`, `RecentBoardRow.swift`, `LiftPressStyle.swift`, `RecentBoardsManager.swift`

The app's landing screen with three entry paths to the canvas and a recent boards section.

**Entry Paths:**

1. **"New Board" (primary CTA)** — `.buttonStyle(.glassProminent)` + tertiary tint, presents a `.fileExporter` for `Untitled Board.refboard`. On success, an empty canvas opens with that save location as its `currentBoardURL`, so the back button can write straight to it.
2. **"Open Board" (secondary)** — `.buttonStyle(.glass)` + tertiary tint, opens `.fileImporter` for `.refboard` files. Imports via `BoardArchiver.importElements` on a detached task, records in recents, passes elements + URL to `ContentView`
3. **Drag-and-drop** — drop images/GIFs onto the dashed rectangle area. `.contentShape(.rect)` ensures the entire padded area is a valid drop target, not just the icon/text

**Visual Design:**
- Background stays flat `DesignSystem.Colors.primary` — Liquid Glass on a flat dark fill renders muted (Apple's docs explicitly call this out), but we accept it for the larger surfaces (drop zone, recents) and reserve glass for the CTA buttons where `.buttonStyle(.glass)` has its own backdrop-independent fallbacks.
- Large photo icon (`photo.on.rectangle.angled`, `@ScaledMetric` for Dynamic Type) with `.accessibilityHidden(true)`
- Dashed border rectangle highlights on drag target (`isTargeted` state)
- "New Board" and "Open Board" buttons side-by-side below as native glass buttons
- "Recent Boards" section below buttons (up to 5 entries) — see `RecentBoardsList` / `RecentBoardRow` below
- Error alert (`showImportError` bool + `importErrorMessage` string) for failed imports

**Recent Boards List (`RecentBoardsList` + `RecentBoardRow`):**

The list is a flush stack of per-row cards rather than one shared container with hairline dividers. Each row owns its own background so a press effect (`LiftPressStyle`) scales the whole card, not just the inner content. Rows stack flush (`VStack(spacing: 0)`) with only the first row's top corners and last row's bottom corners rounded via `UnevenRoundedRectangle` — the group reads as one continuous shape while each row remains independently pressable.

```swift
ForEach(Array(recents.enumerated()), id: \.element.id) { index, entry in
    RecentBoardRow(
        entry: entry,
        isFirst: index == 0,
        isLast: index == recents.count - 1,
        onTap: { onOpen(entry) }
    )
}
```

**`LiftPressStyle` (`Features/FilePicker/LiftPressStyle.swift`):**

Custom `ButtonStyle` that mimics the bubble/lift of a native glass button on plain rows. Scale `1.02` + lift `−2pt y` on press, spring-released:

```swift
struct LiftPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 1.02 : 1.0)
            .offset(y: configuration.isPressed ? -2 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6),
                       value: configuration.isPressed)
    }
}
```

Used on the recents rows where we want tactile press feedback without the full Liquid Glass material (which doesn't render correctly on the flat dark background).

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
    // Third parameter is the saved canvas color hex from the manifest, or
    // nil for legacy v1 files. `ContentView` falls back to system background
    // when nil.
    onBoardSelected: ([CMCanvasElement], URL, String?) -> Void,
    onFilesDropped: ([URL]) -> Void
)
```

`onNewBoard` receives the save URL chosen in the file exporter so `ContentView` can seed `currentBoardURL` for save-on-back.

**Integration:**
- `RootView` hosts `FilePickerView` and routes to `ContentView` based on which callback fires
- `initialBoardURL` is tracked through `RootView` → `ContentView` so save-on-back writes to the correct location

### Save-on-Back Flow

Back navigation is wired through the leading toolbar's back chevron (see "Canvas Navigation Toolbar"). Floating `CanvasStatusBar`/`CanvasBackButton` have been removed.

1. Back chevron tap sets `pendingBackNavigation = true` and triggers a canvas snapshot via `snapshotToken`
2. `onSnapshot` callback checks the flag — if pending back, calls `saveAndGoBack(elements:wasDirty:)`
3. `saveAndGoBack` writes to `currentBoardURL` via `BoardArchiver.export` on a detached task, flips `markCleanTrigger`, then calls `onBack()` which sets `showCanvas = false` in `RootView`
4. If the export throws, an alert offers "Discard & Leave" or "Stay"; otherwise navigation proceeds

Because "New Board" requires choosing a save location up front, `currentBoardURL` is always set by the time the canvas appears, so the back chevron always has somewhere to write to.

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

## Known Refactor Opportunities

These are pre-existing trends amplified by the text-elements PR. None are correctness issues; all are scale / hygiene items worth a dedicated cleanup PR before the file becomes harder to navigate.

### `BoardCanvasView.swift` is too large

**Status as of text-elements branch:** ~2,356 lines total, `body` ~515 lines.

The `body` property runs through several distinct render passes that are now interleaved:
- Background grid `Canvas`
- Image `ForEach`
- Text `ForEach`
- Solo-text selection chrome (external)
- Editing border (external)
- Marquee overlay
- Floating action bar
- Group bounding box overlay
- Drag gesture chain
- Multiple `.onChange` handlers (snapshot, mark-clean, load, active-tool, selection-change, undo/redo triggers)

Each render pass is a candidate for extraction into its own `View` struct in its own file, per `references/views.md` ("Strongly prefer to avoid breaking up view bodies using computed properties or methods that return `some View`. Extract them into separate `View` structs instead, placing each into its own file.").

**Suggested split (rough sketch — refine when actually doing the refactor):**
- `BoardCanvasGridLayer` — the `Canvas` grid background
- `PlacedImagesLayer` — the image `ForEach` + per-image rendering
- `PlacedTextsLayer` — the text `ForEach` + per-text rendering
- `SelectionChromeLayer` — solo-text handles, editing border, group bbox, action bar
- `BoardCanvasView` keeps state ownership, gesture wiring, and composition.

### Multiple types in one file

Resolved by the spring-cleaning extraction. `BoardCanvasView.swift` is now ~2120 lines (down from ~2470), containing only `BoardCanvasView`. The other types now live in:
- `Features/BoardCanvas/Elements/PlacedImage.swift`
- `Features/BoardCanvas/Elements/PlacedText.swift`
- `Features/BoardCanvas/Elements/TextElementView.swift`
- `Features/BoardCanvas/Elements/FileImageView.swift`
- `Features/BoardCanvas/Elements/ImageCache.swift`
- `Features/BoardCanvas/Import/CanvasDropDelegate.swift`
- `Features/BoardCanvas/Import/ItemProviderHelpers.swift` (the `loadURLsFromProviders` function + `NSItemProvider` extension)

The duplicate file-loading code that previously existed in `InsertFileControl.swift` is also resolved: `InsertFileControl` was deleted (it was never instantiated outside its own `#Preview`) and both the canvas drop handler and `FilePickerView` now call into `Import/ItemProviderHelpers.swift`.

### Pre-existing modern-concurrency cleanup

**`Task.sleep(nanoseconds:)` (`BoardCanvasView.swift` ~line 1030 in `scheduleRefreshVisibleElements`)** — `references/api.md` rule says use `.sleep(for:)` instead. Pre-existing on `main`.

**`DispatchQueue.main.async` in trigger-clear patterns (`BoardCanvasView.swift`)** — Several trigger bindings (`undoTrigger`, `redoTrigger`, `homeTrigger`, `externalInsertURLs`) are cleared via `DispatchQueue.main.async`. `references/swift.md` says no GCD. The `elementsToLoad` handler intentionally uses `.main.async` because its run-loop drain guarantee is load-bearing for the landing snap (see "Landing Snap" above). The others are pre-existing and can be migrated to `Task { @MainActor in ... }` in a cleanup PR.

(The text-elements PR introduced one `DispatchQueue.main.async` in `CanvasTextField.swift` for `becomeFirstResponder` — already converted to `Task { @MainActor }` per the rule.)

### Toolbar accessibility labels

Resolved by the native-toolbar migration. Every button in `CanvasNavigationToolbar` now uses `Label("Title", systemImage:)`, which carries the title for both VoiceOver and the system overflow menu. The active tool also gets `.accessibilityAddTraits(.isSelected)` so the selection state isn't conveyed by color alone. The standalone `CanvasSettingsButton` / `CanvasOverlayLayout` back button are deleted.

### `BoardCanvasView`'s per-text `.onTapGesture` mixes layout + state-machine logic

The closure inside the text `ForEach`'s `.onTapGesture` handles: tap-on-sole-selected-text → re-edit; tap-on-other-text → tool-routed selection. Branches on `selection.selectedIDs` + `editingTextID` and dispatches a Task. Per `references/views.md` ("Button actions should be extracted from view bodies into separate methods"), this belongs in a method on `BoardCanvasView`. Not extracted in this PR because the focus/selection state machine was being actively iterated and behavioral risk was high.

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
