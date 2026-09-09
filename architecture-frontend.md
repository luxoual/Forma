# Frontend Architecture (Dev A)

⚠️ This document is maintained by **Dev A (Frontend/Canvas)**.

It describes the UI and canvas code **as actually built** — not plans, not ideas. If something here isn't in the code, it shouldn't be here.

**How this doc is written:** plain language first, precise names second. Every section starts with what the thing does in ordinary words, then gets specific. Exact names (`BoardCanvasView`, `camera.scale`), file paths, and numbers are kept literal so you can search for them. See `context.md` → "How to write documentation" for the full rule.

---

## Words we use a lot

Read this once and the rest of the doc gets easier.

| Word | What it actually means |
|---|---|
| **World space** | The imaginary sheet of paper that goes on forever. Every item's real position lives here. It doesn't move when you pan. |
| **Screen space** | Where things land on the actual iPad glass, measured in points from the top-left corner. |
| **The camera** | Where you're currently looking, and how far zoomed in. Panning and zooming move the camera, not the items. |
| **Viewport** | The rectangle of world space you can see right now. Basically "what the camera is pointed at." |
| **Culling** | Skipping work for things you can't see. We don't build views for off-screen images at all. |
| **Hit-testing** | Working out which item is under your finger. |
| **Element / item** | One thing on the canvas: an image or a text note. |
| **Commit** | Saving a change for real, after the gesture ends. During the gesture we only *show* the change. |
| **Store** | `LocalBoardStore`, the backend's memory of what's on the board. The canvas keeps its own faster copy and syncs to the store. |

**The one formula everything rests on:**

```
screenPoint = worldPoint * camera.scale + camera.offset
```

Read backwards, that's how a tap becomes a world position. Both directions matter, and both live in `screenToWorld(_:)`.

---

## Current status

Core canvas and UI are built and working. Active development continues.

---

# The infinite canvas

**Status: Implemented (MVP)**
**File:** `BoardCanvasView.swift`

A self-contained SwiftUI view that lets you pan, zoom, and place images on an endless flat surface.

## How position works

Nothing on the canvas ever "moves" when you pan. Items sit at fixed world coordinates forever. What changes is where the camera is pointed. This is the single most important idea in the file — if you're ever confused about a coordinate bug, start by asking whether you're in world space or screen space.

- World space uses `CGFloat` with origin at (0, 0)
- World units are arbitrary but consistent — roughly 1 unit per screen point when zoom is 1.0

## The camera

Camera state lives in `@Observable final class CanvasCamera` (`CanvasCamera.swift`), owned by `BoardCanvasView` as `@State private var camera = CanvasCamera()`.

- `camera.offset: CGSize` — how far the world has been shifted, in screen points
- `camera.scale: CGFloat` — zoom level
- Limits: `minScale = 0.05`, `maxScale = 8.0`

Four things write to the camera: pinch, two-finger pan, the home button (`jumpToContentCenter`), and the landing snap when a board loads. All of them go through `camera.offset` / `camera.scale` — there's no second path.

**Where the camera points on open:**

- Normally, `.onAppear` sets `camera.offset` to `(screenWidth/2, screenHeight/2)`, putting world origin in the middle of the screen
- If elements happened to load before `onAppear` ran, it calls `jumpToContentCenter(animated: false)` instead, so you land on your content
- When a board loads through `elementsToLoad`, that same snap is delayed by one run-loop tick (see "Landing snap" below for why)

**Converting a tap to a world position:**

```swift
func screenToWorld(_ p: CGPoint) -> CGPoint {
    CGPoint(x: (p.x - offset.width) / scale, 
            y: (p.y - offset.height) / scale)
}
```

## How things get drawn

- The grid background is a SwiftUI `Canvas`
- Items are real SwiftUI views in a `ZStack`, layered with `.zIndex()`
- Each item is placed with `.position()` and sized with `.frame()`
- Off-screen images are never built. `visibleImages` asks the store which images touch the viewport, and only those become views

**The grid:**

- Lines every 128 world units (`gridSpacingWorld = 128.0`)
- Drawn in world coordinates, then converted to screen positions
- Toggled by `showGrid`
- There used to be a red crosshair at the origin. It caused render timing problems and was removed.

**Empty canvas:**

When `placedImages` is empty, a centered `photo.on.rectangle.angled` symbol (80pt) appears with "Drag and drop an image here". It uses `DesignSystem.Colors.secondary` with `compositingGroup()` and `.blendMode(.difference)`, which is a trick to make it readable on *any* canvas color — difference blending inverts against whatever is behind it. It disappears as soon as the first image lands.

---

# Gestures

Three gestures run at the same time on the canvas ZStack.

## Drag — routed through the active tool

`DragGesture(minimumDistance: 8)`. The active tool decides what a drag means.

1. On the first `.onChanged`, the tool hit-tests and picks a `DragMode`: `.pan`, `.moveItem`, or `.none`
2. That decision is cached in `currentDragMode` and reused for the whole gesture — we don't re-decide mid-drag
3. `.pan` adds the movement to `offset`. `.moveItem` updates `selection.dragOffset` in world space, which makes the item follow your finger without touching the store
4. On `.onEnded`, a `.moveItem` drag calls `commitMove()` to save positions, then all drag state resets

## Taps — each view handles its own

Taps are attached to individual views, not to one big parent gesture:

- Each `FileImageView` has `.onTapGesture { ... tappedItem(id:) }`, attached **before** `.position(...)` so the tappable area follows the item
- The background grid `Canvas` has `.onTapGesture { ... tappedEmpty() }`

**Why it's built this way:** we used to put one `.simultaneousGesture(SpatialTapGesture())` on the outer ZStack. That caused taps to go through two things at once — tapping the trash button in the selection bar *also* tapped the image behind it. SwiftUI has no "stop here, don't pass this tap along" for simultaneous gestures. Letting each child own its tap lets SwiftUI's normal hit-testing pick a single winner: the topmost view. That's the idiomatic fix.

The 8pt minimum on the drag gesture keeps the two systems apart — a tap moves less than 8pt, so it never starts a drag.

## Pinch zoom (bridged from UIKit)

**File:** `PinchGestureView.swift`

SwiftUI's `MagnificationGesture` only zooms around the center of the view. We want zoom to pivot on your fingers, like Apple Freeform. That needs the pinch centroid, which SwiftUI doesn't expose — so we wrap `UIPinchGestureRecognizer` in a `UIViewRepresentable`.

- Reports **per-tick scale changes**, not a running total. `.began` and `.ended` report 1.0; only `.changed` reports real values
- Reports the centroid in the installer's own coordinate space, not the window's, so it matches the space the canvas positions things in. Matters if the canvas ever gets inset by a toolbar or safe area
- Attached with `.background(PinchGestureView(onPinch:))`, handled by `handlePinch(phase:scaleDelta:anchor:)`
- The actual zoom math is a **pure function** with no view involved: `CanvasCamera.zoomAnchoredOffset(anchor:oldOffset:oldScale:newScale:)` in `CanvasCamera.swift`. It keeps `worldPoint = (anchor - offset) / scale` the same across the zoom change, which is what "the point under your fingers stays under your fingers" means mathematically. Being pure makes it testable without running a view.

## Two-finger pan (bridged from UIKit)

**File:** `TwoFingerPanView.swift`

Two fingers always pan, no matter which tool is active. Without this, the Group tool's marquee would trap you — you'd have no way to move around while it's selected.

- Wraps `UIPanGestureRecognizer` with min and max touches set to 2
- Reports **per-tick movement**, and `handleTwoFingerPan(phase:delta:)` just adds it to `offset`
- Configured with `cancelsTouchesInView = false`, `delaysTouchesBegan/Ended = false`, and a delegate returning `true` from `shouldRecognizeSimultaneouslyWith`, so SwiftUI's own gestures still see the touches

## Why both bridges report changes instead of totals

Pinch and two-finger pan fire at the same time and both write `offset`.

The old design had each one capture a starting value, then report "start value plus everything since." That broke: whichever handler ran second in a frame had captured its starting value *before* the first handler's writes, so it overwrote them with stale math.

Reporting per-tick changes fixes it completely. Each handler reads the current `offset`/`scale`, adds its change, writes back. There's no stored starting value to go stale. As a bonus, one gesture ending before the other needs no special handling.

## Shared gesture installer

**File:** `GestureInstallerView.swift`

Both UIKit bridges need to attach their recognizer to the SwiftUI hosting view above them. That's fiddly, so it's written once.

`GestureInstallerView` + the `GestureInstallerCoordinator` protocol handle:
- Walking up the responder chain (`responder.next`) to find the first `UIViewController.view`
- Installing the recognizer there when the view enters the window or changes superview
- Re-installing if the view gets re-parented
- Forcing `isUserInteractionEnabled = false` on itself, so the installer never accidentally swallows touches

