import Foundation
import simd

/// Types of elements that can appear on the canvas.
public enum CMElementType: String, Codable, Hashable {
    case rectangle
    case ellipse
    case path
    case text
    case image
}

/// Represents a rectangular area in the world coordinate space.
public struct CMWorldRect: Codable, Hashable {
    public var origin: SIMD2<Double>
    public var size: SIMD2<Double>
    
    /// Initializes a CMWorldRect with origin and size.
    public init(origin: SIMD2<Double>, size: SIMD2<Double>) {
        self.origin = origin
        self.size = size
    }
    
    /// Checks if this rectangle intersects with another.
    public func intersects(_ other: CMWorldRect) -> Bool {
        let aMin = origin
        let aMax = origin + size
        let bMin = other.origin
        let bMax = other.origin + other.size
        
        return !(aMax.x <= bMin.x || aMin.x >= bMax.x || aMax.y <= bMin.y || aMin.y >= bMax.y)
    }
    
    /// Returns the union of this rectangle with another.
    public func union(_ other: CMWorldRect) -> CMWorldRect {
        let minX = min(origin.x, other.origin.x)
        let minY = min(origin.y, other.origin.y)
        let maxX = max(origin.x + size.x, other.origin.x + other.size.x)
        let maxY = max(origin.y + size.y, other.origin.y + other.size.y)
        
        return CMWorldRect(origin: SIMD2<Double>(minX, minY), size: SIMD2<Double>(maxX - minX, maxY - minY))
    }
}

/// Represents a 2D affine transformation.
public struct CMAffineTransform2D: Codable, Hashable {
    public var matrix: simd_double3x3

    public init() { self.matrix = matrix_identity_double3x3 }
    public init(matrix: simd_double3x3) { self.matrix = matrix }

    public func hash(into hasher: inout Hasher) {
        let m = matrix
        hasher.combine(m.columns.0.x); hasher.combine(m.columns.0.y); hasher.combine(m.columns.0.z)
        hasher.combine(m.columns.1.x); hasher.combine(m.columns.1.y); hasher.combine(m.columns.1.z)
        hasher.combine(m.columns.2.x); hasher.combine(m.columns.2.y); hasher.combine(m.columns.2.z)
    }

    public static func == (lhs: CMAffineTransform2D, rhs: CMAffineTransform2D) -> Bool {
        lhs.matrix == rhs.matrix
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var vals: [Double] = []
        vals.reserveCapacity(9)
        while !container.isAtEnd { vals.append(try container.decode(Double.self)) }
        guard vals.count == 9 else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Expected 9 doubles for matrix")) }
        self.matrix = simd_double3x3(
            SIMD3(vals[0], vals[1], vals[2]),
            SIMD3(vals[3], vals[4], vals[5]),
            SIMD3(vals[6], vals[7], vals[8])
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        let m = matrix
        try container.encode(m.columns.0.x); try container.encode(m.columns.0.y); try container.encode(m.columns.0.z)
        try container.encode(m.columns.1.x); try container.encode(m.columns.1.y); try container.encode(m.columns.1.z)
        try container.encode(m.columns.2.x); try container.encode(m.columns.2.y); try container.encode(m.columns.2.z)
    }
}

/// Header for a canvas element, containing common metadata.
public struct CMElementHeader: Codable, Hashable, Identifiable {
    public var id: UUID
    public var type: CMElementType
    public var transform: CMAffineTransform2D
    public var bounds: CMWorldRect
    public var layerId: CMLayerID
    public var zIndex: Int

    public init(id: UUID, type: CMElementType, transform: CMAffineTransform2D, bounds: CMWorldRect, layerId: CMLayerID, zIndex: Int) {
        self.id = id
        self.type = type
        self.transform = transform
        self.bounds = bounds
        self.layerId = layerId
        self.zIndex = zIndex
    }
}

/// Payload data for different canvas element types.
public enum CMCanvasElementPayload: Codable, Hashable {
    case rectangle(fillColor: String)
    case ellipse(fillColor: String)
    case path(points: [SIMD2<Double>], strokeColor: String, strokeWidth: Double)
    case text(content: String, fontName: String, fontSize: Double, color: String)
    case image(url: URL, size: SIMD2<Double>)
    
