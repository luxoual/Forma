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

Decision Status: **Pending**

Questions to be resolved during development:

- How world coordinates are represented
- Camera model for panning and zooming
- Rendering strategy for canvas items
- Visibility culling strategy
- Performance considerations for large boards

When finalized, document:

- coordinate system model
- camera structure
- rendering flow

---

## Canvas Item Model

Decision Status: **Pending**

Future documentation will include:

- item types
- shared item properties
- transform data
- layer ordering strategy
- extensibility for new item types

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
```

**How it works:**
- All selection tools share the same geometry effect ID (`"activeButton"`)
- When active tool changes, SwiftUI recognizes the shared ID in the same namespace
- Background smoothly **slides** from old position to new position instead of fading
- Animation: `.smooth(duration: 0.3)`

**Integration Pattern:**

The toolbar takes a binding for active tool state and callbacks for actions:

```swift
CanvasToolbar(
    activeTool: $activeTool,
    onUndo: { /* undo logic */ },
    onRedo: { /* redo logic */ },
    onAddItem: { /* add item logic */ }
)
.padding(.leading, 16) // Position from left edge
```

**Responsive Design:**

- Works in both portrait and landscape orientations
- Uses standard SwiftUI layout that adapts automatically
- Safe area aware when integrated with canvas views

**Button Styling:**

Uses `.buttonStyle(.plain)` to:
- Remove default iOS button styling (blue tint, system highlights)
- Ensure custom design system colors are applied exactly as specified
- Maintain full control over visual appearance

**Files:**

- `Features/HUD/CanvasToolbar.swift`

**Future Considerations:**

- Additional tools can be added to `CanvasTool` enum
- Toolbar position could be made configurable
- Auto-hide behavior could be added
- Tool-specific context menus or settings

---

## Media Handling

Decision Status: **Partially Implemented**

### Media Import UI (FilePicker)

**Status: Implemented**

The FilePicker provides the user interface for importing images into the application.

**Components:**

- `FilePickerView`: SwiftUI view presenting the import interface
- `FilePickerViewModel`: `@Observable` class managing import state and operations
- `CanvasImage`: Data model for imported images

**Import Methods:**

1. **Drag and Drop**
   - Uses SwiftUI's `.onDrop(of:)` modifier
   - Accepts items of type `.image`
   - Provides visual feedback through `isTargeted` state
   - Handles multiple concurrent drops asynchronously

2. **File Browser**
   - Uses SwiftUI's `.fileImporter()` modifier
   - Accepts `UTType.image` content types
   - Supports multiple selection
   - Handles security-scoped resources with `startAccessingSecurityScopedResource()`

**UI Design:**

- Empty state with dashed border drop zone
- "Browse" button for file picker access
- Visual feedback on drag targeting (color changes via `DesignSystem.Colors.tertiary`)
- Animations using SwiftUI's `.animation()` modifier

**Image Processing:**

- Converts file URLs to `Data`
- Creates `UIImage` from data
- Wraps in SwiftUI `Image` type
- Stores as `CanvasImage` model with UUID identifier

**Current Limitations:**

- Images stored in view model's array (not yet persisted)
- No thumbnail generation
- No file storage strategy implemented
- Position and scale properties exist but placement not yet implemented

**Files:**

- `FilePickerView.swift`
- `FilePickerViewModel.swift`
- `ModelsCanvasImage.swift` (defines `CanvasImage`)

---

### Pending Media Systems

Areas still to be implemented:

- Long-term file storage strategy
- Thumbnail generation
- Caching strategy
- Media lifecycle management
- Integration with canvas placement

---

## Persistence

Decision Status: **Pending**

Future documentation may include:

- board storage structure
- item serialization
- save/load flow
- migration strategy

---

## Performance Strategy

Decision Status: **Pending**

Areas that may eventually be documented:

- canvas rendering performance
- image memory management
- thumbnail usage
- viewport culling
- large board optimization

---

# Updating This Document

Developers and AI agents should update this file **when an implementation becomes stable**.

Example workflow:

1. Implement a subsystem
2. Validate that it works correctly
3. Confirm the approach will remain in the project
4. Document the design here

---

# Documentation Principles

When writing architecture notes:

- Document **what the system actually does**
- Avoid speculative or future designs
- Prefer **simple explanations**
- Include diagrams or examples if helpful

---

# Relationship to context.md

`context.md` describes:

- product goals
- system concepts
- project structure

`architecture.md` describes:

- **how the system actually works**

Both files should evolve alongside the project.