Cleanup matters here. Each bridge's `dismantleUIView(_:coordinator:)` calls `Coordinator.detach()`, which removes the recognizer, clears its target and delegate, and swaps the callback for a no-op. Without this, remounting the canvas (like `RootView` toggling `showCanvas`) would leave duplicate recognizers behind and leak memory through retain cycles.

## Camera extraction — done, with one thing left

`offset` and `scale` now live in `CanvasCamera`. `zoomAnchoredOffset` is a static method on it.

Three functions stayed on `BoardCanvasView` because they need view-local state the camera doesn't have:
- `viewportCGRect()` and `allElementRects()` need `canvasSize`, `placedImages`, `placedTexts`
- `jumpToContentCenter` needs `canvasSize`, `reduceMotion`, and `scheduleRefreshVisibleElements()` — it writes to `camera.offset` but lives on the view

**Possible next step:** if the camera became an environment-injected observable, the toolbar could call camera methods directly, and the UUID-trigger pattern for `homeTrigger` (maybe `undoTrigger`/`redoTrigger` too) could go away.

**One subtlety to watch:** `PinchGestureView` reports its centroid in installer-local coordinates; `TwoFingerPanView` uses `recognizer.view`. These are the same space today only because the installer sits as a `.background` of the canvas ZStack. Inset the canvas and they'd drift apart. For any new recognizer that reports points, use installer-local coordinates.

---

# Placing images

Images go in through `insertImages(atScreenPoint:urls:)`:

1. **Get a safe copy.** Files are copied into `Application Support/ImportedImages/` by `makeSandboxCopyIfNeeded(from:)`, because the app can't rely on keeping access to the original location. This happens once, inside `insertImages`, so callers just pass raw URLs
2. **Pick a size.** Pixel dimensions come from `CGImageSource`, then get scaled into world units with the aspect ratio preserved. Capped at 512 world units, floored at 64
3. **Avoid stacking.** `firstNonOverlappingRect(near:size:)` nudges the image diagonally if it would land on something (up to 64 tries, 24pt per nudge)
4. **Put it on top.** `nextZIndex` auto-increments so new items land above old ones

**Three ways images arrive:** dropping files on the canvas, the toolbar's "Add Item" file picker, and the `@Binding var externalInsertURLs: [URL]?` binding.

**The model:**

```swift
struct PlacedImage: Identifiable {
    let id: UUID
    let url: URL          // Local file URL
    var worldRect: CGRect // Position/size in world coordinates
    var zIndex: Int       // Render order
}
```

**Drawing an image:** `FileImageView` loads from the file URL asynchronously, uses `.resizable()` + `.scaledToFill()` + `.clipped()`, and shows a `ProgressView` while loading. Its frame is the world size times `scale`, positioned from the world center.

---

# Handling drops

**Accepts:** `UTType.image` (PNG, JPEG, and friends) and `UTType.gif`.

`CanvasDropDelegate` (a file-scope struct) conforms to `DropDelegate`. It checks the dropped providers carry a type we accept, then loads file URLs asynchronously. Some sources hand over a file URL directly; others only give raw data, so there's a fallback that writes the data to a temp file.

**Shared loading code:** `Features/BoardCanvas/Import/ItemProviderHelpers.swift` holds `loadURLsFromProviders(_:preferredTypes:)` and the `NSItemProvider` extensions (`loadFileURLCompat(for:)`, `loadDataAsTempFileCompat(for:)`). Both the canvas drop handler and `FilePickerView`'s landing drop zone call it. A duplicate copy used to live in `InsertFileControl.swift`; that file was deleted along with the unused control.

---

# How the canvas connects to the rest of the app

## RootView — the router

**File:** `RootView.swift`

A small view that decides whether you see the landing screen or the canvas.

- Shows `FilePickerView` at launch, switches to `ContentView` once files are chosen
- `@State private var showCanvas: Bool` is the switch
- Watches `openHandler.importedElements` with `onChange(of:)`, so opening a `.refboard` from outside the app goes straight to the canvas
- `ContentView` gets the chosen URLs as a plain `let initialURLs: [URL]`, not a binding

## AppOpenHandler

An `@Observable @MainActor final class` (previously `ObservableObject` + `@Published`). Injected at the app root via `.environment(openHandler)` and read with `@Environment(AppOpenHandler.self)` in `RootView` and `ContentView`.

## ContentView

- Wraps `BoardCanvasView` in a `NavigationStack` and attaches `CanvasNavigationToolbar` through `.toolbar { ... }`. The nav bar is translucent Liquid Glass, and the canvas runs edge-to-edge underneath it
- Holds `@State private var urlsToInsert: [URL]?` for file-picker handoff
- On `.onAppear`, passes `initialURLs` into `urlsToInsert` for the canvas to pick up
- Presents `.fileImporter` when the toolbar's add button fires
- Presents the `CanvasSettingsView` sheet when the gear fires

## File picker handoff

1. The toolbar's `onAddItem` sets `importerPresented = true`
2. `.fileImporter` opens, allowing multiple `.image` and `.gif` files
3. Chosen URLs go to `BoardCanvasView` through the `externalInsertURLs` binding
4. `BoardCanvasView` sees the change via `.onChange` and calls `insertImagesAtCenter()`
5. The binding is cleared so the same URLs don't fire twice

---

# Keeping it fast

**What we do now:**

