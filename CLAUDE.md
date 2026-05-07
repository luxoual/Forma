# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

iPad-only art reference board app built with Swift/SwiftUI. Users organize images, GIFs, videos, and text notes on an infinite canvas. Offline-first, no external dependencies — only native Apple frameworks.

**Bundle ID:** `AxI.SuperCoolArtReferenceTool1`
**Deployment Target:** iPadOS 26.1

## Build & Run

```bash
# Build for simulator
xcodebuild -project SuperCoolArtReferenceTool.xcodeproj \
  -scheme SuperCoolArtReferenceTool \
  -destination 'platform=iOS Simulator,name=iPad Air' \
  -configuration Debug build

# Or open in Xcode
open SuperCoolArtReferenceTool.xcodeproj
```

SwiftPM is used for one dependency (`ZIPFoundation`, added via Xcode's Package Dependencies). No CocoaPods or Carthage. No test targets currently exist.

## Architecture

### Dev Role System

Development is split between two roles. **Ask the user which role before starting work.**

- **Dev A (Frontend/Canvas):** Canvas rendering, gestures, SwiftUI views, UI components. Works in `Features/`, `DesignSystem/`, `UIComponents/`. Updates `architecture-frontend.md`.
- **Dev B (Data/Persistence):** Data models, storage, persistence, services. Works in `Models/`, `Persistence/`, `Services/`. Updates `architecture-backend.md`.

Avoid modifying the other role's systems unless explicitly instructed. Documentation is split to prevent merge conflicts.

### Key Data Flow

```
SuperCoolArtReferenceToolApp → RootView → FilePickerView (landing) → ContentView → BoardCanvasView
                                                                         ↕
                                                                   LocalBoardStore (actor, tile-indexed spatial store)
```

### Core Files

| File | Role |
|------|------|
| `Features/BoardCanvas/BoardCanvasView.swift` | Infinite canvas: pan/zoom gestures, image rendering, viewport culling |
| `Persistence/CanvasModels.swift` | Core types: `CMCanvasElement`, `CMWorldRect`, `CMTileKey`, `CMElementHeader` |
| `Persistence/LocalBoardStore.swift` | In-memory tile-indexed store (actor), spatial queries, z-order management |
| `Persistence/LocalCanvasService.swift` | Service layer wrapping LocalBoardStore |
| `App/BoardArchiver.swift` | Import/export `.refboard` packages (JSON manifest + assets/) |
| `App/ContentView.swift` | Main canvas container, toolbar layout, export/import UI |
| `Features/HUD/CanvasToolbar.swift` | Left/right toolbar with tool selection, undo/redo |
| `Features/FilePicker/FilePickerView.swift` | Landing screen with drag-and-drop/browse for initial file import |
| `DesignSystem/Colors.swift` | Color palette: primary (#191919), secondary (#535353), tertiary (#86B8FE), text (#FFFFFF) |

### Coordinate Systems

- **Frontend (Dev A):** `CGFloat`, `CGPoint`, `CGRect` — screen-to-world: `(screenPoint - offset) / scale`
- **Backend (Dev B):** `SIMD2<Double>`, `CMWorldRect` — tile-based spatial indexing (`CMTileKey`, tile size 1024)
- Integration requires conversion between these two systems.

### Canvas Constants

- Zoom range: 0.05x – 8.0x
- Grid spacing: 128 world units
- Tile cache capacity: 256 tiles
- Image size range: 64 – 512 world units
- Gesture minimum distance: 8pt

## Documentation

Three docs describe the system — read them before major changes:

- `context.md` — Product goals, dev roles, MVP scope (shared, high-level)
- `architecture-frontend.md` — Canvas, gestures, UI implementation (Dev A owns)
- `architecture-backend.md` — Data models, persistence, export format (Dev B owns)

Document only finalized implementations, not speculative architecture.

## Known Issues

- File loading logic duplicated between `BoardCanvasView.swift` and `InsertFileControl.swift`.
- Pointer and group tools in toolbar are not yet connected to canvas behavior.
