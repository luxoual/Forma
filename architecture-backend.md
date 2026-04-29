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
- ZIP import/export paths were hardened to avoid path traversal and unstable relative-path generation during archive extraction and creation.
- Temporary unzip directories are now cleaned up even when archive extraction fails early.
- Multi-image paste/import placement now arranges images as a square-style batch instead of nudging each image diagonally from the same center point.
- Batch image insertion shifts the entire grid until it finds a non-overlapping region on the canvas.
- Board import in the UI is now filtered to `.refboard` only instead of also allowing generic folders and packages.
- App-open delivery now passes imported `CMCanvasElement` values through the root view into the canvas on first launch/open.
- `LocalBoardStore` now maintains reverse tile membership per element so move/resize/delete operations can update the spatial index precisely instead of leaving stale tile memberships behind.
- Visible-image refresh now uses a direct `imagePlacements(...)` query from the store instead of doing a headers query followed by a second payload lookup pass in the canvas.
- Canvas image loading now uses a shared multilevel thumbnail pipeline with snapped thumbnail levels, request deduplication, bounded decode concurrency, and memory-cost-aware caching to reduce pan/zoom decode churn.

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

`BoardArchiver.export(elements:to:)` mutates the archive in place: when the destination already exists it opens the ZIP in `.update` mode, adds only asset entries whose UUIDs weren't already present, removes entries for deleted elements, and rewrites `manifest.json`. Image entries use `.none` compression (already compressed bytes); `manifest.json` uses `.deflate`. This keeps autosave of a "move/resize/add-one-image" change near-free on boards with hundreds of assets. `BoardArchiver.importElements(from:copyAssetsToAppSupport:)` accepts either the new ZIP or a legacy package folder, unpacks if needed, decodes `manifest.json`, and resolves image assets.

The method is `nonisolated` so autosave can run on a detached `.userInitiated` task for off-main saves (back button); force-quit-safe `.inactive` saves still run on the main actor since they must complete before SIGKILL. Save paths coordinate with `LocalBoardStore.peekDirty()` / `markClean()` — the dirty flag is cleared only after a confirmed-successful write, so a cancelled file exporter doesn't silently drop pending changes.

When `copyAssetsToAppSupport` is enabled, imported image assets are copied into the app container so the canvas can keep stable file URLs after temporary unzip directories are removed.

### Archive Safety

The archive layer now includes explicit path-safety checks:
- ZIP entry extraction rejects empty paths, absolute paths, backslash-based paths, and any standardized destination that escapes the intended temp extraction root.
- ZIP creation derives entry names by stripping only the verified source-root prefix, rather than doing a global string replacement on absolute paths.
- Temporary extraction directories are deleted via `defer` so failed imports do not leak temp folders.

The app uses a custom `UTType.refboard` helper. In code it is resolved from the `refboard` filename extension first, then falls back to the exported identifier `AxI.SuperCoolArtReferenceTool.refboard`.

At the moment, `UTType.refboard` still conforms to `public.data` in code rather than `public.zip-archive`. This is a compatibility choice: the project is still building with a generated `Info.plist`, so the custom `.refboard` document type is not fully registered through app metadata yet. Using `.data` preserves current file-picker behavior until the project switches to a real plist-based type declaration.

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

`LocalBoardStore` now acts as the backing spatial index for canvas rendering. It stores:
- `tileIndex`: tile key -> element IDs
- `elementTiles`: element ID -> tile keys
- `elements` / `fullElements`: header and payload storage

That reverse index allows incremental tile maintenance when an image moves or resizes. The store also tracks `minZIndex` / `maxZIndex` so z-order promotions no longer need to scan the full board just to compute the next topmost or bottommost index.

The canvas render path now uses `imagePlacements(in:margin:limit:)` as a specialized query for visible image items. That keeps viewport refresh to a single backend pass that returns only the data needed by the image renderer.

---

## Thumbnail Loading Pipeline

Decision Status: **Implemented**

**File:**
- `SuperCoolArtReferenceTool/Features/BoardCanvas/BoardCanvasView.swift`

Image presentation now uses a shared thumbnail-loading pipeline instead of per-view ad hoc thumbnail decoding.

Behavior:
- Requested screen sizes are snapped to discrete thumbnail levels (`128`, `256`, `384`, `512`, `768`, `1024`, `1536`, `2048`).
- During interaction, requested levels are capped lower so panning and zooming favor cheaper decodes.
- The pipeline reuses the nearest cached thumbnail level immediately when possible.
- Duplicate requests for the same `url + level` are deduplicated through an in-flight task map.
- Thumbnail decode concurrency is bounded by an async limiter.
- Cached thumbnails are stored in an `NSCache` with both count and total-cost limits, and cache cost is based on decoded pixel size.

This is not yet a persistent on-disk thumbnail pyramid. Levels are generated lazily in memory from source files, but the pipeline now behaves like a lightweight multilevel thumbnail system during canvas interaction.

---

## Batch Image Placement

Decision Status: **Implemented**

**File:**
- `SuperCoolArtReferenceTool/Features/BoardCanvas/BoardCanvasView.swift`

Canvas image insertion now treats a paste/import of multiple images as a single batch layout operation.

Behavior:
- The canvas computes a near-square grid using the number of incoming images.
- Each image keeps its own aspect ratio and is centered within a shared grid cell size derived from the largest image in the batch.
- The batch is initially centered around the requested insertion point.
- If any image in the batch would overlap an existing placed image, the system first searches nearby candidate offsets on coarse and fine grids, then falls back to moving the full batch outside the currently occupied canvas bounds to guarantee a non-overlapping placement.

This replaces the older one-by-one diagonal nudge behavior, which could still create visually messy overlaps for larger paste operations.

---

# Integration Points

- `ContentView` collects a snapshot of `CMCanvasElement` from `BoardCanvasView` and exports via `BoardArchiver` (macOS uses a save panel to choose the target URL).
- `BoardArchiver` is the single backend entry point for encoding/decoding `.refboard` files (ZIP or legacy package).
- `BoardCanvasView` now performs batch image placement for pasted/imported image URLs before writing the resulting `CMCanvasElement` set into `canvasStore`.
- `CanvasService` provides viewport and selection queries (`elements(in:margin:...)`, `topmostElement(at:...)`) for tile-based culling and hit-testing.
- `CanvasService` exposes z-order operations (`moveToTop` / `moveToBottom`) for absolute layer adjustments.
- `LocalBoardStore` provides the specialized `imagePlacements(in:margin:limit:)` query used by the visible-canvas render path.
- The canvas thumbnail pipeline is currently implemented inside `BoardCanvasView.swift`; it depends on backend file-URL payloads remaining stable after import/export and app-open flows.