- `visibleImages` is the subset of `placedImages` that actually touches the viewport. Only those become `FileImageView` instances
- `imageRenderPlan()` splits `visibleImages` into `detailItems` (the real image) and `overviewItems` (a cheap placeholder rectangle), based on on-screen size and level-of-detail thresholds
- `scheduleRefreshVisibleElements()` re-asks the store which images are visible, but waits 40ms first (80ms while you're actively panning or zooming) so a burst of movement causes one query, not fifty
- Text elements aren't culled. They're cheap SwiftUI views with no image decoding behind them, so filtering them would cost more than it saves

**Later, if needed:**
- Cull text by viewport (low priority — see above)
- Metal rendering for very large boards (1000+ images)

---

# Canvas chrome (the native toolbar)

**Status: Implemented (native iPadOS 26 Liquid Glass)**
**File:** `Features/BoardCanvas/Tools/CanvasNavigationToolbar.swift`

Everything around the canvas — back, board name, tools, undo/redo, add, settings — is one native SwiftUI `.toolbar` on the `NavigationStack` wrapping `BoardCanvasView`.

We used to hand-build this as floating overlays (`CanvasOverlayLayout` + `CanvasToolbar` + `CanvasStatusBar` + `CanvasSettingsButton`). All of that is deleted. The native toolbar gives us press feedback, the glass material, grouped capsules via `ToolbarItemGroup`, separation via `ToolbarSpacer`, and automatic overflow into a `•••` menu on narrow screens — every one of which we were previously writing ourselves, worse.

**Layout:**

```
[Leading group]                                                [Trailing items]
< (back)  |  BoardName pill        [Pointer | Group | Text | Add] | [Undo | Redo] | [Settings]
```

- The **leading group** puts the back chevron and board name in one glass capsule. The name is a non-interactive glass button inside the group, so only the group's outer pill is glass — glass inside glass looks wrong
- **Trailing groups** are separated by `ToolbarSpacer(.fixed)`. That spacer is what makes each group render as its own capsule
- **Every button uses `Label("Title", systemImage:)`** so the overflow menu has real text to show when the bar runs out of room

**Tools group:**

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

The active tool is shown two ways: a blue tint *and* the `.isSelected` accessibility trait. Color alone would tell VoiceOver users nothing.

No `matchedGeometryEffect` — the system animates this itself. And separate buttons work in the overflow menu, where a segmented `Picker` wouldn't.

Add lives with the tools because it's the other "put something on the canvas" action. It's not a mode, so it gets no tint and no `.isSelected`. It used to sit next to Settings, where it read like a settings control.

**The board name pill, and the disabled-button trick:**

A bare `Text(boardName).glassEffect()` in a leading toolbar slot gets squeezed to about chevron width — the system doesn't honor `frame(maxWidth:)` on raw text there. Wrapping the text in a button that can't be tapped makes the system treat it as a real control, and real controls get their requested size:

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

**How ContentView wires it up:**

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
                onAddItem: openImageImporter,
                onSettings: { showingSettings = true }
            )
        }
}
```

The settings sheet is still presented from `ContentView` via `.sheet(isPresented: $showingSettings)`.

---

# Finding your way around

## Minimap

**Status: Implemented**
**File:** `Features/BoardCanvas/CanvasMinimapView.swift`

A 160×100pt see-through panel in the bottom-right corner showing where your content sits and where you're currently looking.

It's a **pure view** — it takes two inputs and holds no state of its own:

```swift
struct CanvasMinimapView: View {
    let elementRects: [CGRect]
    let viewportRect: CGRect
}
```

`BoardCanvasView` feeds it:

```swift
.overlay(alignment: .bottomTrailing) {
    let rects = allElementRects()   // placedImages + placedTexts worldRects
    if !rects.isEmpty {
        CanvasMinimapView(elementRects: rects, viewportRect: viewportCGRect())
            .padding(16)
    }
}
```

It hides itself on an empty canvas, because the overlay is conditional on `!rects.isEmpty`.

**How it draws, step by step:**

1. `worldExtents()` takes every element rect plus the viewport, finds the box containing all of them, and pads it by 12%
2. `aspectCorrected(_:toMatch:)` grows that box outward from its center until its shape matches the minimap panel's shape
3. `project(_:world:into:)` converts any world rectangle into a position inside the panel
4. Elements draw as white rounded rectangles, never smaller than 2×2pt so tiny items stay visible
5. The **viewport indicator** draws as a `.white.opacity(0.08)` fill with a `DesignSystem.Colors.tertiary` outline

Plus `.allowsHitTesting(false)` (it's decoration, not a control) and `.accessibilityHidden(true)` (nothing meaningful to announce).

**Why step 2 exists:**

`project` works out its horizontal and vertical scale separately. Feed it a box whose shape doesn't match the panel and it squashes everything to fit — like stretching a photo to fill a differently-shaped frame.

That box's shape isn't fixed. As you pan away from your content, `worldExtents()` grows along the direction you panned, so its shape keeps changing. The result was a viewport indicator that changed shape depending on how far you'd wandered, which is misleading: the indicator represents your iPad screen, and your iPad screen doesn't change shape.

`aspectCorrected` fixes it by making the box match the panel before anything is drawn. Then horizontal and vertical scale come out equal, and every rectangle keeps its true proportions — the viewport indicator and the image thumbnails alike.

It only ever grows the box, never trims it, so nothing can get pushed outside the panel. `viewportCGRect()` is `canvasSize / scale`, meaning it already carries the device's true shape; the minimap's job is just to not throw that away.

The panel itself stays 160×100 in any orientation. The indicator's shape inside it is what tracks the device.

## Home button

**Status: Implemented**
**Files:** `Features/BoardCanvas/Tools/CanvasNavigationToolbar.swift`, `BoardCanvasView.swift`

A house icon in the undo/redo group that flies the camera back to the middle of your content.

**How the button reaches the canvas:** the same UUID trick as undo/redo. `ContentView` owns `@State private var homeTrigger: UUID?`. Tapping sets it to a fresh `UUID()`. `BoardCanvasView` watches it with `.onChange(of: homeTrigger)`, calls `jumpToContentCenter()`, and clears it. The point of a UUID rather than a `Bool` is that every tap is a distinct value, so two taps in a row both register.

**`jumpToContentCenter(animated: Bool = true)`:**

1. Bails unless `canvasSize != .zero` and `camera.scale > 0`
2. `guard let bounds = union(of: allElementRects()) else { return }` — nothing to center on if the board is empty
3. Works out the offset that puts the content's middle at the screen's middle:
   `target = CGSize(width: canvasSize.width/2 - bounds.midX * camera.scale, height: canvasSize.height/2 - bounds.midY * camera.scale)`
4. If animating and Reduce Motion is off: `.easeInOut(0.4)`, with `scheduleRefreshVisibleElements()` in the `completion:` block so images don't pop in mid-flight
5. Otherwise: set the offset instantly and refresh immediately

`@Environment(\.accessibilityReduceMotion) private var reduceMotion` is read on `BoardCanvasView` and respected on the animated path.

## Landing snap

**Status: Implemented**

Open a board with content and you land looking at that content, not at empty space near the world origin.

**Why it needs `DispatchQueue.main.async`:**

The snap fires from `onChange(of: elementsToLoad)`, right after `applyElements`. But `jumpToContentCenter` refuses to run unless `canvasSize != .zero`, and `canvasSize` is only set in `BoardCanvasView.onAppear`.

SwiftUI doesn't guarantee which `onAppear` runs first. Sometimes `ContentView.onAppear` (which sets `elementsToLoad`) fires *before* `BoardCanvasView.onAppear`, so `canvasSize` is still zero and the snap silently gives up.

Wrapping the call in `DispatchQueue.main.async` pushes it past the end of the current run-loop pass, by which point every `onAppear` has definitely run.

**This one is not interchangeable with `Task { }`.** A bare `Task` uses Swift concurrency's cooperative scheduler, which doesn't drain the run loop, so it doesn't give the ordering guarantee we're relying on. Everywhere else in this file, prefer `Task { @MainActor in ... }`; here, don't.

There's also a fallback in `onAppear` itself for the opposite race: if elements were already applied before `canvasSize` existed, the snap fires there instead.

---

# Tools

**Status: Implemented**
**File:** `CanvasToolBehavior.swift`

Each toolbar tool decides for itself what a tap or drag means. That decision lives behind a protocol, so adding a tool doesn't mean editing a giant switch statement in the view.

```
CanvasTool (enum)              -- toolbar identity, UI selection
    |
    v
CanvasToolBehavior (protocol)  -- gesture interpretation per tool
    ├── PointerToolBehavior    -- tap=select, drag-on-item=move, drag-on-empty=pan
    ├── GroupToolBehavior      -- tap=toggle selection, drag-on-item=group move, drag-on-empty=marquee select
    └── TextToolBehavior       -- tap-empty=place text (canvas owns this), tap-item=select, drag-on-item=move, drag-on-empty=pan
