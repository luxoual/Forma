import SwiftUI

struct PlacedImage: Identifiable {
    let id: UUID
    let url: URL
    var worldRect: CGRect
    var zIndex: Int
}
