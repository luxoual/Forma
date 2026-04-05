import Foundation
import simd

public protocol CanvasService {
    func upsert(elements: [CMCanvasElement]) async throws
    func delete(elementIDs: [UUID]) async throws
    func elements(in rect: CMWorldRect, layers: [UUID]?, limit: Int?) async throws -> [CMElementHeader]
    func elements(in viewport: CMWorldRect, margin: Double, layers: [UUID]?, limit: Int?) async throws -> [CMElementHeader]
    func topmostElement(at point: SIMD2<Double>, layers: [UUID]?) async throws -> CMElementHeader?
    func moveToTop(elementIDs: [UUID]) async throws
    func moveToBottom(elementIDs: [UUID]) async throws
    func elementDetail(id: UUID) async throws -> CMCanvasElement?
    func tileStream(for viewport: CMWorldRect, margin: Double) -> AsyncStream<CanvasServiceTileEvent>
    var changes: AsyncStream<CanvasServiceChange> { get }
}

public enum CanvasServiceTileEvent {
    case willLoad(CMTileKey)
    case didLoad(CMTileKey, headers: [CMElementHeader])
    case evicted(CMTileKey)
}

public enum CanvasServiceChange {
    case elementsUpserted([UUID])
    case elementsDeleted([UUID])
}