```

**The protocol:**

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

Taps are split into two methods so the view can call the right one based on which `.onTapGesture` fired. `tappedItem` gets the `UUID` directly — SwiftUI already figured out what was tapped, so there's no reason to look it up again by position. Both are `@MainActor` so they can change `CanvasSelectionState` directly instead of hopping through `MainActor.run`.

**`dragBegan` is deliberately synchronous.** It hit-tests against the in-memory `placedImages` (converted to `HitTestItem`) rather than asking the store, which would be `async`. When it was async, a quick flick could finish before the mode decision came back, and the drag did nothing. The `moveToTop` z-order write still happens, but it's fired off afterward as a side effect that nobody waits on.

**`DragMode`:** `.pan`, `.moveItem`, `.resizeItem`, `.marqueeSelect`, `.none`

**How a drag flows:**

1. First `.onChanged`: check for a resize handle hit first, then ask the tool → cache the `DragMode`
2. That decision is synchronous, so there's no window where the drag is live but undecided
3. Later `.onChanged` events: `applyDrag()` sends them to pan, move, resize, or marquee based on the cached mode
4. `.onEnded`: commit whichever action was running

**Pointer:** drag an item to select it, raise it, and move it. Drag empty space to pan. Tap an item to select. Tap empty to deselect.

**Group:** drag a selected item to move the whole group. Drag an unselected item to add it (`extending: true`) and move. Drag empty space to draw a marquee. Tap an item to toggle its membership. Tap empty to clear.

**Text:** drag an item to select and move it (same as pointer). Drag empty space to pan. Tap an item to select it. Tap empty space is special — see below.

**Why text's empty-tap is handled by the canvas, not the tool:** placing text needs the world coordinate of the tap, and that lives in the view's coordinate space, which the protocol doesn't expose. So `TextToolBehavior.tappedEmpty` only clears the selection, and `BoardCanvasView` does the actual `insertText(at:)`. After placing, `insertText` switches `activeTool = .pointer` automatically (the Figma convention), so you don't leave a trail of empty text boxes with every tap.

**Factory:** `toolBehavior(for: CanvasTool) -> CanvasToolBehavior`.

**To add a tool:** add a case to `CanvasTool`, write a struct conforming to `CanvasToolBehavior`, add it to the factory.

---

# Selection and moving

**Status: Implemented**
**Files:** `CanvasSelectionState.swift`, `HandlePosition.swift`, `SelectionOverlay.swift`, `MarqueeOverlayView.swift`, `BoardCanvasView.swift`

## Selection state

`CanvasSelectionState` is an `@Observable` class owned as `@State` in `BoardCanvasView`:

- `selectedIDs: Set<UUID>` — what's selected
- `dragOffset: CGSize` — how far the current drag has moved, in world space
- `isDragging: Bool` — is a move in progress
- `select(_:extending:)` — select something; `extending: true` toggles it for multi-select
- `clearSelection()` — deselect everything

**Marquee state** (same class):
- `marqueeStartWorld: CGPoint?` — where the marquee drag began
- `marqueeCurrentWorld: CGPoint?` — where it is now
- `marqueeWorldRect: CGRect?` — those two as a normalized rectangle
- `isMarqueeing: Bool` — computed from `marqueeStartWorld != nil`
- `clearMarquee()`

## What selection looks like

**Files:** `SelectionOverlay.swift` (views), `HandlePosition.swift` (model)

- `ResizeHandleView` — one shared 10×10pt rounded square, white fill, blue border. Used by both overlay types
- `SelectionOverlay` — solid 2pt blue border + 8 handles, for a single selected item
- `GroupSelectionOverlay` — solid 2pt blue border + 8 handles around the group's bounding box. Same weight as the single version on purpose, so multi-select doesn't look like a different feature. (It used to be dashed.)
- Individually selected items inside a group show a faint border instead of full handles
- `MarqueeOverlayView` — solid 1.5pt blue rectangle with an 8%-opacity blue fill. (Also used to be dashed.)

**Handles hide while you're dragging one:**

Both overlays take an `activeHandle: HandlePosition?`. While you drag one handle, the other seven disappear so they don't compete with what you're doing; the border stays. `CanvasSelectionState.resizeHandle` is the one source of "which handle is live" across single-image, single-text, and group resize — all three call sites in `BoardCanvasView` pass `selection.resizeHandle`. `nil` means "not resizing" and everything renders.

`HandlePosition` (in its own file, to keep `CanvasSelectionState` free of view concerns) defines `.topLeft`, `.topCenter`, `.topRight`, `.leftCenter`, `.rightCenter`, `.bottomLeft`, `.bottomCenter`, `.bottomRight`, plus helpers: `anchorPosition` (the opposite handle), `isCorner`, `isLeftSide`, `isTopSide`.

## Moving

1. You drag a selected item → `applyDrag()` sets `selection.dragOffset` in world space
2. While dragging, selected items render at `position + (dragOffset * scale)`. The store is never touched — that's what keeps dragging smooth
3. On release, `commitMove()` records a `.move` command for undo, then applies it through `applyMoveDelta()`

## Resizing

**Status: Implemented (single + group)**

`hitTestHandle(screenPoint:)` is a pure question with no side effects. It returns a `HandleHitResult` (`.singleItem` or `.group`), and the caller sets up whichever resize state that implies.

**One item selected:**
1. `hitTestHandle` measures screen distance to the item's 8 handles (30pt hit radius — generous, because fingers are)
2. A hit means `.resizeItem` mode and single-resize state
3. `applyResize(translation:)` calls the shared `computeResizedRect()`
4. The live rectangle lives in `selection.resizeCurrentRect`
5. `commitResize()` ignores no-op resizes and records a `.resize` command

**Two or more selected:**
1. `hitTestHandle` checks the handles on the group's bounding box
2. A hit means `.resizeItem` mode, and every selected item's rectangle is snapshotted into `groupResizeStartRects`
3. `applyGroupResize(translation:)` runs `computeResizedRect()` on the bounding box
4. Each item's new rectangle comes from `scaledRect(original:bboxStart:bboxCurrent:)`, which scales position and size relative to the box's origin:
   - `scaleX = bboxCurrent.width / bboxStart.width`
   - `scaleY = bboxCurrent.height / bboxStart.height`
5. `commitGroupResize()` records one `.groupResize(fromRects:toRects:)` command and applies everything in a single batch via `applyResizeRects(_:)`

**Shared math:** `computeResizedRect(handle:startRect:translation:) -> CGRect?`
- Corner handles keep the aspect ratio and pin the opposite corner
- Edge handles stretch one axis and pin the opposite edge
- Nothing shrinks below `minImageDimensionWorld = 64`
- Both single and group paths use it, so they can't drift apart

**Single resize state** (in `CanvasSelectionState`): `resizeHandle`, `resizeStartRect`, `resizeCurrentRect`, `resizeElementID`, `isResizing` (computed from `resizeHandle != nil`), `clearResize()`.

**Group resize state:** `groupResizeStartRects: [UUID: CGRect]?`, `groupResizeBBoxStart`, `groupResizeBBoxCurrent`, `isGroupResizing` (computed from `groupResizeStartRects != nil`), `clearGroupResize()`.

## Keeping store writes orderly

All store changes go through `enqueueStoreMutation()`. Each new one cancels whatever is in flight and waits for it to finish before starting. This stops an older, slower write from landing after a newer one and undoing it — which is easy to trigger by mashing undo/redo.

Each change uses batched `elements(for:)` + `upsert(elements:)`: two round-trips to the actor, not two per element.

---

# Undo and redo

**Status: Implemented**
**Files:** `CanvasCommandHistory.swift`, `BoardCanvasView.swift`, `ContentView.swift`

Every reversible action is recorded as a small description of what changed and what it changed from — enough to play it backwards or forwards, without storing whole board snapshots.

```
CanvasCommand (enum)         — describes a reversible operation
CanvasCommandHistory         — @Observable class with undo/redo stacks
BoardCanvasView              — executes commands via helper methods
ContentView                  — triggers undo/redo from toolbar
```

| Command | Data stored | Undo | Redo |
|---------|-------------|------|------|
| `.move` | `elementIDs: Set<UUID>`, `delta: CGSize` | Move by -delta | Move by +delta |
| `.resize` | `elementID: UUID`, `fromRect`, `toRect` | Restore fromRect | Restore toRect |
| `.groupResize` | `fromRects: [UUID: CGRect]`, `toRects: [UUID: CGRect]` | Restore all fromRects | Apply all toRects |
| `.insert` | `snapshots: [PlacedElementSnapshot]` | Remove elements | Re-add elements |
| `.delete` | `snapshots: [PlacedElementSnapshot]` | Re-add elements | Remove elements |

`PlacedElementSnapshot` holds everything needed to fully recreate an element: `id`, `url`, `worldRect`, `zIndex`, and the complete `CMCanvasElement`.

**Managing history:**

- `CanvasCommandHistory` is `@Observable @MainActor`, owned as `@State` in `ContentView` and handed to `BoardCanvasView` as a required init parameter (no default — an accidental second history would silently split the undo stack)
- `push(_:)` adds to undo and clears redo
- `popUndo()` / `popRedo()` move commands between the stacks
- `canUndo` / `canRedo` drive button state
- `clear()` wipes both. Called after importing a board, so undo can't reach back into the previous board and try to resurrect assets that no longer exist

**Wiring:** toolbar buttons fire the `undoTrigger` / `redoTrigger` UUID bindings. `BoardCanvasView` watches them and calls `performUndo()` / `performRedo()`, which pop a command and dispatch to shared helpers: `applyMoveDelta()`, `applyResizeRect()`, `applyResizeRects(_:)`, `addElements()`, `removeElements()`.

**To make a new action undoable:** add a case to `CanvasCommand`, push it in that action's commit function, handle it in `performUndo()` / `performRedo()`.

---

# Selection action bar

**Status: Implemented**
**Files:** `CanvasSelectionActionBar.swift`, `SelectionActionBarLayer.swift`

A small floating bar that appears next to whatever you've selected. Right now it holds one button: delete.

We tried `.contextMenu(menuItems:preview:)` first. Its default preview couldn't lift a whole multi-selection, and a custom preview couldn't blur the items that weren't part of it. So: a floating bar.

**The button:**

```swift
Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
    .labelStyle(.iconOnly)     // visible: just the trash icon
    .buttonStyle(.glass)       // native Liquid Glass
    .tint(.red)
    .controlSize(.large)
