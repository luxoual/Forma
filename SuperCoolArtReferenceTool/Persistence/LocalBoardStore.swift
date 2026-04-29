//
//  LocalBoardStore.swift
//  SuperCoolArtReferenceTool
//
//  Created by andy lin on 2/16/26.
//

import Foundation
import simd

/// Minimal in-memory store to demo the infinite canvas using shared CanvasModels types.
/// This avoids protocol conformance and external persistence for now so you can run it.
actor LocalBoardStore {
    // Index from tile -> element IDs
    private var tileIndex: [CMTileKey: Set<UUID>] = [:]
    // Reverse index from element -> tiles so moves/resizes can update membership precisely.
    private var elementTiles: [UUID: Set<CMTileKey>] = [:]
    // Element headers by ID
    private var elements: [UUID: CMElementHeader] = [:]
    private var fullElements: [UUID: CMCanvasElement] = [:]
    private var minZIndex: Int?
    private var maxZIndex: Int?

    private let cache = TileCache(capacity: 256)

    /// True when content has changed since the last `markClean()`. Set by every mutating
    /// method; read by autosave to skip redundant writes.
    private var isDirty = false

    /// Returns whether the store has changed since the last `markClean()`. Non-consuming —
    /// callers must follow up with `markClean()` only after the save has actually succeeded,
    /// otherwise a cancelled exporter would silently drop the dirty flag and the next autosave
    /// would incorrectly skip writing.
    func peekDirty() async -> Bool { isDirty }

    /// Clears the dirty flag. Call only on confirmed-successful persistence.
    func markClean() async { isDirty = false }

    /// Returns all full elements currently stored, unsafely exposing internal order.
    /// Sorted by zIndex then UUID for stable export ordering.
    func allElements() async -> [CMCanvasElement] {
        let values = Array(fullElements.values)
        return values.sorted { (lhs, rhs) in
            let a = lhs.header
            let b = rhs.header
            if a.zIndex == b.zIndex { return a.id.uuidString < b.id.uuidString }
            return a.zIndex < b.zIndex
        }
    }

    /// Replaces the entire store with the provided elements, rebuilding indices and cache.
    /// Does not mark the store dirty — this is the load path and the in-memory state now matches disk.
    /// In-session "clear all" should go through `delete` instead.
    func replaceAll(with newElements: [CMCanvasElement]) async {
        tileIndex.removeAll()
        elementTiles.removeAll()
        elements.removeAll()
        fullElements.removeAll()
        cache.removeAll()

        for element in newElements {
            apply(element: element)
        }
        recomputeZIndexBounds()
    }

    // MARK: - Public API

    /// Insert or update element headers and update tile index.
    func upsert(headers: [CMElementHeader]) async {
        guard !headers.isEmpty else { return }
        var affectedTiles: Set<CMTileKey> = []
        var needsZIndexRecompute = false

        for header in headers {
            let previousHeader = elements[header.id]
            apply(header: header, affectedTiles: &affectedTiles)
            if let previousHeader, previousHeader.zIndex != header.zIndex {
                needsZIndexRecompute = true
            }
        }

        for key in affectedTiles {
            cache.remove(key)
        }
        if needsZIndexRecompute {
            recomputeZIndexBounds()
        }
        isDirty = true
    }

    /// Insert or update full elements (header + payload) and update tile index.
    func upsert(elements: [CMCanvasElement]) async {
        guard !elements.isEmpty else { return }
        var affectedTiles: Set<CMTileKey> = []
        var needsZIndexRecompute = false

        for element in elements {
            let previousHeader = self.elements[element.id]
            apply(element: element, affectedTiles: &affectedTiles)
            if let previousHeader, previousHeader.zIndex != element.header.zIndex {
                needsZIndexRecompute = true
            }
        }

        for key in affectedTiles {
            cache.remove(key)
        }
        if needsZIndexRecompute {
            recomputeZIndexBounds()
        }
        isDirty = true
    }

    private func produceTileEvents(
        for viewport: CMWorldRect,
        margin: Double,
        continuation: AsyncStream<TileEvent>.Continuation
    ) async {
        let expanded = CMWorldRect(
            origin: SIMD2<Double>(viewport.origin.x - margin, viewport.origin.y - margin),
            size: SIMD2<Double>(viewport.size.x + 2 * margin, viewport.size.y + 2 * margin)
        )
        let keys = CMTileKey.keysIntersecting(rect: expanded)
        for key in keys {
            if let cached = cache.get(key) {
                continuation.yield(.didLoad(key, headers: cached))
            } else {
                continuation.yield(.willLoad(key))
                let headers: [CMElementHeader]
                if let ids = tileIndex[key] {
                    headers = ids.compactMap { elements[$0] }.sorted { $0.zIndex < $1.zIndex }
                } else {
                    headers = []
                }
                cache.put(key, headers: headers)
                continuation.yield(.didLoad(key, headers: headers))
            }
        }
        continuation.finish()
    }

    /// Delete elements and clear any cached tiles.
    func delete(elementIDs: [UUID]) async {
        guard !elementIDs.isEmpty else { return }
        var removedAny = false
        var affectedTiles: Set<CMTileKey> = []

        for id in elementIDs {
            guard elements.removeValue(forKey: id) != nil else { continue }
            removedAny = true
            fullElements.removeValue(forKey: id)
            if let previousTiles = elementTiles.removeValue(forKey: id) {
                affectedTiles.formUnion(previousTiles)
                remove(id: id, from: previousTiles)
            }
        }

        guard removedAny else { return }
        for key in affectedTiles {
            cache.remove(key)
        }
        recomputeZIndexBounds()
        isDirty = true
    }

    /// Query element headers intersecting a region.
    func headers(in rect: CMWorldRect, limit: Int? = nil) async -> [CMElementHeader] {
        let ids = idsIntersecting(rect: rect)
        var result: [CMElementHeader] = []
        result.reserveCapacity(ids.count)
        for id in ids {
            if let header = elements[id], header.bounds.intersects(rect) {
                result.append(header)
            }
            if let limit, result.count >= limit { break }
        }
        return result.sorted { ($0.zIndex, $0.id.uuidString) < ($1.zIndex, $1.id.uuidString) }
    }

    /// Query element headers intersecting the viewport expanded by margin.
    func headers(in viewport: CMWorldRect, margin: Double, limit: Int? = nil) async -> [CMElementHeader] {
        let expanded = CMWorldRect(
            origin: SIMD2<Double>(viewport.origin.x - margin, viewport.origin.y - margin),
            size: SIMD2<Double>(viewport.size.x + 2 * margin, viewport.size.y + 2 * margin)
        )
        return await headers(in: expanded, limit: limit)
    }

    /// Returns image placements intersecting the viewport expanded by margin.
    func imagePlacements(in viewport: CMWorldRect, margin: Double, limit: Int? = nil) async -> [ImagePlacement] {
        let headers = await headers(in: viewport, margin: margin, limit: limit)
        var placements: [ImagePlacement] = []
        placements.reserveCapacity(headers.count)
        for header in headers {
            guard
                let element = fullElements[header.id],
                case .image(let url, _) = element.payload
            else {
                continue
            }
            placements.append(ImagePlacement(id: header.id, url: url, bounds: header.bounds, zIndex: header.zIndex))
        }
        return placements
    }

    /// Returns the topmost header containing a point.
    func topmostHeader(at point: SIMD2<Double>) async -> CMElementHeader? {
        let tileSize = CMTileKey.size
        let key = CMTileKey(
            x: Int(floor(point.x / tileSize)),
            y: Int(floor(point.y / tileSize))
        )
        let ids = tileIndex[key] ?? []
        var best: CMElementHeader? = nil
        for id in ids {
            guard let header = elements[id], header.bounds.contains(point) else { continue }
            if let current = best {
                if header.zIndex > current.zIndex {
                    best = header
                }
            } else {
                best = header
            }
        }
        return best
    }

    /// Moves the provided elements above all others by adjusting zIndex.
    func moveToTop(elementIDs: [UUID]) async {
        guard !elementIDs.isEmpty else { return }
        let ordered = elementIDs.compactMap { elements[$0] }.sorted { $0.zIndex < $1.zIndex }
        guard !ordered.isEmpty else { return }

        let startingZ = (maxZIndex ?? -1) + 1
        var nextZ = startingZ
        for header in ordered {
            var updated = header
            updated.zIndex = nextZ
            nextZ += 1
            elements[updated.id] = updated
            if var full = fullElements[updated.id] {
                full.header = updated
                fullElements[updated.id] = full
            }
        }

        minZIndex = min(minZIndex ?? startingZ, ordered.first?.zIndex ?? startingZ)
        maxZIndex = nextZ - 1
        cache.removeAll()
        isDirty = true
    }

    /// Moves the provided elements below all others by adjusting zIndex.
    func moveToBottom(elementIDs: [UUID]) async {
        guard !elementIDs.isEmpty else { return }
        let ordered = elementIDs.compactMap { elements[$0] }.sorted { $0.zIndex < $1.zIndex }
        guard !ordered.isEmpty else { return }

        let startingZ = (minZIndex ?? 0) - ordered.count
        var nextZ = startingZ
        for header in ordered {
            var updated = header
            updated.zIndex = nextZ
            nextZ += 1
            elements[updated.id] = updated
            if var full = fullElements[updated.id] {
                full.header = updated
                fullElements[updated.id] = full
            }
        }

        minZIndex = startingZ
        maxZIndex = max(maxZIndex ?? (nextZ - 1), ordered.last?.zIndex ?? (nextZ - 1))
        cache.removeAll()
        isDirty = true
    }

    /// Fetch a full element by ID (if present).
    func element(id: UUID) async -> CMCanvasElement? {
        fullElements[id]
    }

    /// Fetch a dictionary of full elements for the given IDs.
    func elements(for ids: [UUID]) async -> [UUID: CMCanvasElement] {
        var result: [UUID: CMCanvasElement] = [:]
        for id in ids {
            if let element = fullElements[id] {
                result[id] = element
            }
        }
        return result
    }

    enum TileEvent {
        case willLoad(CMTileKey)
        case didLoad(CMTileKey, headers: [CMElementHeader])
        case evicted(CMTileKey)
    }

    struct ImagePlacement: Identifiable {
        let id: UUID
        let url: URL
        let bounds: CMWorldRect
        let zIndex: Int
    }

    /// One-shot tile stream for the viewport expanded by margin.
    func tileStream(for viewport: CMWorldRect, margin: Double) -> AsyncStream<TileEvent> {
        AsyncStream { continuation in
            Task {
                await self.produceTileEvents(for: viewport, margin: margin, continuation: continuation)
            }
        }
    }

    private func idsIntersecting(rect: CMWorldRect) -> Set<UUID> {
        let keys = CMTileKey.keysIntersecting(rect: rect)
        var ids: Set<UUID> = []
        for key in keys {
            if let bucket = tileIndex[key] {
                ids.formUnion(bucket)
            }
        }
        return ids
    }

    private func apply(element: CMCanvasElement) {
        fullElements[element.id] = element
        apply(header: element.header)
    }

    private func apply(element: CMCanvasElement, affectedTiles: inout Set<CMTileKey>) {
        fullElements[element.id] = element
        apply(header: element.header, affectedTiles: &affectedTiles)
    }

    private func apply(header: CMElementHeader) {
        let id = header.id
        let oldTiles = elementTiles[id] ?? []
        let newTiles = Set(CMTileKey.keysIntersecting(rect: header.bounds))
        remove(id: id, from: oldTiles.subtracting(newTiles))
        add(id: id, to: newTiles.subtracting(oldTiles))
        elementTiles[id] = newTiles
        elements[id] = header
        updateZIndexBounds(with: header.zIndex)
    }

    private func apply(header: CMElementHeader, affectedTiles: inout Set<CMTileKey>) {
        let id = header.id
        let oldTiles = elementTiles[id] ?? []
        let newTiles = Set(CMTileKey.keysIntersecting(rect: header.bounds))
        affectedTiles.formUnion(oldTiles)
        affectedTiles.formUnion(newTiles)
        remove(id: id, from: oldTiles.subtracting(newTiles))
        add(id: id, to: newTiles.subtracting(oldTiles))
        elementTiles[id] = newTiles
        elements[id] = header
        updateZIndexBounds(with: header.zIndex)
    }

    private func add(id: UUID, to keys: Set<CMTileKey>) {
        for key in keys {
            tileIndex[key, default: []].insert(id)
        }
    }

    private func remove(id: UUID, from keys: Set<CMTileKey>) {
        for key in keys {
            guard var bucket = tileIndex[key] else { continue }
            bucket.remove(id)
            if bucket.isEmpty {
                tileIndex.removeValue(forKey: key)
            } else {
                tileIndex[key] = bucket
            }
        }
    }

    private func updateZIndexBounds(with zIndex: Int) {
        minZIndex = min(minZIndex ?? zIndex, zIndex)
        maxZIndex = max(maxZIndex ?? zIndex, zIndex)
    }

    private func recomputeZIndexBounds() {
        guard let first = elements.values.first else {
            minZIndex = nil
            maxZIndex = nil
            return
        }

        var minValue = first.zIndex
        var maxValue = first.zIndex
        for header in elements.values.dropFirst() {
            minValue = min(minValue, header.zIndex)
            maxValue = max(maxValue, header.zIndex)
        }
        minZIndex = minValue
        maxZIndex = maxValue
    }
}
