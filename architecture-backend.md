# Backend Architecture (Dev B)

⚠️ This document is maintained by **Dev B (Data/Persistence/Infrastructure)**.

It describes the data, storage, and file code **as actually built** — not plans, not ideas. If something here isn't in the code, it shouldn't be here.

**How this doc is written:** plain language first, precise names second. Every section starts with what the thing does in ordinary words, then gets specific. Exact names (`LocalBoardStore`, `CMElementHeader.parentID`), file paths, and numbers are kept literal so you can search for them. See `context.md` → "How to write documentation" for the full rule.

---

## Words we use a lot

Read this once and the rest of the doc gets easier.

| Word | What it actually means |
|---|---|
| **Element** | One thing on the board: an image, a text note, or a frame. In code, a `CMCanvasElement`. |
| **Header** | The part of an element every type shares: id, position and size (`bounds`), stacking order (`zIndex`), and which frame it belongs to (`parentID`). A `CMElementHeader`. |
| **Payload** | The part that's specific to the type: an image's file, a text note's words and font, a frame's title. A `CMCanvasElementPayload`. |
| **World space** | The endless flat surface items live on. Positions here never change when you pan or zoom. The backend works in `SIMD2<Double>` and `CMWorldRect`. |
| **Tile** | A 1024 × 1024 square of world space. The board is cut into tiles so "what's near here?" can skip everything far away. A `CMTileKey`. |
| **The store** | `LocalBoardStore`, the in-memory record of every element on the open board. It's the source of truth for saving. |
| **Manifest** | `manifest.json`, the file that lists every element and board setting. It's what gets read back when a board opens. |
| **`.refboard`** | A saved board. It's a ZIP file holding the manifest plus copies of every image. |
| **Asset** | An image file stored inside the `.refboard`, under `assets/`. Text and frames have no asset — they live entirely in the manifest. |
| **Dirty** | "Has unsaved changes." The store sets its dirty flag on every edit and only clears it after a save actually succeeds. |
| **Frame** | A labeled box that groups other elements. The children stay what they were (images stay images); they just point at the frame through `parentID`. |
| **Snapshot** | A frozen copy of an element taken before or after an edit, so undo can put it back exactly. A `PlacedElementSnapshot`. |

**Frontend and backend use different number types for the same world.** The canvas (Dev A) uses `CGFloat` / `CGPoint` / `CGRect`. The backend uses `Double` / `SIMD2<Double>` / `CMWorldRect`. Whenever data crosses between them, it gets converted. That conversion lives in `BoardCanvasView` (see "Where frontend and backend meet" at the bottom).

---

## Current status

The data model, the in-memory store, and save/open of `.refboard` files are all built and working. Frames (grouping) are saved and loaded.

---

# What's on a board: the element model

**Status: Implemented**
**File:** `Persistence/CanvasModels.swift`

Every item on a board is described the same way: a header that says *where* it is, and a payload that says *what* it is. Splitting it like this means the store can sort and search elements by position without caring whether they're images, text, or frames.

## Element types

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

`rectangle`, `ellipse`, and `path` exist in the model but the canvas doesn't create them yet. `image`, `text`, and `frame` are the ones in use.

## Payloads

```swift
case rectangle(fillColor: String)
case ellipse(fillColor: String)
case path(points: [SIMD2<Double>], strokeColor: String, strokeWidth: Double)
case text(content: String, fontName: String, fontSize: Double, color: String, wrapWidth: Double?)
case image(url: URL, size: SIMD2<Double>)
case frame(title: String)
```

**Text.** The words, font, and color all live in the manifest. No file is created for text, which is why text never touches the `assets/` folder inside the ZIP. The frontend's `PlacedText` mirrors this payload one-to-one (see `architecture-frontend.md` → Text Elements).

**`text.wrapWidth`** decides how a text note lays out:

- `nil` — auto-width. The text grows sideways as you type.
- a number — the user dragged a side handle to fix the width, in world units. Text wraps inside it.