```

The title still exists for VoiceOver; `.labelStyle(.iconOnly)` just hides it visually. The native glass style brings its own material, press animation, and shape, replacing hand-rolled `RoundedRectangle` + shadow code.

**Positioning — and why the bar is always mounted**

`SelectionActionBarLayer` keeps the bar in `BoardCanvasView`'s ZStack permanently. It's never conditionally inserted, even though it's usually invisible.

The reason is a Liquid Glass quirk. A glass view that's freshly inserted at the top `zIndex` and positioned with `.position()` samples what's behind it *before* the canvas underneath has settled in that compositing pass. It caches the wrong light/dark appearance and keeps it until something unrelated forces a re-sample. That's the "tap it again and it looks right" bug. A view that's always mounted, with stable identity, never takes that bad first sample.

So the layer's job is to show, hide, and move a view that already exists:

- **Show/hide** — opacity 1 or 0, driven by `isVisible = boundingBox != nil && !isInteracting`, where `isInteracting = isDragging || isResizing || isGroupResizing || isMarqueeing`
- **Position** — `displayCenter = isVisible ? liveCenter : lastCenter`. Parking at `lastCenter` during interaction matters: publishing a moving position every frame would start a fresh `.snappy` animation every frame on an invisible view. Invisible, but still spending real frame budget — it showed up as jitter while resizing text
- **Position tracking** — `@State private var lastCenter` updates via `.onChange(of: liveCenter)`, guarded by `isVisible` so it doesn't drift during interactions. Live center is `boundingBox.midX/maxY * scale + offset`, plus a 32pt gap
- **Animation gating** — `transitionAnimation` returns `nil` while interacting, so the bar appears and disappears instantly at drag start and end. Animating opacity and position for 0.2s on top of a starting gesture was the cause of "the first fraction of every drag feels rough"

**Host wiring:**

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

**Deleting:**

- `deleteSelection()` fetches the real `CMCanvasElement`s from `LocalBoardStore` via `elements(for:)` before snapshotting. Building them from the view's `placedImages` cache would risk snapshotting stale data, and undo would then restore something subtly wrong
- Those snapshots become a `.delete(snapshots:)` command, then `removeElements()` applies the change
- `fallbackImageElement(for:)` and `fallbackTextElement(for:)` cover the rare case where the view and store disagree

---

# Text elements

**Status: Implemented**

**Files:**
- `BoardCanvasView.swift` (`PlacedText`, `TextElementView`, `insertText`/`commitTextEdit`, resize state, render path)
- `Features/BoardCanvas/CanvasTextField.swift` (the UIKit editing field)
- `Features/BoardCanvas/CanvasToolBehavior.swift` (`TextToolBehavior`)
- `Features/BoardCanvas/CanvasCommandHistory.swift` (`.editTextContent`, `.resizeText`, extended `.groupResize`)
- `Persistence/CanvasModels.swift` (`CMCanvasElementPayload.text` + `wrapWidth`)

Text lives in its own `placedTexts: [PlacedText]` array beside `placedImages`, rather than both being unified behind one `PlacedItem` type. Two arrays with a few branched code paths is genuinely simpler than a protocol abstraction until a third element type shows up. When one does, that's the moment to unify.

**The model:**

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

`fontSize` is the one true source of text size. Corner-drag resize, group resize, and any future font-size picker all change this same field. `worldRect.size` is *measured from what actually rendered* — never assigned directly, except for `worldRect.origin`.

## Why text scales differently than images

Images render at `worldRect.size * scale` — frame and position both multiplied by zoom up front.

Doing that to text broke it. A string that fit on one line at zoom 1.0 wrapped onto two lines at zoom 0.2. The cause is CoreText hinting: at small font sizes, glyphs come out slightly wider than a straight multiplication predicts. So layout decisions weren't the same at every zoom — which is unacceptable, because wrapping is a layout decision the user can see.

The fix is to lay text out **once, at base size**, and scale the finished result:

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

No `* scale` on font, frame, or wrap width. `.scaleEffect` only magnifies the finished picture, so wrapping is identical at every zoom.

`onGeometryChange` is the feedback loop that keeps `worldRect.size` matching the text that actually rendered. Hit-testing, marquee selection, and group bounding boxes all depend on it.

**Why the rounding sits in `of:` and not in the action closure:** during a resize drag, in-between `fontSize`/`wrapWidth` values hit that same CoreText sub-pixel behavior, and the measured size wobbles by fractions of a point each frame. Left alone, each wobble fires `onGeometryChange` → writes the binding → re-renders → re-measures → visible jitter. Rounding inside `of:` means the observer only fires when the *rounded* number changes, so the noise never reaches the action at all. Real drag-driven changes are multiple points, so they still get through.

## Two width modes

`PlacedText.wrapWidth` picks between two different render paths:

- **Auto-width (`wrapWidth == nil`)** — the text box grows sideways as you type; only pressing Enter breaks a line. The editing field uses a `ZStack(alignment: .topLeading)` with an invisible `Text(content).fixedSize(horizontal: true, vertical: true).opacity(0)` underneath it. That hidden copy forces the ZStack's width to match the longest line, and the TextField simply fills it. Without that trick, a vertical-axis TextField wraps to its minimum width while you type and then un-wraps when the static `Text` takes over on commit — a visible jump
- **Wrap mode (`wrapWidth != nil`)** — an explicit `.frame(width: wrapWidth, alignment: .leading)` plus `.fixedSize(horizontal: false, vertical: true)`. Text reflows inside that width; height follows the content

The view splits into `body` → `sizedContent` → `textOrField` specifically so the auto-width path never carries a `.frame(width:)` modifier. An earlier version always had `.frame(width: placed.wrapWidth.map { $0 * scale })` in the chain, and even with a nil width it interacted with the trailing `.fixedSize` to cause wrapping at small fonts.

## `CanvasTextField` — why editing uses UITextView

**File:** `CanvasTextField.swift`

SwiftUI's `TextField` gives no control over caret thickness. UIKit's caret is a fixed ~2pt, and the surrounding `.scaleEffect` shrinks it to less than a pixel when you're zoomed out — the caret effectively vanishes.

So `CanvasTextField` is a `UIViewRepresentable` around `CanvasUITextView`, a `UITextView` subclass that overrides the caret:

```swift
override func caretRect(for position: UITextPosition) -> CGRect {
    let original = super.caretRect(for: position)
    let targetVisible: CGFloat = 2.5
    let thickness = targetVisible / max(canvasScale, 0.0001)
    return CGRect(x: original.origin.x, y: original.origin.y,
                  width: thickness, height: original.height)
}
```

Drawing it at `2.5 / canvasScale` means that after `.scaleEffect(scale)` shrinks it back down, it lands at exactly 2.5pt on screen at every zoom and font size. Height still follows the text; only thickness is pinned.

Other notes:
- `textContainerInset.right = caretThickness` reserves room so the caret doesn't get clipped at the end of a line. SwiftUI's `TextField` has this slack built in; `UITextView` doesn't unless you ask
- Focus is driven by the `isEditing` flag in `updateUIView` calling `becomeFirstResponder()` / `resignFirstResponder()`, guarded by `isFirstResponder` to skip redundant calls. No `@FocusState` needed — the wrapper owns its own first-responder lifecycle
- `Coordinator` implements `textViewDidChange` to push text into the binding, and `textViewDidEndEditing` to fire `onCommit` (which calls the parent's `commitTextEdit(id:)`)
- `tintColor = DesignSystem.Colors.primary` makes the caret and selection highlight dark. They'd disappear against the blue editing border otherwise
- `textContainerInset = .zero` and `lineFragmentPadding = 0` so the editing layout matches the static `Text` shown after commit — otherwise text visibly shifts when you finish typing

## The editing lifecycle

Three pieces of state on `BoardCanvasView`:
- `@State private var editingTextID: UUID?` — which text is being edited, if any
- `@State private var pendingTextInserts: Set<UUID>` — drafts placed but not yet committed
- `@State private var editingTextOriginalContent: String?` — what the text said before a re-edit, so undo can put it back

**Placing** (text tool active, tap on empty canvas):

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

**Re-editing** (tap once to select, tap again to edit):

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

This works the same under all three tools, since any of them can leave you with a single text selected.

**`commitTextEdit(id:)` is the one place edits are saved.** It's safe to call twice for a newly placed id because `pendingTextInserts.remove(id)` makes the second call a no-op. For re-edits it's scoped to `editingTextID == id`, so a double-fire (selection change, then focus loss) finds a nil original on the second pass and skips pushing a duplicate command.

What it does depends on the situation:

| Situation | What happens |
|---|---|
| New, still empty | Discarded quietly. No history entry |
| New, has content | Push `.insert`, write to store |
| Re-edit, now empty | Push `.delete` whose snapshot rebuilds the element from the **original** content, so undo brings the text back rather than an empty box. Delete from store |
| Re-edit, content changed | Push `.editTextContent(from, to)`, write to store |
| Re-edit, content identical | Write to store anyway (harmless), no history entry |

## Dragging while editing is disabled on purpose

If a text is being edited, dragging inside it does nothing. The drag handler's first `onChanged` checks `editingTextID` and that text's world rect; if the drag started inside, `currentDragMode` becomes `.none` and the gesture stays inert for its whole lifetime.

Two reasons, both good:

**Convention.** Apple Notes, Pages, Keynote, Figma, and Miro all treat editing and moving as separate modes. To move a text you're editing, tap outside first (which commits through the existing paths), then drag.

**It avoids an unwinnable fight.** UITextView's own text-selection recognizers grab the live touches. SwiftUI's `DragGesture` only ends up seeing the start and end, so live-tracking a move would look like a teleport from first frame to last. Disabling the move leaves UITextView's native text selection working normally, which is the behavior you actually want inside a text field.

## Three ways an edit gets committed

`textViewDidEndEditing` fires `onCommit` when the text view gives up first-responder — but UITextView doesn't do that on its own when you tap some other SwiftUI view. It has to be told. So three explicit paths cover the gaps:

1. **`onChange(of: selection.selectedIDs)`** — the common one. Tapping any other element changes the selection, and the watcher commits if `selectedIDs` now holds anything other than the text being edited. Guarded with `!newIDs.isEmpty` so that a `clearSelection()` — which `insertText` itself calls — doesn't commit and delete a brand-new draft in the same frame. That crashed before the guard existed
2. **`onChange(of: activeTool)`** — switching tools commits first. The one-shot `skipNextToolChangeCommit` flag exempts the auto-swap that `insertText` performs
3. **The empty-canvas tap handler** — `onTapGesture(coordinateSpace: .local)` on the grid `Canvas` commits before deciding whether to place new text or run the tool's `tappedEmpty`

## Resizing text: corners change size, sides change width

A single selected text shows handles at the four corners plus the left and right edge centers. Top and bottom are hidden because text height comes from its content — there's nothing meaningful to drag. `SelectionOverlay` takes a `Set<HandlePosition>` so text can pass a restricted set; `TextElementView.textHandles` is `fileprivate` so the canvas-level chrome can use the same set.

`hitTestHandle` returns a `.singleTextItem(handle, text)` case for solo-text hits and refuses top/bottom edges. Multi-selections fall through to `.group`, which now understands text.

`applyTextResize(translation:)` handles three cases:

- **Corner drag** → scales the font, Freeform-style. It reuses the aspect-locked `computeResizedRect` to get a width ratio, then multiplies the starting `fontSize` by it. If `wrapWidth` was set, it scales too. The origin follows the new rect, keeping the opposite corner pinned. Font can't go below 8pt.

  `computeResizedRect` takes an optional `minDimension` (defaulting to `minImageDimensionWorld`, 64). Text overrides it with `startRect.width * (minTextFontSize / startFontSize)` so the rectangle's floor lines up with the font's own 8pt floor. Without the override, the rectangle stops shrinking at 64pt while the font still has room to go — which feels like the text "snapping" and refusing to get smaller
- **Right-edge drag** → sets `wrapWidth`, left edge pinned. Reference width is the existing `wrapWidth`, or the current `worldRect.width` for auto-width text. Minimum 40pt
- **Left-edge drag** → sets `wrapWidth` *and* shifts `origin.x = startRect.maxX - newWrap`, so the right edge stays put (Figma convention)

Changing `placed.fontSize` / `wrapWidth` / `origin` directly during the drag is fine here: the view re-renders, `onGeometryChange` re-derives `worldRect.size`, and undo already captured the starting state.

**The command:**

```swift
case resizeText(
    elementID: UUID,
    fromFontSize: CGFloat, toFontSize: CGFloat,
    fromWrapWidth: CGFloat?, toWrapWidth: CGFloat?,
    fromOrigin: CGPoint, toOrigin: CGPoint
)
```

It captures everything one resize gesture can touch, including the origin shift from a left-edge drag. `applyTextResizeState(elementID:fontSize:wrapWidth:origin:)` is the shared restore helper used by commit, undo, and redo alike.

## Text inside a group resize

A multi-selection containing text now shows group handles (it used to suppress them). Text scales with the box: `fontSize` and `wrapWidth` both multiply by the **geometric mean** of the width and height ratios — `sqrt(widthRatio * heightRatio)` — and the origin follows the box through the same `scaledRect` helper that moves images.

**Why the geometric mean:** using just the width ratio would break vertical drags. Drag the bottom edge of a group and the width ratio is exactly 1.0, so text wouldn't change size at all while the images stretched. The geometric mean folds both axes together. Corner drags are aspect-locked, so both ratios are equal and it collapses to either one. Side drags pick up the axis that changed, through the other's 1.0.

The `.groupResize` command gains `fromTextStates` and `toTextStates` — dictionaries of `TextResizeSnapshot` (fontSize, wrapWidth, origin) sitting alongside the existing image rect dictionaries. An all-image group has empty text dictionaries; an all-text group has empty rect ones. Either way, one undo press reverses everything at once.

Unlike images (which get their scaled rect at render time), text mutates `placedTexts[idx]` directly each frame in `applyGroupResize`. Text rendering is font-size-plus-frame rather than driven by `worldRect`, and live mutation is cheap for text. For images it's avoided, because re-rendering large image views every frame isn't.

**`applyGroupResizeApply` writes everything in one mutation, and that's load-bearing.** The obvious implementation — call `applyResizeRects` and `applyTextResizeState` per element in a loop — silently loses data. Each call fires its own `enqueueStoreMutation`, and that helper *cancels* whatever is in flight. Only the last write in the loop would survive; every image rect and earlier text change before it would be dropped.

Instead, the shared helper does all in-memory changes synchronously, pre-builds the text `CMCanvasElement`s, then fires **one** `enqueueStoreMutation` that fetches every image element, appends every text element, and upserts the whole batch. Cancellation can then only interrupt work that hasn't been prepared yet, so a group resize commits atomically.

## Handles and the editing border draw outside the text

`scaleEffect` shrinks everything inside the text view, including any `.overlay`. A 10pt handle becomes 2pt at zoom 0.2 — impossible to see and impossible to hit.

So handles and the editing border are drawn at the canvas level in `BoardCanvasView`'s body, using world coordinates times scale (the same approach as image group selection):

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

The faint multi-select border for text inside a group stays *inside* the scaleEffect. It's a minor cosmetic hint, the group's own handles are the real affordance, and shrinking at low zoom is acceptable for it.

## The save-on-back race

`commitTextEdit`'s store write goes through `enqueueStoreMutation`, which is async. Press back while editing and the snapshot used to read `canvasStore.allElements()` before that write landed — so the file got saved without the text you just typed.

The `snapshotTrigger` handler now:
1. Calls `commitTextEdit(editing)` synchronously, starting the store write
2. Captures `storeMutationTask` outside the Task, so the closure holds a stable reference to it
3. Awaits `pendingMutation?.result` before reading `allElements()`

Now the snapshot includes everything typed, no matter how fast you hit back.

## Persistence

`CMCanvasElementPayload.text` and `BoardArchiver.ManifestPayload.text` mirror `PlacedText`'s fields (content, fontName, fontSize, color, wrapWidth). `wrapWidth` uses `encodeIfPresent` / `decodeIfPresent`, so older `.refboard` files that predate the field load fine with `wrapWidth = nil` (auto-width). See `architecture-backend.md` for how the file format evolves.

## Which text actions are undoable

| Action | Command | Notes |
|--------|---------|-------|
| Create text + commit non-empty content | `.insert` | Fired by `commitTextEdit` when newly placed and not empty |
| Re-edit content | `.editTextContent(from, to)` | Only when the content actually changed |
| Re-edit cleared everything | `.delete` | Snapshot rebuilds from original content, so undo restores the text |
| Move text | `.move` | Same command as images; `applyMoveDelta` walks both arrays |
| Resize text (corner / side) | `.resizeText` | Captures fontSize + wrapWidth + origin |
| Group resize including text | `.groupResize` | Extended with text-state dictionaries |
| Delete via action bar | `.delete` | `deleteSelection` snapshots both kinds; `applyResizeRects` filters out text ids defensively |

---

# Settings sheet

**Status: Implemented (native Liquid Glass material)**
**File:** `Features/BoardCanvas/Settings/CanvasSettingsView.swift`

The gear in `CanvasNavigationToolbar` opens a translucent sheet over the canvas. The old `CanvasSettingsButton.swift` and `CanvasOverlayLayout.swift` are gone.

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

**The decisions behind that:**

- **`.presentationBackground(.thinMaterial)`** gives the frosted-glass look. A real `.glassEffect()` can't be used here: sheets sit behind a dimming scrim, so glass can't sample the live canvas the way toolbar buttons can. Material is the correct sheet-level equivalent
- **`.scrollContentBackground(.hidden)` + `.listRowBackground(Color.clear)`** strip `Form`'s opaque grouped background and row fills, so the material shows through the whole sheet instead of just the margins
- **`canvasColorScheme`** keeps the sheet's light/dark mode matched to the canvas behind it, so opening Settings over a dark canvas doesn't flash a bright panel. It's computed from the canvas color's brightness (Rec. 709 luminance, threshold 0.5):

  ```swift
  private var canvasColorScheme: ColorScheme {
      let rgb = canvasColor.resolve(in: environment)
      let lum = 0.2126 * Double(rgb.red) + 0.7152 * Double(rgb.green) + 0.0722 * Double(rgb.blue)
      return lum < 0.5 ? .dark : .light
  }
  ```

- **A real color well.** This used to be an invisible `ColorPicker` layered over a custom pill. Now it's just `ColorPicker("Canvas Color", selection:, supportsOpacity: false)`, and the version row is a native `LabeledContent`
- **One `.tint(DesignSystem.Colors.tertiary)`** on the `NavigationStack` covers the toggle, color well, and Done button — no per-control overrides

**Removed:** the "Toolbar Position" picker (left/right) and the `ToolbarSide` enum went away with the floating overlays. The toolbar is native and lives on top now, so side placement isn't a real choice anymore.

**The two settings that do something:**

1. **Canvas Color** — `@Binding var canvasColor: Color`, applied as `.background(canvasColor)` on the canvas ZStack. New boards and old v1 files default to `Color(uiColor: .systemBackground)`, so the canvas follows the system light/dark setting until you pick something. Once picked, it's saved as `#RRGGBB` in the board file
2. **Show Grid** — `@Binding var showGrid: Bool`, controls the grid layer. Defaults to `true`

