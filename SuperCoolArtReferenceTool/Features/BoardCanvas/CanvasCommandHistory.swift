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

/// Captures every piece of text-element state a resize gesture can affect.
/// Used inside `.groupResize` so text in a multi-selection participates
/// atomically with image rect changes (one undo press = revert everything).
struct TextResizeSnapshot {
    let fontSize: CGFloat
    let wrapWidth: CGFloat?
    let origin: CGPoint
}

/// A reversible canvas operation.
enum CanvasCommand {
    case move(elementIDs: Set<UUID>, delta: CGSize)
    case resize(elementID: UUID, fromRect: CGRect, toRect: CGRect)
    /// Resize of a multi-element selection. `fromRects`/`toRects` cover
    /// image elements (which use a worldRect as authoritative state).
    /// `fromTextStates`/`toTextStates` cover text elements (which use
    /// fontSize + wrapWidth + origin). Mixed selections include entries
    /// in both dicts; pure-image groups leave the text dicts empty;
    /// pure-text groups leave the rect dicts empty. Either way the undo
    /// is atomic.
    case groupResize(
        fromRects: [UUID: CGRect],
        toRects: [UUID: CGRect],
        fromTextStates: [UUID: TextResizeSnapshot],
        toTextStates: [UUID: TextResizeSnapshot]
    )
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
    /// Text color was changed from the selection action bar. Unlike the
    /// other cases this carries only one side — "put these elements in
    /// these colors" — because it is registered on the *first* frame of a
    /// picker drag, before anyone knows where the drag will end. Undo runs
    /// it with the original colors; the redo command is built from the live
    /// board at undo time (see `BoardCanvasView.perform(_:)`), which is when
    /// the final picked color is actually known.
    case setTextColors(hexes: [UUID: String])

    /// Label the system shows in the Undo/Redo pill and the Edit menu
    /// ("Undo Move", "Redo Delete").
    ///
    /// Named for the *edit this command undoes*, because what gets registered
    /// is always the reverse: after the user deletes, the registered command
    /// is `.insert`, and the pill should still read "Undo Delete". Every
    /// other case is its own reverse, so the name is the same either way.
    var undoneEditName: String {
        switch self {
        case .move: "Move"
        case .resize, .groupResize: "Resize"
        case .insert: "Delete"
        case .delete: "Add"
        case .editTextContent: "Edit Text"
        case .resizeText: "Resize Text"
        case .setTextColors: "Text Color"
        }
    }
}

/// The board's handle on the system `UndoManager`.
///
/// We don't keep our own undo/redo stacks. Every reversible edit is handed
/// to the window's `UndoManager` (Foundation's built-in undo system), and
/// the system does the rest: three-finger swipe left/right, the floating
/// Undo/Redo pill, ⌘Z / ⇧⌘Z on a hardware keyboard, and the Edit menu all
/// route into that same manager for free.
///
/// The only reason this is a class is that `UndoManager.registerUndo` needs
/// a class instance as the "target" of each action, and `BoardCanvasView` is
/// a struct. Being the target also lets `clear()` remove *only our* actions
/// from the shared manager, without touching whatever else the window has
/// registered.
///
/// `canUndo` / `canRedo` mirror the manager's state so SwiftUI can grey out
/// the toolbar buttons. `UndoManager` isn't observable, so we listen to its
/// notifications and copy the answer over each time it changes.
@Observable
@MainActor
final class CanvasCommandHistory {
    private(set) var canUndo = false
    private(set) var canRedo = false

    /// The window's undo manager, handed over by `WindowUndoManagerReader`
    /// once the canvas is in a window. Nil before that (and in previews), in
    /// which case registrations are dropped — there's no user yet to undo for.
    @ObservationIgnored private var undoManager: UndoManager?
    @ObservationIgnored private var observerTasks: [Task<Void, Never>] = []

    deinit {
        observerTasks.forEach { $0.cancel() }
    }

    /// Point this history at `manager`. Safe to call repeatedly; re-attaching
    /// the same manager is a no-op.
    func attach(_ manager: UndoManager?) {
        guard manager !== undoManager else { return }
        undoManager?.removeAllActions(withTarget: self)
        undoManager = manager
        observe(manager)
        refresh()
    }

    /// Register `command` as what undo should run next.
    ///
    /// `perform` is the board's "run this command and hand back its
    /// reverse" function. When the user undoes, we run `command` through it
    /// and register the returned reverse — and because `UndoManager` knows
    /// it is mid-undo at that moment, that second registration lands on the
    /// redo stack. That one trick is how redo works without a second stack.
    func registerUndo(
        _ command: CanvasCommand,
        perform: @escaping @MainActor (CanvasCommand) -> CanvasCommand
    ) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { history in
            let redo = perform(command)
            history.registerUndo(redo, perform: perform)
        }
        // Only name the group on a fresh edit. Mid-undo or mid-redo the
        // manager carries the original name across to the new group itself.
        if !undoManager.isUndoing && !undoManager.isRedoing {
            undoManager.setActionName(command.undoneEditName)
        }
        // `canUndo` flips when the run loop closes this event's group;
        // the DidCloseUndoGroup observer below picks that up.
    }

    func undo() { undoManager?.undo() }
    func redo() { undoManager?.redo() }

    /// Drop every action we registered. Called after importing a board, so
    /// undo can't reach back into the previous board and try to resurrect
    /// assets that no longer exist.
    func clear() {
        undoManager?.removeAllActions(withTarget: self)
        refresh()
    }

    private func observe(_ manager: UndoManager?) {
        observerTasks.forEach { $0.cancel() }
        observerTasks = []
        guard let manager else { return }
        // These three are the moments the stacks actually change. A fresh
        // registration lands as a group that the run loop closes at the end
        // of the event, so DidCloseUndoGroup catches new actions too.
        //
        // Deliberately NOT `NSUndoManagerCheckpoint`: reading `canRedo`
        // posts that notification, so a checkpoint observer that reads
        // `canRedo` would wake itself up forever.
        let names: [Notification.Name] = [
            .NSUndoManagerDidCloseUndoGroup,
            .NSUndoManagerDidUndoChange,
            .NSUndoManagerDidRedoChange,
        ]
        observerTasks = names.map { name in
            Task { [weak self] in
                let changes = NotificationCenter.default.notifications(named: name, object: manager)
                for await _ in changes {
                    guard let self else { return }
                    self.refresh()
                }
            }
        }
    }

    private func refresh() {
        canUndo = undoManager?.canUndo ?? false
        canRedo = undoManager?.canRedo ?? false
    }
}
