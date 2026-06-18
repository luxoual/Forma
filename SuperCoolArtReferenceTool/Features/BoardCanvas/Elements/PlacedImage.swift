import SwiftUI

struct PlacedImage: Identifiable, Equatable {
    let id: UUID
    let url: URL
    var worldRect: CGRect
    var zIndex: Int
    var parentFrameID: UUID?
}