---

# Saving the canvas color

**Status: Implemented**

**Files:** `ContentView.swift`, `RootView.swift`, `AppOpenHandler.swift`, `FilePickerView.swift`, `DesignSystem/Colors.swift`. For the file-format side, see `architecture-backend.md` → "Export Package".

The canvas color travels in and out of the board file. The split: SwiftUI owns the live `Color` and the hex conversion (turning an adaptive color into concrete RGB needs an `EnvironmentValues`, which only the view layer has). The backend owns how it's stored on disk (`canvasColor: String?` in the manifest).

**How it travels:**

```
manifest.json:canvasColor (String?)
    ↓ BoardArchiver.importElements → ImportResult.canvasColorHex (String?)
    ↓ FilePickerView.onBoardSelected callback (elements, url, hex)  — or AppOpenHandler.importedCanvasColorHex on .onOpenURL
    ↓ RootView.initialCanvasColorHex (String?)
    ↓ ContentView.init(initialCanvasColorHex:)
    ↓ @State canvasColor (Color)  ← initialCanvasColorHex.flatMap(Color.init(hex:)) ?? Color(uiColor: .systemBackground)
    ↓ ColorPicker + .background(canvasColor) on canvas ZStack
```

**Three pieces of state in `ContentView`:**

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

Three instead of one, because each answers a different question:

