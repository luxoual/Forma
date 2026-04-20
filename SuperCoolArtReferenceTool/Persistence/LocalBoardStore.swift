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
    // Element headers by ID
    private var elements: [UUID: CMElementHeader] = [:]
    private var fullElements: [UUID: CMCanvasElement] = [:]

    private let cache = TileCache(capacity: 256)

    /// True when content has changed since the last `consumeDirty()`. Set by every mutating
    /// method; read by autosave to skip redundant writes.
    private var isDirty = false

    /// Atomically returns whether the store is dirty and clears the flag.
    func consumeDirty() async -> Bool {
        let was = isDirty
        isDirty = false
        return was
    }

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
        // Clear existing
        tileIndex.removeAll()
        elements.removeAll()
        fullElements.removeAll()
        cache.removeAll()
        // Insert provided elements and rebuild tile index
        for el in newElements {
            let header = el.header
            elements[header.id] = header
            fullElements[header.id] = el
            for key in CMTileKey.keysIntersecting(rect: header.bounds) {
                tileIndex[key, default: []].insert(header.id)
            }
        }
    }

    // MARK: - Public API

    /// Insert or update element headers and update tile index.
    func upsert(headers: [CMElementHeader]) async {
        guard !headers.isEmpty else { return }
        var affected: Set<CMTileKey> = []
        for header in headers {
            elements[header.id] = header
            for key in CMTileKey.keysIntersecting(rect: header.bounds) {
                tileIndex[key, default: []].insert(header.id)
                affected.insert(key)
            }
        }
        for key in affected { cache.remove(key) }
        isDirty = true
    }

    /// Insert or update full elements (header + payload) and update tile index.
    func upsert(elements: [CMCanvasElement]) async {
        guard !elements.isEmpty else { return }
        var affected: Set<CMTileKey> = []
        for element in elements {
            let header = element.header
            self.elements[header.id] = header
            self.fullElements[header.id] = element
            for key in CMTileKey.keysIntersecting(rect: header.bounds) {
                tileIndex[key, default: []].insert(header.id)
                affected.insert(key)
            }
        }
        for key in affected { cache.remove(key) }
        isDirty = true
    }

    private func produceTileEvents(
        for viewport: CMWorldRect,
        margin: Double,
        continuation: AsyncStream<TileEvent>.Continuation
    ) async {
        let expanded = CMWorldRect(
            origin: SIMD2<Double>(viewport.origin.x - margin, viewport.origin.y - margin),
            size: SIMD2<Double>(viewport.size.x + 2*margin, viewport.size.y + 2*margin)
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
    
    /// Delete elements and clear any cached tiles (naive for demo).
    func delete(elementIDs: [UUID]) async {
        guard !elementIDs.isEmpty else { return }
        var removedAny = false
        for id in elementIDs {
            if elements.removeValue(forKey: id) != nil { removedAny = true }
            fullElements.removeValue(forKey: id)
        }
        guard removedAny else { return }
        // Rebuild tile index naively
        tileIndex.removeAll()
        for header in elements.values {
            for key in CMTileKey.keysIntersecting(rect: header.bounds) {
                tileIndex[key, default: []].insert(header.id)
            }
        }
        cache.removeAll()
        isDirty = true
    }

    /// Query element headers intersecting a region.
    func headers(in rect: CMWorldRect, limit: Int? = nil) async -> [CMElementHeader] {
        let keys = CMTileKey.keysIntersecting(rect: rect)
        var ids: Set<UUID> = []
        for key in keys { if let bucket = tileIndex[key] { ids.formUnion(bucket) } }
        var result: [CMElementHeader] = []
        result.reserveCapacity(ids.count)
        for id in ids {
            if let h = elements[id], h.bounds.intersects(rect) { result.append(h) }
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
        let maxZ = elements.values.map { $0.zIndex }.max() ?? 0
        var nextZ = maxZ + 1
        let ordered = elementIDs.compactMap { elements[$0] }.sorted { $0.zIndex < $1.zIndex }
        guard !ordered.isEmpty else { return }
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
        cache.removeAll()
        isDirty = true
    }

    /// Moves the provided elements below all others by adjusting zIndex.
    func moveToBottom(elementIDs: [UUID]) async {
        guard !elementIDs.isEmpty else { return }
        let minZ = elements.values.map { $0.zIndex }.min() ?? 0
        var nextZ = minZ - elementIDs.count
        let ordered = elementIDs.compactMap { elements[$0] }.sorted { $0.zIndex < $1.zIndex }
        guard !ordered.isEmpty else { return }
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
        cache.removeAll()
        isDirty = true
    }
    
    /// Fetch a full element by ID (if present).
    func element(id: UUID) async -> CMCanvasElement? {
        return fullElements[id]
    }

    /// Fetch a dictionary of full elements for the given IDs.
    func elements(for ids: [UUID]) async -> [UUID: CMCanvasElement] {
        var result: [UUID: CMCanvasElement] = [:]
        for id in ids {
            if let el = fullElements[id] { result[id] = el }
        }
        return result
    }

    enum TileEvent {
        case willLoad(CMTileKey)
        case didLoad(CMTileKey, headers: [CMElementHeader])
        case evicted(CMTileKey)
    }

    /// One-shot tile stream for the viewport expanded by margin.
    func tileStream(for viewport: CMWorldRect, margin: Double) -> AsyncStream<TileEvent> {
        AsyncStream { continuation in
            Task {
                await self.produceTileEvents(for: viewport, margin: margin, continuation: continuation)
            }
        }
    }
}

