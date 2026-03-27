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
        var affected: Set<CMTileKey> = []
        for header in headers {
            elements[header.id] = header
            for key in CMTileKey.keysIntersecting(rect: header.bounds) {
                tileIndex[key, default: []].insert(header.id)
                affected.insert(key)
            }
        }
        for key in affected { cache.remove(key) }
    }
    
    /// Insert or update full elements (header + payload) and update tile index.
    func upsert(elements: [CMCanvasElement]) async {
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
        for id in elementIDs {
            elements.removeValue(forKey: id)
            fullElements.removeValue(forKey: id)
        }
        // Rebuild tile index naively
        tileIndex.removeAll()
        for header in elements.values {
            for key in CMTileKey.keysIntersecting(rect: header.bounds) {
                tileIndex[key, default: []].insert(header.id)
            }
        }
        cache.removeAll()
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