Older boards were saved before this field existed. To keep them opening, the decoder uses `decodeIfPresent`, so a missing key just means `nil`. The encoder uses `encodeIfPresent`, so an auto-width text writes no key at all instead of writing `null`. **Any payload that grows a new optional field should copy this pattern.**

## Frames: grouping without changing what's inside

**What a frame is:** a labeled box drawn around a set of elements, so they move and resize together.

**How it's stored:** a frame is just another element — `type: .frame`, `payload: .frame(title:)`, with its box in `header.bounds`. Membership is stored on the *child*, not the frame: each child image, text, or nested frame sets `CMElementHeader.parentID` to its frame's id.

This keeps grouping separate from content. An image inside a frame is still an image payload; only its header changed. That's also why grouped items keep showing everywhere images and text show (the canvas, the minimap, the asset outliner) — nothing about them was converted.

On the canvas side, `PlacedFrame { id, title, worldRect, zIndex, parentFrameID }` holds a frame's live state. `PlacedImage` and `PlacedText` also carry `parentFrameID`, so the canvas can update grouping right away instead of waiting for the store write to land.

### Creating a frame, and undoing it

Making a frame does two things at once: it adds a new frame element, *and* it changes the selected elements by pointing their `parentID` at it. A plain "insert" undo would only remove the frame and leave the children pointing at a frame that no longer exists.

So creation records snapshots of the selected children **before** and **after** they were reparented:

- `CanvasCommand.createFrame(frameSnapshot:beforeChildSnapshots:afterChildSnapshots:)` — re-applies the "after" children, then adds the frame.
- `CanvasCommand.dissolveFrame(frameSnapshot:groupedChildSnapshots:ungroupedChildSnapshots:)` — removes the frame, then puts the children back to their "before" parents.

Each is the other's reverse. Undo runs `.dissolveFrame`; redo runs `.createFrame`.

**Where a new frame goes.** If every selected element already has the same parent frame, the new frame's `parentID` is that frame, so grouping inside a frame nests. Otherwise it's top-level (`nil`). An earlier version used the parent's *parent* by mistake, so new frames escaped the frame they were made in. Both are routed through the system `UndoManager` like every other canvas edit (see `architecture-frontend.md` for how undo works).

### Moving things inside a frame

Dragging a child past its frame's edge doesn't pull it out of the frame. Instead the frame **grows** to keep holding it, plus `defaultFramePadding` (40 world units) of margin. If that frame is itself inside another frame, the outer one grows too, all the way up.

That growth has to be undoable, which caused a subtle problem. Undoing the move slides the child back, but sliding back doesn't shrink the frame — frames only ever grow on their own. So `.move` carries an extra field:

```swift
case move(elementIDs: Set<UUID>, delta: CGSize, frameRectsToRestore: [UUID: CGRect]? = nil)
```

- `frameRectsToRestore == nil` → a real move. Grow parent frames as needed, and remember their old sizes.
- non-nil → the undo of a move. First set those frames back to their remembered sizes, then slide everything back *without* growing anything.

**The order matters.** The remembered sizes are captured *after* the move, at the moved position. Resetting a frame's size after sliding back would snap the frame to where it was dragged, away from its contents. Each undo/redo cycle would push it further away. Resetting first, then sliding, keeps the frame and its contents together.

### Resizing a frame

Resizing a frame scales the frame and everything inside it together. It reuses the same group-resize path as a multi-selection, then saves the new bounds of every touched element.

### A frame caveat for older builds

The manifest decoder throws on a payload `type` it doesn't recognize. A board that contains a frame, opened in a build from before frames existed, will fail to open rather than open without the frames. The manifest `version` was not bumped for frames (it's still `3`). Since nothing reads `version` today (see "Changing the manifest safely"), a bump wouldn't have prevented this anyway.

---

# Saving and opening a board: the `.refboard` file

