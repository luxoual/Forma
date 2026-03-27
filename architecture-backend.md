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

The custom UTType is defined as `.refboard` (by filename extension) to match the exported package type.

---

# Integration Points

- `ContentView` collects a snapshot of `CMCanvasElement` from `BoardCanvasView` and passes it into `BoardExportDocument` for export.
- `BoardArchiver` is the single backend entry point for encoding/decoding `.refboard` packages.


