# Backend Architecture Documentation (Dev B)

⚠️ This document is maintained by **Dev B (Data/Persistence/Infrastructure)**.

The purpose of this file is to document **data models, persistence, storage, and system infrastructure** as they become stable during development.

This file should reflect the **actual implemented system**, not speculative designs.

---

# Current Status

Backend architecture has **core data models and persistence layer** implemented, ready for frontend integration.

---

# Recent Changes (Backend Impact)

- `.refboard` is a **single-file ZIP** export format. The exporter writes a manifest plus copied image assets into one archive.
- Import accepts both the ZIP-based `.refboard` file and the older directory-style package layout for compatibility.
- Board import in the UI is now filtered to `.refboard` only instead of also allowing generic folders and packages.
- App-open delivery now passes imported `CMCanvasElement` values through the root view into the canvas on first launch/open.

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

`BoardArchiver.export(elements:to:)` writes a temp package, zips it, and outputs a flat file. `BoardArchiver.importElements(from:copyAssetsToAppSupport:)` accepts either the new ZIP or a legacy package folder, unpacks if needed, decodes `manifest.json`, and resolves image assets.

When `copyAssetsToAppSupport` is enabled, imported image assets are copied into the app container so the canvas can keep stable file URLs after temporary unzip directories are removed.

The app uses a custom `UTType.refboard` helper. In code it is resolved from the `refboard` filename extension first, then falls back to the exported identifier `AxI.SuperCoolArtReferenceTool.refboard`.

### Import/Open Flow

**Files:**
- `SuperCoolArtReferenceTool/App/SuperCoolArtReferenceToolApp.swift`
- `SuperCoolArtReferenceTool/App/RootView.swift`
- `SuperCoolArtReferenceTool/App/ContentView.swift`
- `SuperCoolArtReferenceTool/Features/BoardCanvas/AppOpenHandler.swift`

`.refboard` files can enter the app through two paths:
- In-app board import via `fileImporter`
- External open via the app-level `.onOpenURL`

Both paths converge on `BoardArchiver.importElements(...)`, which produces `[CMCanvasElement]`. `AppOpenHandler` temporarily stores imported elements for the app-open path, `RootView` promotes that state into `ContentView`, and `ContentView` forwards the elements into `BoardCanvasView` through `loadElements`.

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