**Status: Implemented**
**Files:**
- `App/BoardExportDocument.swift`
- `App/BoardArchiver.swift`

A saved board is one ZIP file with a `.refboard` extension. `BoardArchiver` is the only code that reads or writes it.

## What's inside

- `manifest.json` — every element, plus board settings. Currently written as `version: 3`.
- `assets/` — a copy of every image on the board.

Besides the element list, the manifest holds two board-level settings. Both are `#RRGGBB` strings, and both are left out entirely when unset:

- `canvasColor` (added in v2) — the board's background color.
- `lastTextColor` (added in v3) — the color new text on this board starts in.

`lastTextColor` belongs to the board, not the app, because a dark board and a light board want different text. Picking a color on one shouldn't change the other.

## Saving

`BoardArchiver.export(elements:canvasColorHex:lastTextColorHex:to:)` writes the file.

**It only rewrites what changed.** If the file already exists, export opens the ZIP in `.update` mode. It adds asset entries only for images whose UUIDs aren't in the archive yet, removes entries for deleted elements, and rewrites `manifest.json`. Moving one image on a board of hundreds re-writes a small JSON file, not hundreds of images.

**Compression:** images are stored with `.none`, because JPEG/PNG bytes are already compressed and squeezing them again just burns time. `manifest.json` uses `.deflate`.

**Where saves run:**

