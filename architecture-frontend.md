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

**Spatial Tap Gesture:**
- `SpatialTapGesture()` as `.simultaneousGesture` — handles taps independently of drag
- Required because `DragGesture(minimumDistance: 8)` never fires for taps (< 8pt movement)
- Delegates to active tool's `tapped()` method for hit-testing and selection changes

**Zoom (Magnification Gesture):**
- `MagnificationGesture()` as `.simultaneousGesture` — always active regardless of tool
- Zooms around **view center** (not finger/cursor location)
- Preserves world position at anchor point during zoom
- Gesture state: `zoomStartScale` stores scale at gesture begin

**Known Limitation:**
- Zoom anchors around view center instead of pinch location
- A `PinchGestureView.swift` component was created to capture UIKit pinch gestures with precise anchor points
- Initial integration attempts had issues; reverted to `MagnificationGesture` for stability
- Anchor-based zoom remains a future enhancement

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
- Observes `openHandler.$importedElements` so `.refboard` cold launches navigate directly to canvas
- `ContentView` receives selected URLs as a `let initialURLs: [URL]` (not a binding)

**ContentView:**
- Hosts `BoardCanvasView` in a `ZStack`
- Overlays `CanvasToolbar` (centered left) and `CanvasSettingsButton` (bottom-left)
- Manages `@State private var urlsToInsert: [URL]?` binding for file picker integration
- On `.onAppear`, forwards `initialURLs` to `urlsToInsert` for the canvas to consume
- Presents `.fileImporter` when toolbar "Add Item" is tapped
- Presents `.sheet` with `CanvasSettingsView` when settings button is tapped

**File Picker Integration:**
- Toolbar's `onAddItem` callback sets `importerMode = .images`
- `.fileImporter` allows multiple selection of `.image` and `.gif` types
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
- `CanvasTool`: Enum defining available tools (`.pointer`, `.group`)

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
    └── GroupToolBehavior      -- stub (falls back to pan for now)