    private enum CodingKeys: String, CodingKey {
        case type
        case fillColor
        case points
        case strokeColor
        case strokeWidth
        case content
        case fontName
        case fontSize
        case color
        case url
        case size
    }
    
    private enum PayloadType: String, Codable {
        case rectangle, ellipse, path, text, image
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(PayloadType.self, forKey: .type)
        switch type {
        case .rectangle:
            let fillColor = try container.decode(String.self, forKey: .fillColor)
            self = .rectangle(fillColor: fillColor)
        case .ellipse:
            let fillColor = try container.decode(String.self, forKey: .fillColor)
            self = .ellipse(fillColor: fillColor)
        case .path:
            let points = try container.decode([SIMD2<Double>].self, forKey: .points)
            let strokeColor = try container.decode(String.self, forKey: .strokeColor)
            let strokeWidth = try container.decode(Double.self, forKey: .strokeWidth)
            self = .path(points: points, strokeColor: strokeColor, strokeWidth: strokeWidth)
        case .text:
            let content = try container.decode(String.self, forKey: .content)
            let fontName = try container.decode(String.self, forKey: .fontName)
            let fontSize = try container.decode(Double.self, forKey: .fontSize)
            let color = try container.decode(String.self, forKey: .color)
            self = .text(content: content, fontName: fontName, fontSize: fontSize, color: color)
        case .image:
            let url = try container.decode(URL.self, forKey: .url)
            let size = try container.decode(SIMD2<Double>.self, forKey: .size)
            self = .image(url: url, size: size)
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .rectangle(let fillColor):
            try container.encode(PayloadType.rectangle, forKey: .type)
            try container.encode(fillColor, forKey: .fillColor)
        case .ellipse(let fillColor):
            try container.encode(PayloadType.ellipse, forKey: .type)
            try container.encode(fillColor, forKey: .fillColor)
        case .path(let points, let strokeColor, let strokeWidth):
            try container.encode(PayloadType.path, forKey: .type)
            try container.encode(points, forKey: .points)
            try container.encode(strokeColor, forKey: .strokeColor)
            try container.encode(strokeWidth, forKey: .strokeWidth)
        case .text(let content, let fontName, let fontSize, let color):
            try container.encode(PayloadType.text, forKey: .type)
            try container.encode(content, forKey: .content)
            try container.encode(fontName, forKey: .fontName)
            try container.encode(fontSize, forKey: .fontSize)
            try container.encode(color, forKey: .color)
        case .image(let url, let size):
            try container.encode(PayloadType.image, forKey: .type)
            try container.encode(url, forKey: .url)
            try container.encode(size, forKey: .size)
        }
    }
}

/// Represents a single element on the canvas with header and payload.
public struct CMCanvasElement: Codable, Hashable, Identifiable {
    public var id: UUID { header.id }
    public var header: CMElementHeader
    public var payload: CMCanvasElementPayload

    public init(header: CMElementHeader, payload: CMCanvasElementPayload) {
        self.header = header
        self.payload = payload
    }
}

/// Key identifying a tile on the canvas grid.
public struct CMTileKey: Codable, Hashable {
    public static let size: Double = 1024
    public var x: Int
    public var y: Int
    public init(x: Int, y: Int) { self.x = x; self.y = y }

    /// Returns all tile keys intersecting with the given CMWorldRect.
    public static func keysIntersecting(rect: CMWorldRect) -> [CMTileKey] {
        let tileSize = CMTileKey.size
        let minX = Int(floor(rect.origin.x / tileSize))
        let minY = Int(floor(rect.origin.y / tileSize))
        let maxX = Int(floor((rect.origin.x + rect.size.x - 1e-9) / tileSize))
        let maxY = Int(floor((rect.origin.y + rect.size.y - 1e-9) / tileSize))
        var keys: [CMTileKey] = []
        for x in minX...maxX { for y in minY...maxY { keys.append(CMTileKey(x: x, y: y)) } }
        return keys
    }
}

/// Identifier for a canvas layer.
public typealias CMLayerID = UUID
