import Foundation

/// Snapshot of a placed element, sufficient to add/remove from the board.
/// `url` is populated for image elements (so the in-memory `PlacedImage`
/// can be reconstructed) and nil for text and other URL-less element types.
struct PlacedElementSnapshot {
    let id: UUID
    let url: URL?
    let worldRect: CGRect
    let zIndex: Int
    let element: CMCanvasElement
}

/// A reversible canvas operation.
enum CanvasCommand {
    case move(elementIDs: Set<UUID>, delta: CGSize)
    case resize(elementID: UUID, fromRect: CGRect, toRect: CGRect)
    case groupResize(fromRects: [UUID: CGRect], toRects: [UUID: CGRect])
    case insert(snapshots: [PlacedElementSnapshot])
    case delete(snapshots: [PlacedElementSnapshot])
    /// Text content was changed during a re-edit. Body of the text element
    /// is the only authoritative state being touched — `worldRect` is
    /// downstream-derived from rendered geometry, so this command doesn't
    /// need to capture it.
    case editTextContent(elementID: UUID, fromContent: String, toContent: String)
    /// Text element was resized via a corner or side handle. Carries every
    /// piece of state a single resize gesture can affect:
    /// - `fontSize`: changes on corner drag (uniform scale, Freeform-style).
    /// - `wrapWidth`: changes on left/right side drag (sets a fixed wrap
    ///   width). Also scales proportionally on corner drag if it was
    ///   already set, so a wrap-locked text grows/shrinks coherently.
    /// - `origin`: shifts on left-side drag to keep the right edge
    ///   anchored (Figma convention). Captured for both axes for
    ///   completeness even though only x changes today.
    case resizeText(
        elementID: UUID,
        fromFontSize: CGFloat, toFontSize: CGFloat,
        fromWrapWidth: CGFloat?, toWrapWidth: CGFloat?,
        fromOrigin: CGPoint, toOrigin: CGPoint
    )
}

/// Tracks performed commands for undo/redo support.
@Observable
@MainActor
final class CanvasCommandHistory {
    private(set) var undoStack: [CanvasCommand] = []
    private(set) var redoStack: [CanvasCommand] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func push(_ command: CanvasCommand) {
        undoStack.append(command)
        redoStack.removeAll()
    }

    func popUndo() -> CanvasCommand? {
        guard let command = undoStack.popLast() else { return nil }
        redoStack.append(command)
        return command
    }

    func popRedo() -> CanvasCommand? {
        guard let command = redoStack.popLast() else { return nil }
        undoStack.append(command)
        return command
    }

    func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
