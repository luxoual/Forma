import SwiftUI
import UIKit

/// Finds the window's `UndoManager`, hands it to the caller, and stands on the
/// responder chain so the system's undo entry points can reach the canvas.
///
/// Two jobs, both needed:
///
/// 1. **Find the right manager.** The iPadOS menu bar (Edit > Undo / Redo),
///    the three-finger swipe, and ⌘Z all talk to the manager UIKit's
///    responder chain returns — `UIWindow.undoManager`. SwiftUI's
///    `@Environment(\.undoManager)` isn't guaranteed to be that object, so
///    we mount a zero-size UIView, wait for it to land in a window, and read
///    the manager off the window itself.
///
/// 2. **Answer for it.** A menu item only lights up if some responder on the
///    chain says yes to `canPerformAction(#selector(undo:))`. Plain views
///    don't implement `undo:` / `redo:` — only text views do — so a manager
///    full of actions still leaves Edit > Undo grey. This view implements
///    the selectors, validates against the window's manager, and makes
///    itself first responder whenever nothing else is. While a text view has
///    focus it is first responder instead, and its own typing-undo wins.
///    That view is not our descendant, so we never hijack it.
struct WindowUndoManagerReader: UIViewRepresentable {
    let onFound: (UndoManager?) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onFound = onFound
        return view
    }

    func updateUIView(_ uiView: ReaderView, context: Context) {
        uiView.onFound = onFound
    }

    final class ReaderView: UIView {
        var onFound: ((UndoManager?) -> Void)?
        private var editingEndedTask: Task<Void, Never>?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            isUserInteractionEnabled = false
        }

        override var canBecomeFirstResponder: Bool { true }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            editingEndedTask?.cancel()
            editingEndedTask = nil
            guard let window else { return }
            // Deferred: this fires inside SwiftUI's commit, and `onFound`
            // ends up writing @Observable state. Doing that synchronously
            // here trips "modifying state during view update".
            Task { @MainActor in
                onFound?(window.undoManager)
if window.firstResponderView == nil { becomeFirstResponder() }
            }
            // When a canvas text view resigns, first responder becomes nil
            // and the menu items grey out. Step back in — but only if the
            // seat is actually empty. Switching straight from one text box
            // to another fires this for the first while the second may
            // already have focus, and grabbing then would drop the keyboard.
            editingEndedTask = Task { @MainActor [weak self] in
                let ended = NotificationCenter.default.notifications(
                    named: UITextView.textDidEndEditingNotification
                )
                for await _ in ended {
                    await Task.yield()
                    guard let self, let window = self.window else { return }
                    if window.firstResponderView == nil {
                        self.becomeFirstResponder()
                    }
                }
            }
        }

        @objc func undo(_ sender: Any?) { window?.undoManager?.undo() }
        @objc func redo(_ sender: Any?) { window?.undoManager?.redo() }

        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            switch action {
            case #selector(undo(_:)): window?.undoManager?.canUndo ?? false
            case #selector(redo(_:)): window?.undoManager?.canRedo ?? false
            default: super.canPerformAction(action, withSender: sender)
            }
        }
    }
}

private extension UIView {
    /// The view in this subtree that currently holds first responder, if any.
    /// UIKit has no public getter, so walk the hierarchy.
    var firstResponderView: UIView? {
        if isFirstResponder { return self }
        for subview in subviews {
            if let found = subview.firstResponderView { return found }
        }
        return nil
    }
}
