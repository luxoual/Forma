# Backend Architecture Documentation (Dev B)

⚠️ This document is maintained by **Dev B (Data/Persistence/Infrastructure)**.

The purpose of this file is to document **data models, persistence, storage, and system infrastructure** as they become stable during development.

This file should reflect the **actual implemented system**, not speculative designs.

---

# Current Status

Backend architecture has **core data models and persistence layer** implemented, ready for frontend integration.

---

# System Areas

## Canvas Item Model

Decision Status: **Implemented**

**File:** `CanvasModels.swift`

Complete data model system for canvas elements with support for multiple item types, transformations, and spatial indexing.

### Element Types

**Enum:** `CMElementType`

```swift
enum CMElementType: String, Codable, Hashable {
    case rectangle
    case ellipse
    case path
    case text
    case image
}
```

---
## Export Package (.refboard)

Decision Status: **Implemented**

**Files:**
- `SuperCoolArtReferenceTool/App/BoardExportDocument.swift`
- `SuperCoolArtReferenceTool/App/BoardArchiver.swift`

The export pipeline uses a SwiftUI `FileDocument` implementation to generate a `.refboard` package on demand. `BoardExportDocument` creates a uniquely named temp package, calls `BoardArchiver.export(elements:to:)` to write assets and `manifest.json`, then returns a `FileWrapper` for the package. This avoids filename collisions in `/tmp` and allows the system file exporter UI to present correctly.

The custom UTType is defined as `.refboard` (exported identifier) to match the exported package type.

---

## Spatial Query Helpers

Decision Status: **Implemented**

**Files:**
- `SuperCoolArtReferenceTool/Persistence/CanvasService.swift`
- `SuperCoolArtReferenceTool/Persistence/LocalCanvasService.swift`
- `SuperCoolArtReferenceTool/Persistence/LocalBoardStore.swift`

Added viewport and selection helpers to support tile-based culling and hit-testing:
- `elements(in:margin:layers:limit:)` for viewport-expanded queries.
- `topmostElement(at:layers:)` for point hit testing.
- `moveToTop` / `moveToBottom` for absolute z-order operations.

---

# Integration Points

- `ContentView` collects a snapshot of `CMCanvasElement` from `BoardCanvasView` and passes it into `BoardExportDocument` for export.
- `BoardArchiver` is the single backend entry point for encoding/decoding `.refboard` packages.
- `CanvasService` provides viewport and selection queries (`elements(in:margin:...)`, `topmostElement(at:...)`) for tile-based culling and hit-testing.
- `CanvasService` exposes z-order operations (`moveToTop` / `moveToBottom`) for absolute layer adjustments.


