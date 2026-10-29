import SwiftUI

@Observable
@MainActor
final class CanvasSelectionState {
    var selectedIDs: Set<UUID> = []
    /// World-space offset being applied during an active drag-move
    var dragOffset: CGSize = .zero
    /// Whether a move drag is in progress
    var isDragging: Bool = false

    // MARK: - Resize state

    /// Which handle is being dragged (nil when not resizing)
    var resizeHandle: HandlePosition?
    /// The element's world rect at resize start
    var resizeStartRect: CGRect?
    /// The live world rect during resize (used for rendering)
    var resizeCurrentRect: CGRect?
    /// The ID of the element being resized
    var resizeElementID: UUID?

    var isResizing: Bool { resizeHandle != nil }

    /// Whether the drag has carried the box past its anchor on each axis.
    /// `resizeHandle` stays the handle the finger grabbed, because the
    /// resize math finds the fixed anchor from it. These flags record which
    /// side of that anchor the box sits on now. They also remember the
    /// previous answer, which the crossing margin (hysteresis) needs.
    var resizeFlippedX: Bool = false
    var resizeFlippedY: Bool = false

    /// Goes up by one every time a resize flips. The canvas watches it to
    /// play a haptic tap on Apple Pencil Pro.
    var resizeFlipCount: Int = 0

    /// The handle to highlight: the grabbed handle, mirrored to wherever
    /// the box has flipped. Drag `.topRight` past the anchor and this
    /// reads `.bottomLeft`.
    var displayedResizeHandle: HandlePosition? {
        resizeHandle?.flipped(horizontally: resizeFlippedX, vertically: resizeFlippedY)
    }

    private func clearResizeFlip() {
        resizeFlippedX = false
        resizeFlippedY = false
    }

    // MARK: - Text-specific resize state
    //
    // Text elements use fontSize (and optionally wrapWidth + origin) as
    // authoritative state, not a worldRect like images. Tracked separately
    // so the existing image-resize state stays clean and the gesture
    // commit can branch by mode.

    var textResizeStartFontSize: CGFloat?
    var textResizeStartWrapWidth: CGFloat?
    var textResizeStartWorldRect: CGRect?
    var textResizeElementID: UUID?

    var isTextResizing: Bool { textResizeStartFontSize != nil }

    func clearTextResize() {
        textResizeStartFontSize = nil
        textResizeStartWrapWidth = nil
        textResizeStartWorldRect = nil
        textResizeElementID = nil
        resizeHandle = nil
        clearResizeFlip()
    }

    func select(_ id: UUID, extending: Bool = false) {
        if extending {
            if selectedIDs.contains(id) {
                selectedIDs.remove(id)
            } else {
                selectedIDs.insert(id)
            }
        } else {
            selectedIDs = [id]
        }
    }

    func clearSelection() {
        selectedIDs.removeAll()
    }

    func clearResize() {
        resizeHandle = nil
        resizeStartRect = nil
        resizeCurrentRect = nil
        resizeElementID = nil
        clearResizeFlip()
    }

    // MARK: - Marquee state

    /// World-space anchor point of the marquee drag
    var marqueeStartWorld: CGPoint?
    /// World-space current corner of the marquee drag
    var marqueeCurrentWorld: CGPoint?

    var isMarqueeing: Bool { marqueeStartWorld != nil }

    /// Normalized world-space rect of the active marquee
    var marqueeWorldRect: CGRect? {
        guard let start = marqueeStartWorld, let current = marqueeCurrentWorld else { return nil }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    func clearMarquee() {
        marqueeStartWorld = nil
        marqueeCurrentWorld = nil
    }

    // MARK: - Group resize state

    /// Original world rects of all selected images at resize start.
    var groupResizeStartRects: [UUID: CGRect]?
    /// Original text-element states at resize start (fontSize/wrapWidth/
    /// origin). Parallel to `groupResizeStartRects` but for text — empty
    /// when the selection contains no text elements.
    var groupResizeTextStartStates: [UUID: TextResizeSnapshot]?
    /// Group bounding box at resize start
    var groupResizeBBoxStart: CGRect?
    /// Live group bounding box during resize
    var groupResizeBBoxCurrent: CGRect?

    var isGroupResizing: Bool {
        groupResizeStartRects != nil || groupResizeTextStartStates != nil
    }

    func clearGroupResize() {
        groupResizeStartRects = nil
        groupResizeTextStartStates = nil
        groupResizeBBoxStart = nil
        groupResizeBBoxCurrent = nil
        resizeHandle = nil
        clearResizeFlip()
    }
}
