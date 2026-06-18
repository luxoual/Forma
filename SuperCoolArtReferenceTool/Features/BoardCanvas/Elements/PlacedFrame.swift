import Foundation

struct PlacedFrame: Identifiable, Equatable {
    let id: UUID
    var title: String
    var worldRect: CGRect
    var zIndex: Int
    var parentFrameID: UUID? = nil
}
