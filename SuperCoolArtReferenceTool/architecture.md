# Architecture Documentation

⚠️ This document intentionally begins **decision-pending**.

The purpose of this file is to gradually document **technical architecture decisions** as they become stable during development.

Developers and AI agents should update this document **only after implementation details are validated in the codebase**.

This file should reflect the **actual implemented system**, not speculative designs.

---

# Current Status

Architecture is **early-stage** and many systems are still being defined.

The following sections represent **areas where decisions will eventually be documented**, but most details are intentionally left open until implementation stabilizes.

---

# System Areas

## Infinite Canvas System

Decision Status: **Implemented (MVP)**

### Core Architecture

The canvas system is implemented in `BoardCanvasView.swift` as a standalone, reusable component that provides pan/zoom navigation and image placement on an infinite 2D plane.

**World Coordinate System:**
- World space uses `CGFloat` coordinates with origin at (0, 0)
- Items are positioned using world coordinates independent of screen/viewport
- World units are arbitrary but consistent (currently ~1 unit per screen point at 1.0 scale)

**Camera/Transform Model:**
- `offset: CGSize` - Translation from world origin to screen space (in screen points)
- `scale: CGFloat` - Uniform scale factor (zoom level)
- Bounds: `minScale = 0.05`, `maxScale = 8.0`
- Transform: `screenPoint = worldPoint * scale + offset`

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
- Origin crosshair (red) for debugging coordinate system
- Grid can be toggled via `showGrid` state

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
- A `PinchGestureOverlay.swift` component exists to capture UIKit pinch gestures with precise anchor points, but is **not yet integrated** into `BoardCanvasView`
- Current zoom uses view center as anchor, not the actual pinch location
- Integration planned for next iteration

### Image Placement System

**Placement Logic:**
Images are placed via `insertImages(atScreenPoint:urls:)`:

1. **File Security:** Files are copied to `Application Support/ImportedImages/` to ensure sandbox access
2. **Size Calculation:** 
   - Pixel dimensions read via `CGImageSource` 
   - Scaled to world units preserving aspect ratio
   - Max dimension: 512 world units, min: 64 world units
3. **Anti-Overlap:** `firstNonOverlappingRect(near:size:)` nudges placement diagonally if overlapping existing items (max 64 attempts)
4. **Z-Ordering:** Auto-incrementing `nextZIndex` ensures new items appear on top

**Placement Sources:**
- Drop gesture (drag files onto canvas)
- File import via `InsertFileControl` (not yet wired to canvas)

**Data Model:**
Private `PlacedImage` struct:
```swift
struct PlacedImage: Identifiable {
    let id: UUID
    let url: URL          // Local file URL
    var worldRect: CGRect // Position/size in world coordinates
    var zIndex: Int       // Render order
}
```

**Image Rendering:**
- `FileImageView` loads images asynchronously from file URLs
- Uses `.resizable()`, `.scaledToFill()` with `.clipped()`
- Shows `ProgressView` placeholder during load
- Transform applied: frame size scaled by `scale`, position calculated from world center

### Drop Handling

**Supported Types:**
- `UTType.image` (PNG, JPEG, etc.)
- `UTType.gif`

**Implementation:**
- `CanvasDropDelegate` conforms to `DropDelegate`
- Validates providers have allowed types
- Loads file URLs asynchronously via `loadURLsFromProviders`
- Handles both file representations and data→temp file fallback

**File Loading:**
Async loading via `NSItemProvider` extensions:
- `loadFileURLCompat(for:)` - tries file representation
- `loadDataAsTempFileCompat(for:)` - fallback to data, writes temp file

### Integration Points

**ContentView:**
- Hosts `BoardCanvasView` in a `ZStack`
- Overlays `CanvasToolbar` at leading edge
- Receives import callback (currently prints URLs, not yet connected to insertion)

**Canvas Toolbar:**
- Positioned at `.leading` with 16pt padding
- Binds to `activeTool` state in `ContentView`
- Tool selection **not yet connected** to canvas behavior
- Undo/redo/add callbacks are placeholders

### Performance Considerations