1. **`canvasColor`** — what's on screen right now. It might be an adaptive color whose real RGB depends on light or dark mode
2. **`savedCanvasColorHex`** — the concrete hex for the file. It starts from whatever the file had, and only changes when the user actually picks a color:

   ```swift
   .onChange(of: canvasColor) { _, newValue in
       savedCanvasColorHex = canvasColorHexString(from: newValue.resolve(in: environment))
       canvasColorDirty = true
   }
   ```

   Resolving at pick-time rather than save-time is the whole point. `nil` means "no preference, follow the system." If we resolved at save-time instead, then moving an image on a board whose color you never touched would bake the current system background into the file — silently converting "follow the system" into a fixed color the user never chose
3. **`canvasColorDirty`** — makes the save actually happen. `BoardCanvasView`'s dirty flag only watches elements, so changing just the color would leave `wasDirty` false and `saveInPlace` would bail out. Both save paths check `wasDirty || canvasColorDirty`, and clear the flag alongside `markCleanTrigger` once a write succeeds

**The hex helpers (`DesignSystem/Colors.swift`):**

```swift
extension Color {
    nonisolated init?(hex: String) { /* parses #RRGGBB or RRGGBB */ }
}

// Resolved color → "#RRGGBB". Caller resolves Color via env, this just formats.
func canvasColorHexString(from resolved: Color.Resolved) -> String { ... }
```

`init(hex:)` is `nonisolated` because the project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which would otherwise pin it to the main actor — and `ContentView.init` isn't main-actor isolated.

**A known limitation:** the hex is captured the moment `.onChange(of: canvasColor)` fires, in whatever mode you're in at the time. Pick a color from the ColorPicker's "System Colors" tab while in dark mode and you save the dark-mode version of it; reopening in light mode won't adapt. The contract is "the saved color is the color you last had on screen," which is what a single stored value can honestly promise. A true "follow the system" option would be a separate toggle that keeps `savedCanvasColorHex` nil deliberately.

**Security-scoped access:** `BoardArchiver.importElements` starts and stops security-scoped access itself. `FilePickerView.openBoard` used to wrap its detached task in a second, redundant pair; that's been removed so the archiver is the single owner.

---

# Design system

**Status: Implemented**
**Files:** `DesignSystem.swift`, `Colors.swift`

One place for colors, so the app looks like one app.

```swift
DesignSystem.Colors.primary     // #191919 (25, 25, 25)   - Dark gray
DesignSystem.Colors.secondary   // #535353 (83, 83, 83)   - Medium gray
DesignSystem.Colors.tertiary    // #3977F8 (57, 119, 248) - Saturated blue
DesignSystem.Colors.text        // #FFFFFF (255, 255, 255) - White
DesignSystem.Colors.destructive // #FE8686 (254, 134, 134) - Red
```

| Token | Used for |
|---|---|
| `primary` | Backgrounds — toolbars, settings, containers |
| `secondary` | Quieter text, values, picker options |
| `tertiary` | Anything interactive — active states, toggles, buttons |
| `text` | Main labels and readable content |
| `destructive` | Delete buttons and destructive confirmations |

## The rule: use a token, not a raw color

**Always prefer a `DesignSystem.Colors` token over a hard-coded color** — no `.red`, no `Color(red:…)`, no hex literals, no system semantic colors. New UI pulls from the palette so the app stays coherent and can be themed later.

If the color you need isn't there:

1. Stop. Don't reach for `.red` or `Color(hex:)` as a shortcut
2. Decide what it is: a **new semantic token** (`destructive`, `warning`, `success`) or a genuine one-off. Semantic tokens belong in `Colors.swift`
3. Pick a hue at the palette's saturation and lightness so it sits naturally with the rest. `destructive` (#FE8686) is `tertiary`'s saturation and lightness with a red hue — that's the method
4. Add it to `DesignSystem.Colors` with a doc comment explaining intent, then use it by name

The same goes for any other design primitive that lives (or should live) in the design system — spacing, corner radii, shadows, typography. Hard-coding the same value twice is the signal that it should be a token.

**Structure:** `DesignSystem` is a namespace enum, `Colors` is a nested enum of static colors, and it's built to grow (typography, spacing, shadows).

---

# Other UI

## FilePickerView — the landing screen

**Status: Implemented**
**Files:** `FilePickerView.swift`, `RecentBoardsList.swift`, `RecentBoardRow.swift`, `LiftPressStyle.swift`, `RecentBoardsManager.swift`

Three ways into the canvas, plus a recent boards list.

1. **"New Board"** (main action) — `.buttonStyle(.glassProminent)` with a blue tint. Opens a `.fileExporter` for `Untitled Board.refboard`. On success you get an empty canvas whose `currentBoardURL` is already set, so the back button has somewhere to save to
2. **"Open Board"** — `.buttonStyle(.glass)` with a blue tint. Opens a `.fileImporter` for `.refboard` files, imports through `BoardArchiver.importElements` on a detached task, records it in recents, and hands the elements and URL to `ContentView`
3. **Drag and drop** — drop images or GIFs onto the dashed rectangle. `.contentShape(.rect)` makes the whole padded area a drop target, not just the icon and text

**Visual notes:**
- The background stays flat `DesignSystem.Colors.primary`. Liquid Glass on a flat dark fill renders muted — Apple's own docs say so — and we accept that for the big surfaces (drop zone, recents), reserving glass for the CTA buttons where `.buttonStyle(.glass)` has its own fallbacks
- A large `photo.on.rectangle.angled` icon, sized with `@ScaledMetric` for Dynamic Type, marked `.accessibilityHidden(true)`
- The dashed border highlights while a drag is over it (`isTargeted`)
- Both buttons sit side by side below it
- "Recent Boards" shows up to 5 entries
- Failed imports raise an alert (`showImportError` + `importErrorMessage`)

**The recents list:**

It's a stack of individual cards, not one container with dividers between rows. Each row owns its background, so the press effect (`LiftPressStyle`) can scale the whole card instead of just its contents. Rows stack flush (`VStack(spacing: 0)`), and only the first row's top corners and last row's bottom corners are rounded via `UnevenRoundedRectangle` — so the group reads as one shape while each row stays independently pressable.

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

**`LiftPressStyle`** (`Features/FilePicker/LiftPressStyle.swift`) mimics the lift of a native glass button on a plain row — scale to 1.02, rise 2pt, spring back:

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

It exists because we want tactile feedback on recents rows without the full glass material, which doesn't render well on the flat dark background.

