import Foundation

// swiftc -module-cache-path /tmp/forma-swift-cache \
//   SuperCoolArtReferenceTool/Persistence/CanvasModels.swift \
//   tests/AssetNameChecks.swift -o /tmp/forma-name-checks && /tmp/forma-name-checks
@main
struct AssetNameChecks {
    static func main() throws {
        let header = CMElementHeader(id: UUID(), type: .text, transform: CMAffineTransform2D(),
                                     bounds: CMWorldRect(origin: .zero, size: SIMD2(100, 100)),
                                     layerId: UUID(), zIndex: 1, parentID: UUID(), displayName: "Pose reference")
        let element = CMCanvasElement(header: header, payload: .text(content: "Original note", fontName: "system", fontSize: 24, color: "#000000", wrapWidth: nil))
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let restored = try decoder.decode(CMCanvasElement.self, from: encoder.encode(element))
        precondition(restored.header.displayName == "Pose reference", "Names survive the board's Codable representation")
        precondition(restored.payload == element.payload, "Renaming leaves text content unchanged")
        precondition(restored.header.parentID == element.header.parentID, "Renaming preserves frame membership")
        var legacy = try JSONSerialization.jsonObject(with: encoder.encode(header)) as! [String: Any]
        legacy.removeValue(forKey: "displayName")
        let oldHeader = try decoder.decode(CMElementHeader.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(oldHeader.displayName == nil, "Old boards without names remain readable")
        var image = CMCanvasElement(header: header, payload: .image(url: URL(fileURLWithPath: "/tmp/original.png"), size: SIMD2(100, 100)))
        image.header.type = .image
        let restoredImage = try decoder.decode(CMCanvasElement.self, from: encoder.encode(image))
        precondition(restoredImage.payload == image.payload && restoredImage.header.displayName == header.displayName,
                     "Image labels survive without changing the source URL")
        print("5 asset naming persistence checks passed")
    }
}
