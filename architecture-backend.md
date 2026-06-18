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
- Multi-image import preparation now runs off the main actor with bounded concurrency for sandbox copying and metadata probing, then applies canvas insertion in chunks so large pastes do not block interaction in one synchronous spike.
- Dense-view rendering now uses a count-aware level-of-detail budget: once visible image density rises, only the highest-priority images stay on the detailed thumbnail path while the rest fall back to the cheap overview canvas pass.
- Visible-image querying now uses a zoom-aware preload margin instead of a constant world-space buffer, and detailed-image membership has hysteresis so pan/zoom motion causes less promotion/demotion churn.
- **Manifest schema bumped to version 2** with an optional board-level `canvasColor: String?` (`#RRGGBB`) field. v1 files decode cleanly with `canvasColor = nil` via `Codable` synthesis (the second time the manifest has gained an optional field — `text.wrapWidth` was the first — establishing the additive-evolution pattern). `BoardArchiver.importElements(...)` now returns an `ImportResult { elements, canvasColorHex }` struct; `BoardArchiver.export(...)` takes a `canvasColorHex: String?` parameter and writes it (or omits it for `nil`). The SwiftUI layer owns the `Color ↔ String` conversion since it needs an env to resolve adaptive colors; the archiver only deals in hex strings. See `architecture-frontend.md` → "Canvas Color Persistence" for the frontend-side plumbing.
- **`BoardArchiver` enum marked `nonisolated`** so its helpers don't inherit the project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` default. `export` was already `nonisolated` at the method level for off-main autosave; tagging the enum makes that uniform across `importElements`, `importFromZip`, `importFromPackage`, and the manifest types nested inside.
- Added persistent frame/grouping support. Frames are serialized as first-class canvas elements, child relationships are stored via `CMElementHeader.parentID`, and import/export round-trips image, text, and frame hierarchy together.
- Frame creation, movement, resizing, parent-frame auto-expansion, and undo/redo now use canvas-element snapshots so persistence stays consistent with the visible asset tree.

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
    case frame
}
```

### Element Payload

**Enum:** `CMCanvasElementPayload`

```swift
case rectangle(fillColor: String)
case ellipse(fillColor: String)
case path(points: [SIMD2<Double>], strokeColor: String, strokeWidth: Double)
case text(content: String, fontName: String, fontSize: Double, color: String, wrapWidth: Double?)
case image(url: URL, size: SIMD2<Double>)
case frame(title: String)
```

`text.wrapWidth` is `nil` for auto-width text (grows horizontally with content) and a world-units width when the text has been wrap-locked via the side resize handle. The decoder uses `decodeIfPresent` and the encoder uses `encodeIfPresent` so older `.refboard` files predating this field load cleanly with `wrapWidth = nil` (auto-width), and freshly-saved auto-width texts omit the key from disk rather than writing `null`. This is the canonical pattern for additive payload-field evolution — image, path, and other payloads should follow the same shape if they grow new optional fields.

The frontend `PlacedText` mirrors this payload 1:1 (see `architecture-frontend.md` → Text Elements). Text content lives **entirely in the manifest** — no asset file is created or referenced — which is why text round-trips through the import/export paths without touching the `assets/` directory inside the ZIP.

### Frame Hierarchy

Frames are persisted as normal `CMCanvasElement` records with `type: .frame`, `payload: .frame(title:)`, and bounds stored in `header.bounds`. The hierarchy is represented by `CMElementHeader.parentID` on any child image, text, or nested frame. This keeps grouping orthogonal to payload data: an image remains an image payload, and its membership in a frame is a header relationship.

Runtime frame state is represented by `PlacedFrame { id, title, worldRect, zIndex, parentFrameID }`, mirroring the manifest data needed for save/load and undo reconstruction. `PlacedImage` and `PlacedText` also carry `parentFrameID` so local canvas mutations can update hierarchy before the store write lands.

Frame creation snapshots the selected children before and after reparenting. Undo removes the inserted frame and restores the children to their previous parent IDs; redo restores the child parent IDs and re-adds the frame. This is handled by `CanvasCommand.createFrame(...)` rather than treating frame creation as a plain insert, because grouping changes existing elements in addition to adding a new one.

Moving a child outside its parent frame does not detach it. Instead, the parent frame bounds expand to contain its children, and the move command records the pre-expansion frame rects so undo can restore both the child position and frame bounds. Resizing a frame uses the same group-resize snapshot path as multi-selection: the frame and all descendants are scaled together, then persisted as updated element bounds.

---
## Export Package (.refboard)

Decision Status: **Implemented**

**Files:**
- `SuperCoolArtReferenceTool/App/BoardExportDocument.swift`
- `SuperCoolArtReferenceTool/App/BoardArchiver.swift`

The export pipeline produces a **single-file `.refboard` ZIP** containing:
- `manifest.json` (currently `version: 2`)
- `assets/` (copied image files)

The manifest carries element data plus board-level state. As of version 2 it includes an optional `canvasColor: String?` (`#RRGGBB`) — the user's saved canvas background, or omitted when no preference has been set. v1 files have no `canvasColor` key; `Codable` synthesis treats the missing key as `nil`, so old boards decode without any per-version branching.