```

**Protocol:**

```swift
protocol CanvasToolBehavior {
    func dragBegan(worldStart: CGPoint, store: LocalBoardStore, selection: CanvasSelectionState) async -> DragMode
    func tapped(worldPoint: CGPoint, store: LocalBoardStore, selection: CanvasSelectionState) async
}
```

**DragMode enum:** `.pan`, `.moveItem`, `.none`

**Gesture Routing:**

A single `DragGesture(minimumDistance: 8)` on the canvas ZStack delegates to the active tool's behavior:
1. On first `.onChanged` event: hit-test via tool behavior → cache `DragMode` for gesture duration
2. Subsequent `.onChanged`: `applyDrag()` routes to pan or move based on cached mode
3. `.onEnded`: if translation < 4pt, treat as tap → call `behavior.tapped()`; if `.moveItem`, call `commitMove()`

**Pointer Tool Behavior:**
- Drag on item → select it, bring to top, enter `.moveItem` mode
- Drag on empty canvas → `.pan` mode (normal canvas pan)
- Tap on item → select it
- Tap on empty → clear selection

**Group Tool:** Stub — returns `.pan` for all drags, no-op for taps. Ready for future marquee select.

**Factory:** `toolBehavior(for: CanvasTool) -> CanvasToolBehavior` maps enum to concrete behavior.

**Adding New Tools:**
1. Add case to `CanvasTool` enum
2. Create a struct conforming to `CanvasToolBehavior`
3. Add mapping in `toolBehavior(for:)` factory

---

### Selection & Move System

**Status: Implemented**

**Files:** `CanvasSelectionState.swift`, `HandlePosition.swift`, `SelectionOverlay.swift`, `BoardCanvasView.swift`

**Selection State:**

`CanvasSelectionState` is an `@Observable` class owned as `@State` in `BoardCanvasView`:
- `selectedIDs: Set<UUID>` — currently selected element IDs
- `dragOffset: CGSize` — world-space offset during active drag-move
- `isDragging: Bool` — whether a move drag is in progress
- `select(_:extending:)` — select an item (extending parameter for future multi-select)
- `clearSelection()` — deselect all

**Visual Indicators:**

**Files:** `SelectionOverlay.swift` (view), `HandlePosition.swift` (data model)

Selected items display a `SelectionOverlay` via `.overlay` (applied before `.position()` so it renders in the item's coordinate space):
- Blue stroke border (`DesignSystem.Colors.tertiary`, 2pt)
- White handles (10×10pt rounded rectangles with blue border) at 8 positions: 4 corners + 4 edge midpoints
- `HandlePosition` enum (in `HandlePosition.swift`) defines `.topLeft`, `.topCenter`, `.topRight`, `.leftCenter`, `.rightCenter`, `.bottomLeft`, `.bottomCenter`, `.bottomRight`
- Extracted to its own file to avoid coupling `CanvasSelectionState` to the view layer
- Each handle has helper properties: `anchorPosition` (opposite handle), `isCorner`, `isLeftSide`, `isTopSide`

**Move Interaction:**

1. User drags a selected item → `applyDrag()` sets `selection.dragOffset` in world space
2. During drag, selected items render with a live offset: `position + (dragOffset * scale)` — no store updates per frame
3. On drag end, `commitMove()` pushes a `.move` command to history, then applies via `applyMoveDelta()`

**Resize Interaction:**

**Status: Implemented**

1. On drag start, `hitTestHandle(screenPoint:)` checks screen-space distance to all 8 handles on the selected item (hit radius: 30pt)
2. If a handle is hit → `.resizeItem` drag mode, bypassing tool behavior routing
3. During drag, `applyResize(translation:)` computes the new world rect:
   - **Corner handles:** aspect-ratio-locked resize, opposite corner pinned
   - **Edge handles:** single-axis stretch (width or height only), opposite edge pinned
   - Minimum dimension enforced (`minImageDimensionWorld = 64`)
4. Live rect stored in `selection.resizeCurrentRect`, used by render loop for immediate visual feedback
5. On drag end, `commitResize()` skips no-op resizes (where `newRect == startRect`), then pushes a `.resize` command to history and applies via `applyResizeRect()`
6. Single-select only for now; resize is skipped if multiple items are selected

**Resize State** (in `CanvasSelectionState`):
- `resizeHandle: HandlePosition?` — which handle is being dragged
- `resizeStartRect: CGRect?` — element's world rect at drag start
- `resizeCurrentRect: CGRect?` — live rect during drag
- `resizeElementID: UUID?` — element being resized
- `isResizing: Bool` — computed from `resizeHandle != nil`
- `clearResize()` — resets all resize state

**Performance:**

Store updates are batched — one `elements(for:)` fetch + one `upsert(elements:)` call regardless of selection count (2 actor round-trips, not 2N). This scales for future multi-select.

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
| `.insert` | `snapshots: [PlacedElementSnapshot]` | Remove elements | Re-add elements |
| `.delete` | `snapshots: [PlacedElementSnapshot]` | Re-add elements | Remove elements |

`PlacedElementSnapshot` captures everything needed to fully add/remove an element: `id`, `url`, `worldRect`, `zIndex`, and the full `CMCanvasElement`.

**History Management:**

- `CanvasCommandHistory` is an `@Observable` class owned as `@State` in `ContentView` and passed to `BoardCanvasView`
- `push(_:)` — appends to undo stack, clears redo stack
- `popUndo()` / `popRedo()` — moves commands between stacks
- `canUndo` / `canRedo` — computed properties for UI state

**Integration:**

- Toolbar undo/redo buttons fire UUID trigger bindings (`undoTrigger`, `redoTrigger`)
- `BoardCanvasView` observes triggers via `.onChange` and calls `performUndo()` / `performRedo()`
- Each method pops a command and dispatches to shared helpers: `applyMoveDelta()`, `applyResizeRect()`, `addElements()`, `removeElements()`

**Adding New Undoable Operations:**

1. Add a case to `CanvasCommand` enum
2. Push the command in the action's commit function
3. Add undo/redo handling in `performUndo()` / `performRedo()`

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

`ContentView` implements two layout variants:
- `leftSideLayout` - Toolbar + settings on left (default)
- `rightSideLayout` - Toolbar + settings on right (mirrored)
- Both maintain 16pt padding from edges
- Settings button always positioned with toolbar for consistency

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
DesignSystem.Colors.primary   // #191919 (25, 25, 25) - Dark gray
DesignSystem.Colors.secondary // #535353 (83, 83, 83) - Medium gray  
DesignSystem.Colors.tertiary  // #86B8FE (134, 184, 254) - Light blue
DesignSystem.Colors.text      // #FFFFFF (255, 255, 255) - White
```

