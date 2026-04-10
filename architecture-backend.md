# Backend Architecture Documentation (Dev B)

⚠️ This document is maintained by **Dev B (Data/Persistence/Infrastructure)**.

The purpose of this file is to document **data models, persistence, storage, and system infrastructure** as they become stable during development.

This file should reflect the **actual implemented system**, not speculative designs.

---

# Current Status

Backend architecture has **core data models and persistence layer** implemented, ready for frontend integration.

---

# Recent Changes (Backend Impact)

- `.refboard` is now a **single-file ZIP** format (not a package). The exporter zips a manifest + assets folder into one file.
- Import supports both the new ZIP format and the legacy package folder format for compatibility.
- UTI registration updated to `public.data` + `public.zip-archive` and no longer treated as a package.

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

The export pipeline produces a **single-file `.refboard` ZIP** containing:
- `manifest.json`
- `assets/` (copied image files)

`BoardArchiver.export(elements:to:)` writes a temp package, zips it, and outputs a flat file. `BoardArchiver.importElements(from:)` accepts either the new ZIP or a legacy package folder, unpacks if needed, and resolves assets.

The custom UTType identifier is `AxI.SuperCoolArtReferenceTool.refboard`, declared as `public.data` + `public.zip-archive` (not a package).

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

- `ContentView` collects a snapshot of `CMCanvasElement` from `BoardCanvasView` and exports via `BoardArchiver` (macOS uses a save panel to choose the target URL).
- `BoardArchiver` is the single backend entry point for encoding/decoding `.refboard` files (ZIP or legacy package).
- `CanvasService` provides viewport and selection queries (`elements(in:margin:...)`, `topmostElement(at:...)`) for tile-based culling and hit-testing.
- `CanvasService` exposes z-order operations (`moveToTop` / `moveToBottom`) for absolute layer adjustments.
