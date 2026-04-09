import Foundation

/// A reversible canvas operation.
enum CanvasCommand {
    case move(elementIDs: Set<UUID>, delta: CGSize)
    case resize(elementID: UUID, fromRect: CGRect, toRect: CGRect)
}

/// Tracks performed commands for undo/redo support.
@Observable
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
}