**Usage:**
- Backgrounds: `primary` (toolbars, settings, UI containers)
- Secondary text/values: `secondary` (subtle information, picker options)
- Interactive accents: `tertiary` (active states, toggles, buttons)
- Primary text: `text` (main labels, readable content)

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

**FilePickerView**

**Status: Implemented (Landing Screen)**

**File:** `FilePickerView.swift`

A full-screen empty state view that serves as the app's landing screen for initial file selection.

**Purpose:**
- First screen users see on app launch
- Large drop zone with dashed border for drag-and-drop
- "Browse" button to open file picker
- Once files are selected, transitions to the canvas

**Visual Design:**
- Large photo icon (`photo.on.rectangle.angled`, size 80pt)
- "Drag and drop images here" / "or" / "Browse" button
- Dashed border that highlights on drag target (`isTargeted` state)
- Uses `DesignSystem.Colors` for consistency

**File Selection:**
- `.fileImporter` supports `.image` and `.gif` types with multiple selection
- Drag-and-drop saves `UIImage` objects to temp PNG files via `loadImageToTempFile(from:)` so they flow through the same URL-based pipeline as the browse button

**API:**
```swift
FilePickerView(onFilesSelected: ([URL]) -> Void)
```

**Integration:**
- `RootView` hosts `FilePickerView` and passes an `onFilesSelected` callback
- Callback triggers navigation to `ContentView` with the selected URLs

---

## Future Frontend Work

### Planned Enhancements

1. **Anchor-based Zoom:**
   - Integrate `PinchGestureView` to zoom toward finger location instead of view center
   - Debug UIKit gesture recognizer interaction with SwiftUI gestures

2. **Tool Behavior:**
   - ~~Connect `activeTool` state to actual canvas interactions~~ ✅ Done
   - ~~Implement selection via pointer tool~~ ✅ Done
   - Implement selection rectangles / marquee select for group tool
   - Implement grouping behavior for group tool

3. **Item Interaction:**
   - ~~Select items on tap~~ ✅ Done
   - ~~Move items by dragging~~ ✅ Done
   - ~~Resize handle visuals~~ ✅ Done
   - ~~Functional resize via corner and edge handle drag~~ ✅ Done
   - ~~Undo/redo for move, resize, and insert~~ ✅ Done
   - Delete selected items (command exists, needs UI trigger)
   - Rotation gestures
   - Multi-selection (CanvasSelectionState already supports it via `extending` parameter)

4. **File Import Refactor:**
   - Extract duplicate file loading code into `FileImportHelpers.swift`
   - Consolidate loading logic between `BoardCanvasView` and `InsertFileControl`

5. **Settings Implementation:**
   - Make `CanvasSettingsView` functional
   - Bind grid toggle to `BoardCanvasView.showGrid`
   - Grid spacing slider
   - Add export options

6. **Navigation Flow:**
   - ~~Integrate `FilePickerView` as initial screen~~ ✅ Done
   - ~~Transition from file picker → canvas~~ ✅ Done
   - Board selection/management UI
   - Back navigation from canvas to file picker

7. **Performance:**
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
   - Move/resize operations use `elements(for:)` + `upsert(elements:)` for batched updates
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