`BoardArchiver.export(elements:canvasColorHex:to:)` mutates the archive in place: when the destination already exists it opens the ZIP in `.update` mode, adds only asset entries whose UUIDs weren't already present, removes entries for deleted elements, and rewrites `manifest.json`. Image entries use `.none` compression (already compressed bytes); `manifest.json` uses `.deflate`. This keeps autosave of a "move/resize/add-one-image" change near-free on boards with hundreds of assets. The `canvasColorHex` parameter passes the SwiftUI layer's resolved hex straight into the manifest — `nil` writes no key. `BoardArchiver.importElements(from:copyAssetsToAppSupport:)` accepts either the new ZIP or a legacy package folder, unpacks if needed, decodes `manifest.json`, and resolves image assets. It returns an `ImportResult { elements: [CMCanvasElement], canvasColorHex: String? }`.

The method is `nonisolated` so autosave can run on a detached `.userInitiated` task for off-main saves (back button); force-quit-safe `.inactive` saves still run on the main actor since they must complete before SIGKILL. Save paths coordinate with `LocalBoardStore.peekDirty()` / `markClean()` — the dirty flag is cleared only after a confirmed-successful write, so a cancelled file exporter doesn't silently drop pending changes. Note that `BoardCanvasView`'s `peekDirty()` only tracks the element store; canvas-color-only changes are gated by a parallel `canvasColorDirty` flag in `ContentView` (see `architecture-frontend.md` → "Canvas Color Persistence").

When `copyAssetsToAppSupport` is enabled, imported image assets are copied into the app container so the canvas can keep stable file URLs after temporary unzip directories are removed.

### Schema evolution

Scope: this section is about the **on-disk `manifest.json` schema** — what gets serialized into the `.refboard` ZIP and read back out. Runtime image caches (see "Thumbnail Loading Pipeline") and tile-index layout (see "Spatial Query Helpers") are separate concerns with their own versioning needs and are not affected by manifest field additions.

The manifest's `version: Int` is bumped when a change is observable, but the on-disk shape evolves via additive optional fields and `Codable` synthesis takes care of the round-trip. So far two fields have followed this pattern:

| Field | Added in | Decoder behavior on older files |
|---|---|---|
| `ManifestPayload.text.wrapWidth: Double?` | text-elements PR | Explicit `decodeIfPresent` / `encodeIfPresent` (custom Codable). Missing key → `nil`. |
| `BoardManifest.canvasColor: String?` | v2 | Synthesized `Codable` on the manifest struct. Missing key → `nil`. |

Custom-coded payloads need the explicit `decodeIfPresent` because their `init(from:)` is written by hand; synthesized structs handle the absent-key case automatically. Either way, the v1 → v2 upgrade requires no migration code.

Adding a new manifest field should follow the same pattern:
1. Declare it `Optional` on the struct.
2. If the struct has custom `Codable`, branch via `decodeIfPresent` / `encodeIfPresent`. If synthesized, just add the property.
3. Bump `version: Int` if downstream consumers might need to switch on it (helps future migration logic dispatch correctly); skip the bump if the change is purely additive and forward-readable.

Adding a *breaking* change (rename, type change, mandatory new field) is what would actually demand a version-dispatched migration path. None today.

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
- `SuperCoolArtReferenceTool/App/AppOpenHandler.swift`

`.refboard` files can enter the app through two paths:
- In-app board import via `fileImporter`
- External open via the app-level `.onOpenURL`

Both paths converge on `BoardArchiver.importElements(...)`, which returns an `ImportResult { elements, canvasColorHex }`. `AppOpenHandler` exposes both pieces of state (`importedElements: [CMCanvasElement]?` and `importedCanvasColorHex: String?`) for the app-open path; `RootView` promotes them into `ContentView` (`initialElements` + `initialCanvasColorHex`); `ContentView` forwards the elements into `BoardCanvasView` through `loadElements` and seeds its own `canvasColor` state from the hex (falling back to `Color(uiColor: .systemBackground)` when nil).

`BoardArchiver.importElements` owns its own security-scoped access internally (`startAccessingSecurityScopedResource` / stop pair). Callers should not nest their own — `FilePickerView.openBoard` previously wrapped its detached-task body in a redundant pair; that wrap has been removed so the archiver remains the single owner of the scope.

