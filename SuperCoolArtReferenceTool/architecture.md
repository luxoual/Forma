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