**`RecentBoardsManager`** is `@Observable @MainActor` and stores up to 10 entries as JSON in App Support (`recent_boards.json`). Each entry has:
- `name` — from the filename
- `filePath` — standardized path string, used as both the stable `Identifiable.id` and the dedup key
- `bookmarkData` — a bookmark created with `.suitableForBookmarkFile` from the URL the file importer gave us. This preserves the URL's implicit security scope on iOS. (The explicit `.withSecurityScope` option is macOS-only — don't reach for it here.) It's what lets the app reopen files across launches wherever they live
- `lastOpened` — for sorting

The landing page shows up to 5 valid entries with a doc icon, name, and relative date. Tapping resolves the bookmark via `resolveURL()`, starts security-scoped access, and imports.

Entries whose `resolveURL()` returns nil are pruned on init, so `validEntries(limit:)` does no file I/O — it just slices the already-cleaned array.

`RecentBoardsManager` is created as `@State` in `RootView` and injected with `.environment()` into both `FilePickerView` and `ContentView`. Entries are recorded when a board is opened (picker or recents), imported from the canvas toolbar, exported successfully, or saved on back.

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

`onNewBoard` passes back the save location chosen in the exporter, so `ContentView` can set `currentBoardURL` for save-on-back. `RootView` hosts the picker and routes to `ContentView` based on which callback fires, carrying `initialBoardURL` through so saves land in the right place.

## Save-on-back

Back navigation runs through the leading toolbar's chevron. The old floating `CanvasStatusBar` / `CanvasBackButton` are gone.

1. Tapping back sets `pendingBackNavigation = true` and fires a canvas snapshot via `snapshotToken`
2. The `onSnapshot` callback sees the flag and calls `saveAndGoBack(elements:wasDirty:)`
3. `saveAndGoBack` writes to `currentBoardURL` through `BoardArchiver.export` on a detached task, flips `markCleanTrigger`, then calls `onBack()`, which sets `showCanvas = false` in `RootView`
4. If the write throws, an alert offers "Discard & Leave" or "Stay". Otherwise navigation continues

Because "New Board" makes you choose a save location up front, `currentBoardURL` always exists by the time the canvas appears — the back button always has a destination.

---

# What's next

## Planned

1. **Tools**
   - ~~Connect `activeTool` to canvas interactions~~ ✅
   - ~~Selection via pointer tool~~ ✅
   - ~~Marquee select for group tool~~ ✅
   - ~~Group move/resize~~ ✅

2. **Item interaction**
   - ~~Tap to select~~ ✅
   - ~~Drag to move~~ ✅
   - ~~Resize handle visuals~~ ✅
   - ~~Working resize via corner and edge handles~~ ✅
   - ~~Undo/redo for move, resize, insert, group resize~~ ✅
   - ~~Multi-select via marquee and toggle-tap~~ ✅
   - ~~Group move~~ ✅
   - ~~Group resize~~ ✅
   - ~~Delete selected items~~ ✅
   - Rotation gestures

3. **Settings**
   - Grid spacing slider
   - Export options

4. **Navigation**
   - ~~`FilePickerView` as the first screen~~ ✅
   - ~~Picker → canvas transition~~ ✅
   - ~~Back navigation with save-on-back~~ ✅
   - ~~Recent boards~~ ✅
   - **Save-As prompt for new boards on back.** Right now, if a user somehow reaches the canvas with no `currentBoardURL` and taps back, the board is silently discarded. The flow should be: back tap → snapshot → file exporter → on success record in recents and navigate back; on cancel, stay on the canvas

5. **Performance**
   - Optimize render updates
   - Image caching strategy

---

# Known cleanup opportunities

None of these are bugs. They're size and hygiene items worth a dedicated pass before the file gets harder to navigate.

## `BoardCanvasView.swift` is too big

**As of the text-elements branch:** ~2,356 lines, with `body` alone around 515.

`body` now runs several distinct render passes, interleaved:
- Background grid `Canvas`
- Image `ForEach`
- Text `ForEach`
- Solo-text selection chrome
- Editing border
- Marquee overlay
- Floating action bar
- Group bounding box
- The drag gesture chain
- Many `.onChange` handlers (snapshot, mark-clean, load, active-tool, selection-change, undo/redo)

Each pass is a candidate for its own `View` struct in its own file, per `references/views.md`: *"Strongly prefer to avoid breaking up view bodies using computed properties or methods that return `some View`. Extract them into separate `View` structs instead, placing each into its own file."*

**Rough sketch** (refine when actually doing it):
- `BoardCanvasGridLayer` — the grid background
- `PlacedImagesLayer` — the image `ForEach`
- `PlacedTextsLayer` — the text `ForEach`
- `SelectionChromeLayer` — solo-text handles, editing border, group bbox, action bar
- `BoardCanvasView` keeps state ownership, gesture wiring, and composition

## Multiple types per file — resolved

`BoardCanvasView.swift` is now ~2,120 lines (down from ~2,470) and holds only `BoardCanvasView`. The rest moved to:
- `Features/BoardCanvas/Elements/PlacedImage.swift`
- `Features/BoardCanvas/Elements/PlacedText.swift`
- `Features/BoardCanvas/Elements/TextElementView.swift`
- `Features/BoardCanvas/Elements/FileImageView.swift`
- `Features/BoardCanvas/Elements/ImageCache.swift`
- `Features/BoardCanvas/Import/CanvasDropDelegate.swift`
- `Features/BoardCanvas/Import/ItemProviderHelpers.swift`

The duplicated file-loading code is also gone: `InsertFileControl` was deleted (it was never used outside its own `#Preview`), and both the drop handler and `FilePickerView` now call `ItemProviderHelpers.swift`.

## Concurrency cleanup

- **`Task.sleep(nanoseconds:)`** in `scheduleRefreshVisibleElements` (`BoardCanvasView.swift` ~line 1030). `references/api.md` says use `.sleep(for:)`. Pre-existing on `main`
- **`DispatchQueue.main.async` in trigger-clear patterns.** `undoTrigger`, `redoTrigger`, `homeTrigger`, and `externalInsertURLs` clear themselves this way, and `references/swift.md` says no GCD. These can move to `Task { @MainActor in ... }`. **The `elementsToLoad` handler is the exception** — its run-loop drain guarantee is doing real work there (see "Landing snap"). Leave it alone

(The text-elements PR added one `DispatchQueue.main.async` in `CanvasTextField.swift` for `becomeFirstResponder`; it's already converted.)

## Toolbar accessibility — resolved

Every button in `CanvasNavigationToolbar` uses `Label("Title", systemImage:)`, which carries the title for both VoiceOver and the overflow menu. The active tool also gets `.accessibilityAddTraits(.isSelected)`, so selection isn't conveyed by color alone. The standalone `CanvasSettingsButton` and `CanvasOverlayLayout` back button are deleted.

## The per-text `.onTapGesture` mixes layout with state-machine logic

That closure handles two jobs: tapping the only selected text re-enters editing, and tapping any other text routes selection through the active tool. It branches on `selection.selectedIDs` and `editingTextID` and dispatches a Task. Per `references/views.md` ("Button actions should be extracted from view bodies into separate methods"), it belongs in a method on `BoardCanvasView`. It wasn't extracted in that PR because the focus/selection state machine was being actively changed and the risk of breaking it was high.

---

# Where frontend meets backend

1. **Models**
   - Frontend uses the simplified `PlacedImage`
   - Backend defines `CMCanvasElement`, `CMElementHeader`, `CMCanvasElementPayload`
   - **Future:** replace `PlacedImage` with `CMCanvasElement`

2. **Coordinates**
   - Frontend: `CGFloat`, `CGPoint`, `CGRect`
   - Backend: `SIMD2<Double>`, `CMWorldRect`
   - **Needed:** conversion helpers between the two

3. **Persistence**
   - Frontend keeps `placedImages` in `@State` and syncs to `LocalBoardStore` on insert, move, resize, delete
   - All store changes are serialized through `enqueueStoreMutation()`
   - Move/resize use `elements(for:)` + `upsert(elements:)` for batching
   - Marquee select uses `headers(in: CMWorldRect)`
   - Insert-undo uses `delete(elementIDs:)`
   - Hit testing uses `topmostHeader(at:)`
   - `moveToTop(elementIDs:)` raises selected items on interaction

4. **Tiles**
   - Backend implements `CMTileKey` spatial indexing
   - Frontend uses it for viewport culling via `headers(in:viewport:margin:)` and for hit testing

---

# Notes

- This reflects the MVP as built
- Focus is core interaction and visual polish
- Performance work is deferred until item count actually becomes the bottleneck
- The clean split from the backend lets both sides iterate independently