---

## Persistence Diagnostics

Decision Status: **Implemented**

**Files:**
- `SuperCoolArtReferenceTool/App/Loggers.swift`
- `SuperCoolArtReferenceTool/App/BoardArchiver.swift`

Diagnostics for the import/export/save surface, designed so production logs are useful for narrowing down user-reported failures without leaking sensitive filenames or error text.

### Logger setup

`Loggers.swift` centralizes Logger / OSSignposter declarations. Subsystem auto-derives from `Bundle.main.bundleIdentifier` so per-dev signing (no shared developer certificate, each dev's Apple ID team produces a different bundle id) doesn't break log filtering. Six categories: `App` (`.onOpenURL`), `Save` (autosave), `RecentBoards` (bookmark I/O), `Archiver` (ZIP open failures + probe), `Importer` (file picker results), `ScenePhase` (lifecycle). Filter via `log stream --predicate 'subsystem == "<bundle-id>" && category == "Save"'` or Console.app's category filter.

### Log privacy policy

`OSLogPrivacy` cannot be extended with custom static values — the OSLog macro performs a compile-time check that only accepts the framework's built-in members. Privacy is therefore baked into wrapper methods on `Logger` (`logSaveSuccess`, `logSaveFailure`, `logURLReceipt`, `logFailure`, `logArchiveOpenFailed`). **Add a new persistence-related log via a wrapper rather than calling `Logger.<category>.info(...)` directly** so the privacy rule stays uniform.

| Field | DEBUG | Release |
|---|---|---|
| Filename (`url.lastPathComponent`) | `.public` | `.private(mask: .hash)` |
| Error description / failure reason | `.public` | `.private(mask: .hash)` |
| Provider class, element count, duration, probe result, signpost metadata | `.public` | `.public` |

The hashed-mask in release lets log lines correlate ("save failed for X" → "save retried for X") without leaking the raw filename.

### File-provider attribution

`fileProviderDescription(for:)` returns the broad storage class — `iCloud Drive`, `FileProvider`, `iCloudContainer`, `AppContainer`, `Simulator`, `Other`. DEBUG builds additionally extend `FileProvider` / `iCloudContainer` with the provider's bundle suffix (`FileProvider:WorkingCopy-XYZ`) so we can attribute provider-specific bugs locally; release builds drop the suffix.

The third-party-attribution split exists because a corruption report on `.refboard` files saved through Working Copy (a Files-extension app) needed provider-level resolution to diagnose, but the raw provider name shouldn't ship to release logs.

### `ArchiverError` (formerly `ImportError`)

`BoardArchiver.ArchiverError: LocalizedError` covers both import and export paths — the boundary type name reflects the archiver boundary, not one direction across it. Cases:

- `unsupportedFileExtension` — wrong file extension (import-only path).
- `corruptedFile(failingEntryPath: String?)` — package layout invalid, manifest missing, or `unzipItem` rejected a ZIP entry path. Associated value carries the bad path when known.
- `ioFailure(underlying: Error?)` — `Archive(url:accessMode:)` returned nil for read or write. Associated value reserved for the underlying error if a future ZIPFoundation surface exposes one.

`errorDescription` is plain-language for user alerts; the developer-facing `failureReason` (bad ZIP entry path / underlying error) is folded into log lines via `failureReasonSuffix(for:)` inside the `Logger.log*Failure` wrappers, so the associated-value detail reaches `log stream` without surfacing in the user's alert text.

Splitting into separate `ImportError` / `ExportError` types is deferred until a third call site appears or import/export diverge in error data (e.g. export needs `diskFull(bytesRequired:)`). Today there's one call site each and type-level discrimination buys nothing the compiler isn't already giving.

### OSSignposter intervals

`OSSignposter.archiver` emits begin/end intervals around `BoardArchiver.export` and `.importElements`. Metadata attached to each interval (`provider: <class>`, plus `elements: <count>` on export) is `.public` so it shows in Instruments under `subsystem == "<bundle-id>"` + `category == "Archiver"`. This is the tool for answering "is provider X slow or wrong?" — measure per-provider duration across real saves.

### ZIP-tail probe

When `Archive(url:accessMode: .read)` returns nil inside `unzipItem`, `probeZipTail` reads the trailing 64KB of the file and reports whether the ZIP End-of-Central-Directory signature (`PK\x05\x06`) is present:

- `ZIP probe: NO EOCD found (size=N) — file likely truncated mid-write` — points at killed-during-save (the suspected Working Copy bug shape).
- `ZIP probe: EOCD found (size=N) — file structurally valid but couldn't open` — points elsewhere (header corruption, permission, ZIPFoundation issue).
- Diagnostic strings prefixed `ZIP probe:` for intermediate stat/open/seek/read failures.

Logged via `Logger.archiver.logArchiveOpenFailed(url:probe:)`.

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

The viewport-expanded query margin is no longer effectively constant at the call site. The canvas now computes a zoom-aware preload margin and passes that into `imagePlacements(...)`, which reduces off-screen overfetch at far zoom-out while preserving enough lookahead for normal pan/zoom motion.

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
- When visible image density rises, the canvas does not keep every visible image on this detailed thumbnail-backed path. The thumbnail pipeline is now the expensive tier of a broader LOD system; lower-priority images are represented by a lightweight overview pass instead of triggering full per-image thumbnail work.

This is not yet a persistent on-disk thumbnail pyramid. Levels are generated lazily in memory from source files, but the pipeline now behaves like a lightweight multilevel thumbnail system during canvas interaction.

---

## Batch Image Placement

Decision Status: **Implemented**

**File:**
- `SuperCoolArtReferenceTool/Features/BoardCanvas/BoardCanvasView.swift`

Canvas image insertion now treats a paste/import of multiple images as a single batch layout operation.

Behavior:
- Source file copying into the app sandbox and image metadata probing now happen off the main actor through a bounded-concurrency preparation pipeline.
- The canvas computes a near-square grid using the number of incoming images.
- Each image keeps its own aspect ratio and is centered within a shared grid cell size derived from the largest image in the batch.
- The batch is initially centered around the requested insertion point.
- If any image in the batch would overlap an existing placed image, the system first searches nearby candidate offsets on coarse and fine grids, then falls back to moving the full batch outside the currently occupied canvas bounds to guarantee a non-overlapping placement.
- After preparation, insertion is applied in chunks with yields between batches so very large paste/import operations do not monopolize the main actor.

This replaces the older one-by-one diagonal nudge behavior, which could still create visually messy overlaps for larger paste operations.

---

## Canvas Render Support Infrastructure

Decision Status: **Implemented**

**Files:**
- `SuperCoolArtReferenceTool/Features/BoardCanvas/BoardCanvasView.swift`
- `SuperCoolArtReferenceTool/Persistence/LocalBoardStore.swift`

The backend-facing canvas support now includes explicit render-budgeting behavior layered on top of tile-based visibility queries.

Behavior:
- Visible image candidates still come from `LocalBoardStore.imagePlacements(in:margin:limit:)`.
- If visible count stays below the dense-view threshold, all visible images can remain on the detailed render path.
- Once visible density rises, the canvas enforces a bounded detailed-image budget and splits rendering into:
  - a detailed tier backed by the thumbnail pipeline
  - a cheap overview tier rendered as lightweight canvas primitives
- Detailed-tier selection is priority-based rather than FIFO:
  - selected images are always retained
  - larger on-screen images are favored
  - images nearer the viewport center are favored
- Detailed-tier membership has hysteresis (`stickyDetailImageIDs`) so images do not constantly churn between tiers on minor pan deltas.

This keeps total expensive image-render work closer to a capped budget instead of allowing it to scale linearly with every additional visible image in dense zoomed-out views.

---

# Integration Points

- `ContentView` collects a snapshot of `CMCanvasElement` from `BoardCanvasView` and exports via `BoardArchiver` (macOS uses a save panel to choose the target URL). Board-level state beyond the element list — currently just the canvas-color hex — also flows through `BoardArchiver.export(elements:canvasColorHex:to:)`.
- `BoardArchiver` is the single backend entry point for encoding/decoding `.refboard` files (ZIP or legacy package). Returns an `ImportResult { elements, canvasColorHex }` on import; takes the parallel pair on export.
- `BoardCanvasView` now performs batch image placement for pasted/imported image URLs before writing the resulting `CMCanvasElement` set into `canvasStore`.
- `CanvasService` provides viewport and selection queries (`elements(in:margin:...)`, `topmostElement(at:...)`) for tile-based culling and hit-testing.
- `CanvasService` exposes z-order operations (`moveToTop` / `moveToBottom`) for absolute layer adjustments.
- `LocalBoardStore` provides the specialized `imagePlacements(in:margin:limit:)` query used by the visible-canvas render path.
- The canvas thumbnail pipeline is currently implemented inside `BoardCanvasView.swift`; it depends on backend file-URL payloads remaining stable after import/export and app-open flows. The v2 manifest's added `canvasColor` field doesn't change that contract — image-asset URLs round-trip the same way they always did, and the new field is orthogonal board-level state.
- The dense-view LOD budget and sticky-detail behavior depend on `LocalBoardStore` continuing to provide cheap viewport image placement queries as pan/zoom inputs change frequently.
