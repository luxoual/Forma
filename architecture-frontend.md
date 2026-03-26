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

**Pan (Drag Gesture):**
- `DragGesture(minimumDistance: 0)` captures all drag input
- Updates `offset` by accumulating translation from gesture start
- Gesture state: `dragStartOffset` stores offset at gesture begin

**Zoom (Magnification Gesture):**
- `MagnificationGesture()` captures pinch-to-zoom on trackpad/indirect input
- Currently zooms around **view center** (not finger/cursor location)
- Preserves world position at anchor point during zoom
- Gesture state: `zoomStartScale` stores scale at gesture begin

**Simultaneous Recognition:**
- `.simultaneousGesture()` allows pan and zoom to work together
- Gestures do not block each other

**Known Limitation:**
- Zoom anchors around view center instead of pinch location
- A `PinchGestureView.swift` component was created to capture UIKit pinch gestures with precise anchor points
- Initial integration attempts had issues; reverted to `MagnificationGesture` for stability
- Anchor-based zoom remains a future enhancement

---

### Image Placement System

**Placement Logic:**

Images are placed via `insertImages(atScreenPoint:urls:)`:

1. **File Security:** Files are copied to `Application Support/ImportedImages/` to ensure sandbox access
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

**ContentView:**
- Hosts `BoardCanvasView` in a `ZStack`
- Overlays `CanvasToolbar` (centered left) and `CanvasSettingsButton` (bottom-left)
- Manages `@State private var urlsToInsert: [URL]?` binding for file picker integration
- Presents `.fileImporter` when toolbar "Add Item" is tapped
- Presents `.sheet` with `CanvasSettingsView` when settings button is tapped

**File Picker Integration:**
- Toolbar's `onAddItem` callback sets `showingFilePicker = true`
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
- Callbacks for actions: `onUndo`, `onRedo`, `onAddItem`
- `onAddItem` opens `.fileImporter` for selecting images/GIFs
- Tool state **not yet connected** to canvas behavior (planned for next iteration)

---

### Canvas Settings Button

**Status: Implemented**

**File:** `CanvasSettingsButton.swift`

A standalone settings button positioned at the bottom-left of the canvas, separate from the main toolbar but matching its visual styling.

**Visual Design:**

- **Position**: Bottom-left corner (16pt leading padding, 16pt bottom padding)
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

- Positioned separately from `CanvasToolbar` in `ContentView`
- Opens `.sheet` with `CanvasSettingsView` when tapped
- `@State private var showingSettings` controls sheet presentation
- Callback: `onTap: () -> Void`

**Settings Sheet:**

- **File:** `CanvasSettingsView.swift`
- Navigation-based settings interface
- Placeholder options (grid settings, version info)
- "Done" button to dismiss
- Ready for expansion with functional settings controls

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
```

**Usage:**
- Toolbar backgrounds: `primary`
- Inactive icons/UI elements: `secondary`
- Active states and accents: `tertiary`

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

**Status: Implemented (Separate Screen)**

**File:** `FilePickerView.swift`

A full-screen empty state view for initial file selection before entering the canvas.

**Purpose:**
- Acts as the entry point screen before `BoardCanvasView`
- Large drop zone with dashed border
- "Browse" button to open file picker
- Designed for initial board creation workflow

**Visual Design:**
- Large photo icon (`photo.on.rectangle.angled`, size 80pt)
- "Drag and drop images here" / "or" / "Browse" button
- Dashed border that highlights on drag target
- Uses `DesignSystem.Colors` for consistency

**Integration:**
- Currently exists as standalone view
- **Not yet integrated** into main app navigation flow
- Intended to precede `ContentView` in final board creation flow

---

## Future Frontend Work

### Planned Enhancements

1. **Anchor-based Zoom:**
   - Integrate `PinchGestureView` to zoom toward finger location instead of view center
   - Debug UIKit gesture recognizer interaction with SwiftUI gestures

2. **Tool Behavior:**
   - Connect `activeTool` state to actual canvas interactions
   - Implement selection rectangles when pointer tool is active
   - Implement grouping behavior for group tool

3. **Item Interaction:**
   - Select items on tap
   - Resize handles for selected items
   - Rotation gestures
   - Delete selected items
   - Multi-selection

4. **File Import Refactor:**
   - Extract duplicate file loading code into `FileImportHelpers.swift`
   - Consolidate loading logic between `BoardCanvasView` and `InsertFileControl`

5. **Settings Implementation:**
   - Make `CanvasSettingsView` functional
   - Bind grid toggle to `BoardCanvasView.showGrid`
   - Grid spacing slider
   - Add export options

6. **Navigation Flow:**
   - Integrate `FilePickerView` as initial screen
   - Board selection/management UI
   - Transition from file picker → canvas

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
   - Dev A manages items in `@State` (ephemeral)
   - Dev B has `LocalCanvasService` and `LocalBoardStore` ready
   - **Next step:** Wire canvas changes to persistence layer

4. **Tile System:**
   - Dev B has implemented `CMTileKey` spatial indexing
   - Dev A doesn't use it yet (renders all items)
   - **Future optimization:** Use tile system for visibility culling

---

## Notes

- Architecture reflects MVP implementation
- Focus is on core interaction and visual polish
- Performance optimizations deferred until item count becomes a bottleneck
- Clean separation from backend allows independent iteration
