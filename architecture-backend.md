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

Defines the types of visual elements that can exist on the canvas.

---

### Core Data Structures

#### **CMCanvasElement**

Complete canvas item with header (metadata) and payload (type-specific data).

```swift
struct CMCanvasElement: Codable, Hashable, Identifiable {
    var id: UUID { header.id }
    var header: CMElementHeader
    var payload: CMCanvasElementPayload
}
```

---

#### **CMElementHeader**

Common metadata shared by all element types:

```swift
struct CMElementHeader: Codable, Hashable, Identifiable {
    var id: UUID
    var type: CMElementType
    var transform: CMAffineTransform2D
    var bounds: CMWorldRect
    var layerId: CMLayerID  // typealias UUID
    var zIndex: Int
}
```

**Fields:**
- `id` - Unique identifier for the element
- `type` - Discriminator for payload interpretation
- `transform` - 3x3 affine transformation matrix
- `bounds` - Bounding box in world coordinates
- `layerId` - Layer organization (UUID)
- `zIndex` - Rendering order within layer

---

#### **CMCanvasElementPayload**

Enum with associated values for type-specific data:

```swift
enum CMCanvasElementPayload: Codable, Hashable {
    case rectangle(fillColor: String)
    case ellipse(fillColor: String)
    case path(points: [SIMD2<Double>], strokeColor: String, strokeWidth: Double)
    case text(content: String, fontName: String, fontSize: Double, color: String)
    case image(url: URL, size: SIMD2<Double>)
}
```

**Custom Codable Implementation:**
- Uses private `CodingKeys` enum
- Encodes type discriminator + associated values
- Supports safe decoding with type validation

---

### Coordinate System

#### **CMWorldRect**

Represents rectangular areas in world space using `SIMD2<Double>`.

```swift
struct CMWorldRect: Codable, Hashable {
    var origin: SIMD2<Double>  // Top-left corner
    var size: SIMD2<Double>    // Width and height
}
```

**Methods:**
- `intersects(_:)` - Rectangle intersection test
- `union(_:)` - Returns bounding rect of two rectangles

**Purpose:**
- Spatial queries
- Collision detection
- Bounding box calculations

---

#### **CMAffineTransform2D**

3x3 transformation matrix using `simd_double3x3`.

```swift
struct CMAffineTransform2D: Codable, Hashable {
    var matrix: simd_double3x3
}
```

**Supports:**
- Translation
- Rotation
- Scale
- Skew

**Custom Codable Implementation:**
- Serializes as flat array of 9 doubles
- Ensures stable encoding for persistence

**Custom Hashable Implementation:**
- Hashes all 9 matrix components
- Enables use in dictionaries/sets

---

### Tile System (Spatial Indexing)

#### **CMTileKey**

Identifies tiles in a uniform grid for spatial partitioning.

```swift
struct CMTileKey: Codable, Hashable {
    static let size: Double = 1024  // Tile size in world units
    var x: Int
    var y: Int
}
```

**Methods:**

```swift
static func keysIntersecting(rect: CMWorldRect) -> [CMTileKey]
```

Returns all tile keys overlapping a world rect.

**Purpose:**
- Divides world space into 1024×1024 unit tiles
- Enables O(1) lookup of items in a spatial region
- Supports efficient spatial queries for large canvases

**Algorithm:**
```swift
let minX = Int(floor(rect.origin.x / tileSize))
let minY = Int(floor(rect.origin.y / tileSize))
let maxX = Int(floor((rect.origin.x + rect.size.x - epsilon) / tileSize))
let maxY = Int(floor((rect.origin.y + rect.size.y - epsilon) / tileSize))
// Return all keys in range
```

---

## Persistence Layer

Decision Status: **Implemented**

### LocalBoardStore

**File:** `LocalBoardStore.swift`

In-memory storage for canvas elements with tile-based spatial indexing.

**Responsibilities:**
- Store and retrieve canvas elements
- Maintain spatial index via tile system
- Provide tile-based streaming for viewport queries
- Support upsert and delete operations

**Key Methods:**

```swift
func upsert(elements: [CMCanvasElement]) async
func delete(elementIDs: [UUID]) async
func element(id: UUID) async -> CMCanvasElement?
func headers(in rect: CMWorldRect, limit: Int?) async -> [CMElementHeader]
func tileStream(for viewport: CMWorldRect, margin: Double) -> AsyncStream<TileEvent>
```

**Tile Streaming:**
- Monitors viewport changes
- Loads tiles that enter view
- Evicts tiles that exit view + margin
- Uses `AsyncStream` for reactive updates

---

### LocalCanvasService

**File:** `LocalCanvasService.swift`

Service layer wrapping `LocalBoardStore` with change notification.

**Purpose:**
- Implements `CanvasService` protocol (if defined)
- Provides async/await API
- Broadcasts changes via `AsyncStream`

**Key Methods:**

