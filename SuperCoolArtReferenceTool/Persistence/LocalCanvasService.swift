import Foundation
import simd

/// A simple CanvasService implementation backed by LocalBoardStore for demo purposes.
public final class LocalCanvasService: CanvasService {
    private let store: LocalBoardStore

    private let changeStream: AsyncStream<CanvasServiceChange>
    private var changeContinuation: AsyncStream<CanvasServiceChange>.Continuation

    init(store: LocalBoardStore) {
        self.store = store
        var cont: AsyncStream<CanvasServiceChange>.Continuation!
        self.changeStream = AsyncStream<CanvasServiceChange> { continuation in
            cont = continuation
        }
        self.changeContinuation = cont
    }

    // MARK: - CanvasService

    public func upsert(elements: [CMCanvasElement]) async throws {
        await store.upsert(elements: elements)
        let ids = elements.map { $0.id }
        changeContinuation.yield(.elementsUpserted(ids))
    }

    public func delete(elementIDs: [UUID]) async throws {
        await store.delete(elementIDs: elementIDs)
        changeContinuation.yield(.elementsDeleted(elementIDs))
    }

    public func elements(in rect: CMWorldRect, layers: [UUID]?, limit: Int?) async throws -> [CMElementHeader] {
        // For demo, ignore layers and just return headers in rect
        return await store.headers(in: rect, limit: limit)
    }

    public func elements(in viewport: CMWorldRect, margin: Double, layers: [UUID]?, limit: Int?) async throws -> [CMElementHeader] {
        // For demo, ignore layers and just return headers in expanded viewport
        return await store.headers(in: viewport, margin: margin, limit: limit)
    }

    public func topmostElement(at point: SIMD2<Double>, layers: [UUID]?) async throws -> CMElementHeader? {
        // For demo, ignore layers and just return topmost header at point
        return await store.topmostHeader(at: point)
    }

    public func moveToTop(elementIDs: [UUID]) async throws {
        await store.moveToTop(elementIDs: elementIDs)
        changeContinuation.yield(.elementsUpserted(elementIDs))
    }

    public func moveToBottom(elementIDs: [UUID]) async throws {
        await store.moveToBottom(elementIDs: elementIDs)
        changeContinuation.yield(.elementsUpserted(elementIDs))
    }

    public func elementDetail(id: UUID) async throws -> CMCanvasElement? {
        return await store.element(id: id)
    }

    public func tileStream(for viewport: CMWorldRect, margin: Double) -> AsyncStream<CanvasServiceTileEvent> {
        let local = store.tileStream(for: viewport, margin: margin)
        return AsyncStream { continuation in
            Task {
                for await event in local {
                    switch event {
                    case .willLoad(let key):
                        continuation.yield(.willLoad(key))
                    case .didLoad(let key, let headers):
                        continuation.yield(.didLoad(key, headers: headers))
                    case .evicted(let key):
                        continuation.yield(.evicted(key))
                    }
                }
                continuation.finish()
            }
        }
    }

    public var changes: AsyncStream<CanvasServiceChange> { changeStream }
}