**Current Approach (MVP):**
- All placed items rendered every frame
- No spatial indexing or visibility culling
- Acceptable for small boards (<100 items)

**Future Optimization Paths:**
- Implement visibility culling based on transformed viewport bounds
- Use `CMTileKey` system (already defined in `CanvasModels.swift`) for spatial indexing
- Consider render caching for static content
- Investigate Metal-based rendering for large item counts

---

## Canvas Item Model

Decision Status: **Partially Implemented (Dev B)**

**File:** `CanvasModels.swift`

**Note:** These models are implemented by Dev B for the persistence/data layer. Dev A's current `BoardCanvasView` uses a simplified `PlacedImage` struct for MVP. Full integration pending.

### Element Types

**Enum:** `CMElementType`
```swift
enum CMElementType: String, Codable, Hashable {
    case rectangle, ellipse, path, text, image
}
```

### Core Data Structures

**CMCanvasElement:**
Complete canvas item with header (metadata) and payload (type-specific data).

**CMElementHeader:**
Common metadata shared by all element types:
- `id: UUID` - Unique identifier
- `type: CMElementType` - Element type discriminator
- `transform: CMAffineTransform2D` - 3x3 affine transformation matrix
- `bounds: CMWorldRect` - Bounding box in world coordinates
- `layerId: CMLayerID` (typealias for `UUID`)
- `zIndex: Int` - Rendering order within layer

**CMCanvasElementPayload:**
Enum with associated values for type-specific data:
- `.rectangle(fillColor: String)`
- `.ellipse(fillColor: String)`
- `.path(points: [SIMD2<Double>], strokeColor: String, strokeWidth: Double)`
- `.text(content: String, fontName: String, fontSize: Double, color: String)`
- `.image(url: URL, size: SIMD2<Double>)`

### Coordinate System

**CMWorldRect:**
Represents rectangular areas in world space using `SIMD2<Double>`.

Properties:
- `origin: SIMD2<Double>` - Top-left corner
- `size: SIMD2<Double>` - Width and height

Methods:
- `intersects(_:)` - Rectangle intersection test
- `union(_:)` - Returns bounding rect of two rectangles

**CMAffineTransform2D:**
3x3 transformation matrix using `simd_double3x3`.
- Supports translation, rotation, scale, skew
- Custom `Codable` implementation serializes as flat array of 9 doubles
- Custom `Hashable` implementation for equality/hashing

### Tile System (Spatial Indexing)

**CMTileKey:**
Identifies tiles in a uniform grid for spatial partitioning.

Constants:
- `static let size: Double = 1024` - Tile size in world units

Methods:
- `static func keysIntersecting(rect:)` - Returns all tile keys overlapping a world rect
- Used for efficient spatial queries in large canvases

**Purpose:**
Enables O(1) lookup of items in a spatial region by dividing world space into 1024×1024 unit tiles.

### Current Integration Status

**Dev A (BoardCanvasView):**
- Uses simplified `PlacedImage` struct with `worldRect: CGRect` and `zIndex: Int`
- Does not yet use `CMCanvasElement` or related models
- Coordinates in `CGFloat` instead of `SIMD2<Double>`

**Dev B (Persistence Layer):**
- `CMCanvasElement` models are defined and ready
- `LocalCanvasService` and `LocalBoardStore` implement storage using these models
- Tile-based spatial indexing implemented

**Integration Path:**
- Dev A will migrate from `PlacedImage` to `CMCanvasElement` when connecting to persistence
- Coordinate conversion helpers needed between `CGFloat`-based SwiftUI and `Double`-based SIMD
- Item manipulation UI (selection, resize, rotate) will update `CMElementHeader.transform`

---

## Canvas UI Overlay System

Decision Status: **Implemented**

### Canvas Toolbar (HUD)

**Status: Implemented**

The Canvas Toolbar provides tool selection and canvas actions through a persistent left-side overlay.

**Components:**

- `CanvasToolbar`: Main toolbar view component
- `ToolbarButton`: Reusable button component with active state support
- `CanvasTool`: Enum defining available tools