- `BoardArchiver` is marked `nonisolated`. The project defaults everything to the main actor (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`); without the marker, every archiver helper would be forced onto the main thread. With it, the back-button autosave can run on a detached `.userInitiated` task and not freeze the UI.
- The save that runs when the app goes `.inactive` stays on the main actor on purpose. The system may kill the app right after, so that save has to finish before anything else happens.

**The dirty flag.** Save paths ask `LocalBoardStore.peekDirty()` whether there's anything to save, and call `markClean()` only after the write succeeds. "Peek" doesn't clear the flag. That matters because the user can cancel the file exporter: if peeking cleared the flag, a cancelled save would quietly lose the record that changes were pending.

`peekDirty()` only knows about elements. A change to just the canvas color is tracked separately by a `canvasColorDirty` flag in `ContentView` (see `architecture-frontend.md` → "Canvas Color Persistence").

**Colors cross as strings.** The SwiftUI side turns `Color` into a hex string before calling export, because resolving an adaptive color needs a SwiftUI environment. The archiver only ever sees hex strings. `nil` means "write no key."

## Opening

`BoardArchiver.importElements(from:copyAssetsToAppSupport:)` reads a board. It:

1. Accepts either the ZIP `.refboard` or the older folder-style package, for boards saved before the ZIP format.
2. Unzips to a temporary folder if needed.
3. Decodes `manifest.json` and resolves each image's file.
4. Returns an `ImportResult { elements: [CMCanvasElement], canvasColorHex: String?, lastTextColorHex: String? }`.

When `copyAssetsToAppSupport` is on, images are copied into the app's own container. Without that, image URLs would point into the temporary unzip folder, which gets deleted — and every image on the board would break.

`importElements` handles security-scoped access itself (the `startAccessingSecurityScopedResource` / stop pair). Callers must not wrap it in their own pair. `FilePickerView.openBoard` used to, redundantly; that was removed so the archiver is the only owner.

### How an opened board reaches the canvas

**Files:** `App/SuperCoolArtReferenceToolApp.swift`, `App/RootView.swift`, `App/ContentView.swift`, `App/AppOpenHandler.swift`

A board can come in two ways:

- **From inside the app**, through `fileImporter`. The picker only offers `.refboard` files — not generic folders or packages.
- **From outside**, when another app (like Files) opens a `.refboard` and the system calls `.onOpenURL`.

Both end at `BoardArchiver.importElements(...)`. After that:

- **Outside path:** `AppOpenHandler` holds each piece separately (`importedElements`, `importedCanvasColorHex`, `importedLastTextColorHex`). `RootView` passes them into `ContentView` as `initialElements`, `initialCanvasColorHex`, and `initialLastTextColorHex`.
- **In-app path:** `FilePickerView.onBoardSelected: (BoardArchiver.ImportResult, URL) -> Void` passes the whole `ImportResult` along instead of splitting it up. Two `String?` hex values side by side in a closure signature are easy to swap by accident; passing the struct avoids that and lets board settings grow without touching every hop.

`ContentView` then hands the elements to `BoardCanvasView` through `loadElements`. It sets its `canvasColor` from the hex, falling back to `Color(uiColor: .systemBackground)` when there isn't one. It binds `lastTextColorHex` into the canvas so a color pick writes straight into the state that gets saved.

## Changing the manifest safely

This is about the **on-disk `manifest.json` format** only. The thumbnail cache and the tile index are in memory and are unaffected by manifest changes.

So far every new field has been an optional that older files simply don't have. `Codable` treats a missing key as `nil`, so old boards open with no migration code:

| Field | Added in | What an older file decodes to |
|---|---|---|
| `ManifestPayload.text.wrapWidth: Double?` | text-elements PR | `nil`, via explicit `decodeIfPresent` / `encodeIfPresent` (hand-written Codable) |
| `BoardManifest.canvasColor: String?` | v2 | `nil`, via synthesized `Codable` |
| `BoardManifest.lastTextColor: String?` | v3 | `nil`, via synthesized `Codable` |
| `CMElementHeader.parentID: UUID?` | frames | `nil` (not in any frame), via synthesized `Codable` |

Hand-written `init(from:)` needs the explicit `decodeIfPresent`. Synthesized structs handle a missing key on their own.

**`version` is written but never read.** Nothing on import branches on it. So a version bump documents the format; it doesn't protect anything. One side effect: a v3 file opened in a v2 build just ignores the unknown key and loses that one setting. If a reader ever starts checking `version`, revisit this.

**To add a field:**

1. Make it `Optional`.
2. If the struct has hand-written `Codable`, use `decodeIfPresent` / `encodeIfPresent`. If it's synthesized, just add the property.
3. Bump `version` if a future reader might need to tell formats apart. Skip it if the change is purely additive and old readers can ignore it.

A *breaking* change — renaming, changing a type, adding a required field, or adding a new payload `type` (see the frame caveat above) — is what would really need a version check and a migration path. There's no migration path today.

## Keeping the ZIP safe

A malicious or broken ZIP can contain entry names like `../../something` that try to write outside the folder you're unzipping into ("path traversal"). The archiver guards against that:

- On extract, it rejects entry paths that are empty, absolute, contain backslashes, or would land outside the temporary extraction folder once standardized.
- On create, it builds entry names by stripping the verified source-folder prefix — not by find-and-replace on the full path, which could match in the wrong place.
- The temporary extraction folder is deleted with `defer`, so a failed import doesn't leave junk behind.

## The `.refboard` file type

The app defines `UTType.refboard` in code. It looks the type up by the `refboard` extension first, then falls back to the identifier `AxI.SuperCoolArtReferenceTool.refboard`.

It currently conforms to `public.data`, not `public.zip-archive`. That's deliberate for now: the project still uses a generated `Info.plist`, so the custom document type isn't fully registered in the app's metadata. Using `.data` keeps the file picker working until the project moves to a real plist type declaration.

---

# Diagnostics: logs for save and open

**Status: Implemented**
**Files:** `App/Loggers.swift`, `App/BoardArchiver.swift`

When a user reports "my board won't open," these logs are how we narrow it down — without writing their filenames or error text into release logs.

## Logger setup

`Loggers.swift` holds every `Logger` and `OSSignposter`. The subsystem is read from `Bundle.main.bundleIdentifier`. That's on purpose: each dev signs with their own Apple ID team, so each dev's build has a different bundle id, and a hard-coded subsystem would break log filtering for everyone but one person.

Six categories: `App` (`.onOpenURL`), `Save` (autosave), `RecentBoards` (bookmark reading and writing), `Archiver` (ZIP open failures and the tail probe), `Importer` (file picker results), `ScenePhase` (app lifecycle).

Filter with `log stream --predicate 'subsystem == "<bundle-id>" && category == "Save"'`, or Console.app's category filter.

## What's private in logs

You can't define your own `OSLogPrivacy` values — the logging macro checks at compile time and only accepts the built-in ones. So privacy rules are built into wrapper methods on `Logger`: `logSaveSuccess`, `logSaveFailure`, `logURLReceipt`, `logFailure`, `logArchiveOpenFailed`.

**Add new persistence logs through a wrapper, not `Logger.<category>.info(...)` directly**, so the privacy rule stays the same everywhere.

| Field | DEBUG | Release |
|---|---|---|
| Filename (`url.lastPathComponent`) | `.public` | `.private(mask: .hash)` |
| Error description / failure reason | `.public` | `.private(mask: .hash)` |
| Provider class, element count, duration, probe result, signpost metadata | `.public` | `.public` |

The hash mask means release logs can still match "save failed for X" to "save retried for X" without showing what X is.

## Which storage provider was involved

`fileProviderDescription(for:)` reports roughly where the file lives: `iCloud Drive`, `FileProvider`, `iCloudContainer`, `AppContainer`, `Simulator`, or `Other`. DEBUG builds add the provider app's bundle suffix (like `FileProvider:WorkingCopy-XYZ`); release builds leave it off.

This exists because of a real bug report: `.refboard` files saved through Working Copy (an app that adds itself to Files) were getting corrupted. Diagnosing that needed to know *which* provider. Shipping third-party app names in release logs didn't feel right, hence the DEBUG-only suffix.

## `ArchiverError`

`BoardArchiver.ArchiverError: LocalizedError` covers both saving and opening. It was called `ImportError` until export started using it too.

- `unsupportedFileExtension` — wrong extension (opening only).
- `corruptedFile(failingEntryPath: String?)` — the package layout is invalid, the manifest is missing, or unzipping rejected an entry path. Carries the bad path when known.
- `ioFailure(underlying: Error?)` — `Archive(url:accessMode:)` returned nil for reading or writing. The associated value is reserved for when ZIPFoundation exposes an underlying error.

`errorDescription` is the plain-language text shown to the user. The developer detail (`failureReason`: bad entry path, underlying error) goes into log lines through `failureReasonSuffix(for:)` inside the `Logger.log*Failure` wrappers, so it shows up in `log stream` but never in the user's alert.

Separate `ImportError` / `ExportError` types aren't worth it yet. There's one call site each, and the compiler already knows which is which. Split them if a third call site appears, or if the two need different data (e.g. export needing `diskFull(bytesRequired:)`).

## Timing saves and opens

`OSSignposter.archiver` marks the start and end of every `BoardArchiver.export` and `.importElements`. Each interval carries `provider: <class>`, plus `elements: <count>` on export, all `.public`. In Instruments, filter on `subsystem == "<bundle-id>"` and `category == "Archiver"`. This is how to answer "is provider X slow, or broken?"

## Was the file cut off mid-save?

When `Archive(url:accessMode: .read)` returns nil inside `unzipItem`, `probeZipTail` reads the last 64KB of the file and looks for the ZIP end marker (the End-of-Central-Directory signature, `PK\x05\x06`). Every valid ZIP ends with one.

- `ZIP probe: NO EOCD found (size=N) — file likely truncated mid-write` — the file was cut off, most likely the app was killed during a save. This is the suspected shape of the Working Copy bug.
- `ZIP probe: EOCD found (size=N) — file structurally valid but couldn't open` — the file is complete, so look elsewhere (header corruption, permissions, a ZIPFoundation issue).
- Other `ZIP probe:` lines report failures partway through the probe itself (stat, open, seek, read).

Logged through `Logger.archiver.logArchiveOpenFailed(url:probe:)`.

---

# The store: finding what's near you, fast

**Status: Implemented**
**Files:**
- `Persistence/LocalBoardStore.swift`
- `Persistence/CanvasService.swift`
- `Persistence/LocalCanvasService.swift`

`LocalBoardStore` is an `actor` that remembers every element on the open board. Its main job is answering "which elements are in this rectangle?" quickly, so the canvas only builds views for what's on screen.

## How it finds things: tiles

Checking every element on every pan would get slow on big boards. So the store cuts world space into tiles of `CMTileKey.size = 1024` world units and keeps a lookup from each tile to the elements touching it. To find what's in a rectangle, it checks only the tiles that rectangle covers.

The store keeps:

- `tileIndex: [CMTileKey: Set<UUID>]` — tile → elements touching it
- `elementTiles: [UUID: Set<CMTileKey>]` — element → tiles it touches (the reverse)
- `elements: [UUID: CMElementHeader]` / `fullElements: [UUID: CMCanvasElement]` — the headers and the full elements
- `minZIndex` / `maxZIndex` — the current lowest and highest stacking order

**Why the reverse lookup exists:** when an image moves, the store needs to remove it from the tiles it *used* to touch. Without `elementTiles` it couldn't know which ones those were, and stale entries would pile up. With it, move, resize, and delete update exactly the right tiles.

**Why it tracks min/max z:** "bring to front" needs the current highest `zIndex`. Tracking it means the store doesn't have to scan every element to find it.

## The queries

- `imagePlacements(in:margin:limit:)` — the one the canvas calls on every refresh. Returns just what the image renderer needs, in a single pass. It replaced an older two-step "get headers, then look up each payload" approach.
- `headers(in:limit:)` / `headers(in:margin:limit:)` — headers in a rectangle (used by marquee select).
- `elements(in:margin:layers:limit:)` — viewport query widened by a margin (on `CanvasService`).
- `topmostElement(at:layers:)` — the highest element under a point.
- `moveToTop` / `moveToBottom` — absolute z-order changes.
- `allElements()`, `replaceAll(with:)`, `upsert(elements:)`, `delete(elementIDs:)` — bulk read/write, used for save, load, and edits.
- `peekDirty()` / `markClean()` — the dirty flag described under "Saving."

**The preload margin grows with zoom.** The canvas asks for a bit beyond the visible area, so images are ready before they scroll on screen. That margin isn't a fixed world-space number. A fixed margin wastes a lot of loading when zoomed far out (a few screen points cover huge world distances). So the canvas scales the margin with zoom and passes it into `imagePlacements(...)`.

---

# Loading image thumbnails

**Status: Implemented**
**File:** `Features/BoardCanvas/Elements/ImageCache.swift`

Decoding a full-size photo for a 100-point-wide thumbnail wastes memory and time. And panning would trigger thousands of decodes. So images go through a shared pipeline that decodes only the size needed, and reuses what it can.

- **Fixed sizes.** Requested sizes snap to one of: `128`, `256`, `384`, `512`, `768`, `1024`, `1536`, `2048` pixels. Snapping means two nearly equal requests share one decode.
- **Cheaper while moving.** During pan or zoom, requested sizes are capped lower so motion stays smooth. Sharper versions load when you stop.
- **Show something now.** If a different size of the same image is already cached, it's shown immediately while the right size loads.
- **No duplicate work.** Two requests for the same `url + level` at the same time share one in-flight task.
- **Limited parallel decodes.** An async limiter caps how many decodes run at once.
- **Memory-aware cache.** Thumbnails sit in an `NSCache` with both a count limit and a total-cost limit. Cost is the decoded pixel size, so big images count for more.

This is not a thumbnail cache on disk. Every size is made in memory, on demand, from the original file.

---

# Pasting many images at once

**Status: Implemented**
**File:** `Features/BoardCanvas/BoardCanvasView.swift`

Pasting or importing several images lays them out as a tidy grid, as one operation. The old approach nudged each image diagonally from the same point, and big pastes ended up as a messy overlapping pile.

1. **Prepare off the main thread.** Copying files into the app's sandbox and reading each image's size happen off the main actor, a few at a time.
2. **Pick a grid.** The grid is as close to square as the image count allows. Every cell is the size of the largest image. Each image keeps its own aspect ratio and is centered in its cell.
3. **Center it** on the paste point.
4. **Avoid overlap.** If any image would land on an existing image, the whole grid shifts. It tries nearby spots on a coarse grid, then a fine one. If nothing fits, it moves the whole batch past the edge of everything already on the board, which always works.
5. **Insert in chunks.** Elements are added in chunks of 48, pausing between chunks. A 500-image paste doesn't freeze the app in one long stall.

---

# Keeping dense views fast: level of detail

**Status: Implemented**
**Files:** `Features/BoardCanvas/BoardCanvasView.swift`, `Persistence/LocalBoardStore.swift`

Zoomed far out on a big board, hundreds of images can be on screen at once, each only a few points wide. Building a real image view with a real thumbnail for each one would bring the iPad to its knees. So past a certain density, most images are drawn as cheap placeholder rectangles, and only the most important ones get real thumbnails.

- Visible images still come from `LocalBoardStore.imagePlacements(in:margin:limit:)`.
- Below the dense-view threshold, every visible image is drawn in full.
- Above it, there's a capped budget of full images. The rest go to a cheap overview pass, drawn as simple shapes.
- Which images get the full treatment is decided by priority, not arrival order:
  - selected images always do
  - bigger on-screen images come first
  - images nearer the middle of the screen come first
- **No flicker at the boundary.** An image right on the edge of the cutoff could flip between full and placeholder on every tiny pan. `stickyDetailImageIDs` makes images already showing in full a little harder to demote, so they stay put.

The result is that expensive image work stays near a fixed budget, instead of growing with every image you can see.

---

# Where frontend and backend meet

- **Saving.** `ContentView` asks `BoardCanvasView` for a snapshot of `CMCanvasElement`s, then calls `BoardArchiver.export(elements:canvasColorHex:lastTextColorHex:to:)`. Board settings (canvas color, last text color) go through the same call.
- **Opening.** `BoardArchiver` is the only entry point for reading or writing `.refboard` files (ZIP or legacy folder). It returns an `ImportResult { elements, canvasColorHex, lastTextColorHex }`.
- **Number types.** The canvas works in `CGFloat` / `CGRect`, the store in `Double` / `CMWorldRect`. `BoardCanvasView` converts at every crossing (for example `fallbackImageElement(for:)`, `fallbackTextElement(for:)`, `fallbackFrameElement(for:)`, and `applyElements(_:)`).
- **Frames.** The canvas mirrors `CMElementHeader.parentID` as `parentFrameID` on `PlacedImage`, `PlacedText`, and `PlacedFrame`. Frame create, move, resize, auto-grow, and undo all write full element snapshots back to the store, so what gets saved always matches the tree the user sees.
- **Pasting.** `BoardCanvasView` lays out a batch of pasted or imported images before writing the resulting `CMCanvasElement`s into `canvasStore`.
- **Queries.** `CanvasService` offers viewport and point queries (`elements(in:margin:...)`, `topmostElement(at:...)`) and z-order changes (`moveToTop` / `moveToBottom`). `LocalBoardStore.imagePlacements(in:margin:limit:)` is the specialized query the visible-canvas render uses.
- **Stable image URLs.** The thumbnail pipeline assumes an image's file URL keeps working after open, save, and app-open. That's what `copyAssetsToAppSupport` guarantees. Board settings like `canvasColor` don't affect this — image URLs round-trip the same way regardless.
- **Fast viewport queries.** The level-of-detail budget and sticky detail both re-query on every pan and zoom step, so `imagePlacements(...)` needs to stay cheap.
