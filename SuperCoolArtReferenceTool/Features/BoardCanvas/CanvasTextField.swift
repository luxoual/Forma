import SwiftUI
import UIKit

/// Multi-line text input for canvas text elements. Wraps a UITextView
/// subclass that overrides `caretRect(for:)` to render the caret at a
/// constant on-screen thickness (`2.5pt`) regardless of canvas zoom or
/// font size. Caret HEIGHT still follows the text height; only the
/// THICKNESS is held constant.
///
/// Why: the canvas applies `.scaleEffect(scale)` to text elements for
/// visual zoom (avoids CoreText hinting drift across zoom levels).
/// SwiftUI's `TextField` has a fixed ~2pt native caret that the
/// scaleEffect then shrinks, leaving the caret invisible when text is
/// resized large + canvas zoomed out. The override returns
/// `2.5 / canvasScale` in base units so that after scaleEffect brings
/// it down by `scale`, visible thickness lands at exactly 2.5pt.
struct CanvasTextField: UIViewRepresentable {
    @Binding var text: String
    /// Base/world font size in points (NOT pre-multiplied by canvasScale).
    /// scaleEffect handles visual zoom downstream.
    let fontSize: CGFloat
    /// Current canvas zoom factor. Used to keep caret thickness +
    /// trailing slack at constant visible sizes after scaleEffect.
    let canvasScale: CGFloat
    let textColor: Color
    let isEditing: Bool
    let onCommit: () -> Void

    func makeUIView(context: Context) -> CanvasUITextView {
        let view = CanvasUITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        // Match SwiftUI Text's default rendering: no padding around the
        // glyph metrics. UITextView's defaults (8pt vertical inset, 5pt
        // line fragment padding) would offset the editing layout from
        // the static Text used post-commit, causing a visible jump.
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        // Auto-grow with content (intrinsicContentSize): SwiftUI sizes
        // us via the intrinsic; with scrolling enabled we'd never grow.
        view.isScrollEnabled = false
        view.autocapitalizationType = .sentences
        view.autocorrectionType = .yes
        view.smartQuotesType = .yes
        view.smartDashesType = .yes
        view.textAlignment = .left
        view.spellCheckingType = .yes
        view.allowsEditingTextAttributes = false
        return view
    }

    func updateUIView(_ uiView: CanvasUITextView, context: Context) {
        // Guard against redundant text writes — touching `text` resets
        // caret position and selection, which would jump on every
        // scaleEffect tick during a pinch.
        if uiView.text != text {
            uiView.text = text
        }
        uiView.font = UIFont.systemFont(ofSize: fontSize)
        uiView.textColor = UIColor(textColor)
        // tintColor is BOTH the caret color and the selection-highlight
        // color. Primary (dark) so the caret contrasts the editing
        // border (tertiary blue) — blue-on-blue would blend.
        uiView.tintColor = UIColor(DesignSystem.Colors.primary)
        uiView.canvasScale = canvasScale
        // Reserve trailing space inside the text container so the caret
        // can render at end-of-text without clipping the view bounds.
        // SwiftUI's TextField has analogous built-in slack; UITextView
        // doesn't. Width matches the constant-visible-thickness formula
        // in CanvasUITextView.caretRect — base = 2.5 / canvasScale →
        // 2.5pt visible after scaleEffect.
        let caretThickness = 2.5 / max(canvasScale, 0.0001)
        uiView.textContainerInset = UIEdgeInsets(
            top: 0, left: 0, bottom: 0, right: caretThickness
        )
        // Push the latest closure onto the coordinator each pass so
        // captured state (e.g. the surrounding view's id) stays fresh.
        context.coordinator.onCommit = onCommit

        // Drive focus from `isEditing`. `becomeFirstResponder` triggers a
        // keyboard show, so guard against redundant calls.
        if isEditing && !uiView.isFirstResponder {
            // Defer one runloop tick so the view has a window/superview
            // assignment before requesting focus.
            Task { @MainActor in
                uiView.becomeFirstResponder()
            }
        } else if !isEditing && uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommit: onCommit)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        let text: Binding<String>
        var onCommit: () -> Void

        init(text: Binding<String>, onCommit: @escaping () -> Void) {
            self.text = text
            self.onCommit = onCommit
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            // Ensure the last keystroke is propagated before the parent
            // reads `placed.content` in commitTextEdit. UITextViewDelegate
            // typically fires didChange before didEndEditing already, but
            // an explicit sync guards against ordering surprises with
            // dictation / autocomplete commits.
            if text.wrappedValue != textView.text {
                text.wrappedValue = textView.text
            }
            onCommit()
        }
    }
}

/// UITextView subclass with a custom `caretRect(for:)` that holds the
/// caret thickness at a constant 2.5pt on-screen regardless of font
/// size or canvas zoom. Caret height continues to follow text height
/// via `super.caretRect.height`.
final class CanvasUITextView: UITextView {
    /// Canvas zoom factor passed in from the SwiftUI side. Used to
    /// pre-divide caret thickness so the post-scaleEffect visible
    /// thickness lands at the target value.
    var canvasScale: CGFloat = 1.0 {
        didSet {
            if oldValue != canvasScale {
                // Force the system to redraw the caret at the new
                // thickness on the next blink cycle.
                setNeedsLayout()
            }
        }
    }

    override func caretRect(for position: UITextPosition) -> CGRect {
        let original = super.caretRect(for: position)
        // Constant on-screen caret thickness. Base value is
        // `targetVisible / canvasScale` so that after the surrounding
        // `.scaleEffect(scale)` brings it down by `scale`, the visible
        // thickness lands at exactly `targetVisible` regardless of
        // canvas zoom or font size.
        let targetVisible: CGFloat = 2.5
        let thickness = targetVisible / max(canvasScale, 0.0001)
        return CGRect(
            x: original.origin.x,
            y: original.origin.y,
            width: thickness,
            height: original.height
        )
    }
}