**Visual Design:**

- **Position**: Left-aligned vertical toolbar
- **Fixed width**: 68pt (44pt button + 12pt padding each side)
- **Styling**: 
  - Background: `DesignSystem.Colors.primary` (#191919)
  - Inactive icons: `DesignSystem.Colors.secondary` (#535353)
  - Active state: `DesignSystem.Colors.tertiary` (#86B8FE) background with primary-colored icon
  - Corner radius: 12pt (toolbar), 8pt (buttons)
  - Shadow for depth
- **Touch targets**: 44pt × 44pt (Apple's recommended minimum)

**Tool Groups:**

1. **Selection Tools** (toggleable with active state):
   - Pointer tool (`arrow.up.left`)
   - Group tool (`rectangle.dashed`)

2. **History Actions** (single-action buttons):
   - Undo (`arrow.uturn.backward`)
   - Redo (`arrow.uturn.forward`)

3. **Content Actions**:
   - Add new item (`plus`)

**Active State Animation:**

Uses SwiftUI's `matchedGeometryEffect` to create smooth transitions between active tools:

```swift
@Namespace private var toolNamespace

// Applied to active tool background
.matchedGeometryEffect(id: "activeButton", in: toolNamespace)
.animation(.smooth(duration: 0.3), value: isActive)
```

**Integration:**

- `ContentView` manages `@State private var activeTool: CanvasTool = .pointer`
- Toolbar binds via `@Binding var activeTool: CanvasTool`
- Callbacks for actions: `onUndo`, `onRedo`, `onAddItem` (currently placeholders)
- Tool state **not yet connected** to canvas behavior (planned for next iteration)

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
- **Not yet connected** to `BoardCanvasView` insertion pipeline
- Callback receives file URLs; caller responsible for processing

**Technical Notes:**
- Accessibility labels and hints included
- File loading helpers (`loadURLs(from:preferredTypes:)`) handle async provider resolution
- `NSItemProvider` extensions for file/data loading

**Code Duplication:**
File loading logic (`loadURLsFromProviders`, `NSItemProvider` extensions) is duplicated between `InsertFileControl.swift` and `BoardCanvasView.swift`. Candidate for extraction to shared utility file (e.g., `FileImportHelpers.swift`).

---

### Pinch Gesture Overlay

**Status: Implemented (Not Integrated)**

**File:** `PinchGestureOverlay.swift`

UIKit-backed gesture recognizer bridge for capturing precise pinch-to-zoom gestures in SwiftUI.

**Purpose:**
SwiftUI's `MagnificationGesture` doesn't provide access to the pinch anchor point (center of two fingers). This component wraps `UIPinchGestureRecognizer` to capture both relative scale and anchor location.

**Architecture:**
- `UIViewRepresentable` that creates a transparent passthrough view
- Installs `UIPinchGestureRecognizer` on the **superview** (not the view itself)
- Passthrough view doesn't intercept touches (`point(inside:with:)` returns `false`)
- Allows SwiftUI gestures to work simultaneously

**API:**
```swift
PinchGestureOverlay(
    onChanged: (_ relativeScale: CGFloat, _ anchorInView: CGPoint) -> Void,
    onBegan: () -> Void,
    onEnded: () -> Void
)
```

**Coordinator Pattern:**
- `Coordinator` acts as gesture delegate
- `shouldRecognizeSimultaneouslyWith` returns `true` for all gestures
- Manages gesture lifecycle and attachment to superview

**Current Status:**
- Component is fully implemented and functional
- **Not yet integrated** into `BoardCanvasView`
- `BoardCanvasView` currently uses `MagnificationGesture()` which zooms around view center
- Integration would enable proper anchor-based zooming (zoom towards fingers/cursor)

**Planned Usage:**
Replace `MagnificationGesture` in `BoardCanvasView` with:
```swift
.overlay(
    PinchGestureOverlay(
        onChanged: { relativeScale, anchorInView in
            // Zoom around anchorInView instead of view center
        },
        onBegan: { /* Store initial state */ },
        onEnded: { /* Clean up */ }
    )
)