```swift
func upsert(elements: [CMCanvasElement]) async throws
func delete(elementIDs: [UUID]) async throws
func elements(in rect: CMWorldRect, layers: [UUID]?, limit: Int?) async throws -> [CMElementHeader]
func elementDetail(id: UUID) async throws -> CMCanvasElement?
func tileStream(for viewport: CMWorldRect, margin: Double) -> AsyncStream<TileEvent>
```

**Change Stream:**

```swift
var changes: AsyncStream<CanvasServiceChange>

enum CanvasServiceChange {
    case elementsUpserted([UUID])
    case elementsDeleted([UUID])
}
```

---

### CanvasService Protocol

**File:** `CanvasService.swift`

Protocol defining the interface for canvas persistence operations.

**Purpose:**
- Abstraction layer for persistence
- Allows swapping implementations (local, remote, etc.)
- Defines contract for canvas data operations

---

## Storage Infrastructure

Decision Status: **Implemented**

### PersistenceDriver

**File:** `PersistenceDriver.swift`

Abstract interface for underlying storage mechanisms.

**Implementations:**
- SQLite-based storage
- In-memory storage (for testing)
- Future: Remote sync, file-based, etc.

---

### SQLiteLayer

**File:** `SQLiteLayer.swift`

SQLite implementation of persistence layer.

**Responsibilities:**
- Database schema management
- SQL query execution
- Transaction handling
- Element serialization/deserialization

**Schema:**
- Elements table with JSON payload storage
- Tile index table for spatial queries
- Layer organization tables

---

## Data Model Integration Status

### Current State

**Dev B (Backend):**
- ✅ Complete data models defined (`CMCanvasElement`, `CMElementHeader`, `CMCanvasElementPayload`)
- ✅ Coordinate system with `SIMD2<Double>` and `CMWorldRect`
- ✅ Tile-based spatial indexing (`CMTileKey`)
- ✅ Persistence layer (`LocalBoardStore`, `LocalCanvasService`)
- ✅ Storage infrastructure (`PersistenceDriver`, `SQLiteLayer`)

**Dev A (Frontend):**
- Uses simplified `PlacedImage` struct
- Coordinates in `CGFloat` (`CGPoint`/`CGRect`)
- No tile system usage
- Items stored in `@State` (ephemeral, no persistence)

---

### Integration Requirements

**Coordinate Conversion:**

Need bidirectional helpers:

```swift
// CGFloat/CGPoint → SIMD2<Double>
func toSIMD2(_ point: CGPoint) -> SIMD2<Double> {
    SIMD2<Double>(Double(point.x), Double(point.y))
}

// SIMD2<Double> → CGPoint
func toCGPoint(_ simd: SIMD2<Double>) -> CGPoint {
    CGPoint(x: CGFloat(simd.x), y: CGFloat(simd.y))
}

// CGRect → CMWorldRect
// CMWorldRect → CGRect
```

**Model Migration:**

Frontend needs to:
1. Replace `PlacedImage` with `CMCanvasElement`
2. Use `CMElementHeader` for positioning
3. Store image URL in `CMCanvasElementPayload.image`
4. Update transform from simple rect to `CMAffineTransform2D`

**Persistence Integration:**

Frontend should:
1. Inject `LocalCanvasService` into `BoardCanvasView`
2. Call `service.upsert()` when items added/moved
3. Call `service.delete()` when items removed
4. Use `service.tileStream()` for efficient loading
5. Subscribe to `service.changes` for external updates

---

## Future Backend Work

### Planned Enhancements

1. **Real Persistence:**
   - Wire `LocalCanvasService` to actual SQLite database
   - Implement migrations for schema changes
   - Add data validation and constraints

2. **Optimization:**
   - Index tuning for spatial queries
   - Batch operations for bulk updates
   - Lazy loading for large payloads (e.g., image data)

3. **Board Management:**
   - Board metadata storage (name, created date, etc.)
   - Multi-board support
   - Board import/export

4. **Sync Infrastructure:**
   - Conflict resolution strategy
   - Remote sync protocol
   - Offline queue for changes

5. **Media Management:**
   - Centralized media asset storage
   - Deduplication of identical images
   - Thumbnail generation
   - Media garbage collection

6. **Undo/Redo:**
   - Command pattern for operations
   - History stack persistence
   - Memory-efficient undo state

---

## Dev A / Dev B Integration Points

**Where Backend (Dev B) interfaces with Frontend (Dev A):**

1. **Data Models:**
   - Backend provides `CMCanvasElement` as source of truth
   - Frontend needs conversion helpers to/from SwiftUI types

2. **Persistence Service:**
   - Backend provides `LocalCanvasService` API
   - Frontend calls service methods on user actions
   - Frontend subscribes to change stream for updates

3. **Spatial Indexing:**
   - Backend provides `CMTileKey` system
   - Frontend can use for viewport culling (not yet implemented)

4. **Coordinate Systems:**
   - Backend uses `SIMD2<Double>` for precision
   - Frontend uses `CGFloat` for UIKit/SwiftUI
   - Need conversion layer

---

## Notes

- Models are production-ready and stable
- Persistence layer is functional but not yet wired to frontend
- Tile system enables future performance optimizations
- Clean separation allows backend evolution independent of UI
