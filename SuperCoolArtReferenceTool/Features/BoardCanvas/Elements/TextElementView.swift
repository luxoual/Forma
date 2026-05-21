import SwiftUI

// Lightweight free-floating text view. Renders at fixed-point font size
// (no `*scale`), so when the canvas zooms the text on screen stays the
// same visible size while its world-space footprint shrinks/grows
// inversely. Rendered size is reported back via `onMeasured` so the
// parent can keep `placed.worldRect.size` aligned with what the user
// actually sees — that's what hit-testing, marquee, and selection
// bounding-box read.
struct TextElementView: View {
    @Binding var placed: PlacedText
    let scale: CGFloat
    let isEditing: Bool
    let isSelected: Bool
    let isMultiSelected: Bool
    let onCommitEdit: () -> Void

    /// Minimum width applied to the editing ZStack in BASE/world units
    /// so the empty placeholder + caret have somewhere to render before
    /// typed content gives the field its own intrinsic width. Scales
    /// with zoom via `.scaleEffect(scale)` like everything else in the
    /// element — visible width is `editingMinWorldWidth * scale`.
    private static let editingMinWorldWidth: CGFloat = 80

    /// Solo-text selections show only the corners + left/right edges.
    /// Top/bottom edge handles are hidden because text height is
    /// always content-derived; there's no meaningful "stretch height
    /// independently" gesture for text. Exposed so BoardCanvasView's
    /// body can render the same set externally at screen coordinates
    /// (handles stay touch-friendly under zoom).
    static let textHandles: Set<HandlePosition> = [
        .topLeft, .topRight, .bottomLeft, .bottomRight,
        .leftCenter, .rightCenter
    ]

    var body: some View {
        sizedContent
            .padding(4)
            .overlay {
                // Multi-select dim border stays inside the scaleEffect
                // — it's a low-priority cosmetic indicator and the
                // chrome already rendered around the group bbox is
                // the primary affordance. The editing border + solo-
                // selection handles render EXTERNALLY in BoardCanvasView
                // at screen coordinates so their stroke widths and
                // handle sizes stay touch-friendly regardless of zoom.
                if isSelected && isMultiSelected {
                    Rectangle()
                        .strokeBorder(DesignSystem.Colors.tertiary.opacity(0.5), lineWidth: 1)
                }
            }
            // scaleEffect: lay out the text at base/world units, then
            // visually shrink/grow with canvas zoom. Layout is invariant
            // under scale, which kills the sub-pixel drift bug where the
            // same wrap-locked content fit on one line at zoom 1 but
            // wrapped to two at zoom 0.2 because CoreText hinting at
            // small fonts makes glyphs slightly wider than linear.
            // Anchor `.center` so the visual midpoint matches the
            // layout midpoint that the parent's `.position(...)` is
            // already centering at the screen target.
            .scaleEffect(scale, anchor: .center)
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { newSize in
                // newSize is the BASE/world-unit size now (scaleEffect
                // doesn't change layout). Cache directly into worldRect
                // for hit-testing / bbox math.
                if placed.worldRect.size != newSize {
                    placed.worldRect.size = newSize
                }
            }
            // Focus + commit-on-end-editing are handled inside the
            // CanvasTextField wrapper now (UITextViewDelegate).
    }

    /// The text content with its size-defining modifiers applied at
    /// BASE scale (no `* scale`). The outer `body` wraps this with a
    /// `.scaleEffect(scale)` for the visual zoom, so layout decisions
    /// (line wrapping, intrinsic width) happen once and don't drift
    /// with zoom level.
    ///
    /// Split off so the auto-width path doesn't carry a
    /// `.frame(width:)` modifier at all — at small font sizes an
    /// unconditional `.frame(width: nil)` can subtly interact with
    /// trailing `.fixedSize` and force unwanted wrapping.
    @ViewBuilder
    private var sizedContent: some View {
        let inner = textOrField
            .font(.system(size: placed.fontSize, weight: .regular))
            .foregroundStyle(placed.color)

        if let wrap = placed.wrapWidth {
            inner
                // Explicit leading alignment so short content doesn't
                // get centered inside a too-wide wrap frame (TextField
                // in axis: .vertical doesn't fill width, and the
                // default `.frame(width:)` alignment is .center —
                // produced a "centered while editing, leading after
                // commit" alignment flicker).
                .frame(width: wrap, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            inner
                .fixedSize(horizontal: true, vertical: true)
        }
    }

    @ViewBuilder
    private var textOrField: some View {
        // Wrap mode (wrapWidth set): TextField + Text both wrap inside
        // the explicit `.frame(width:)` applied by sizedContent.
        // Auto-width (wrapWidth nil): the sacrificial-Text ZStack
        // drives the editing TextField's width to the longest line so
        // typing grows the field horizontally and never auto-wraps.
        let isWrapMode = placed.wrapWidth != nil
        if isEditing {
            // CanvasTextField is a UITextView wrapper that overrides
            // caretRect(for:) so the caret stays visible across the
            // full range of fontSize × canvasScale combinations.
            // Native SwiftUI TextField/TextEditor have a fixed ~2pt
            // caret that becomes invisible under our scaleEffect at
            // low zoom. See CanvasTextField.swift for the math.
            if isWrapMode {
                CanvasTextField(
                    text: $placed.content,
                    fontSize: placed.fontSize,
                    canvasScale: scale,
                    textColor: placed.color,
                    isEditing: true,
                    onCommit: onCommitEdit
                )
            } else {
                ZStack(alignment: .topLeading) {
                    Text(placed.content.isEmpty ? "Text" : placed.content)
                        .fixedSize(horizontal: true, vertical: true)
                        .opacity(0)
                        .accessibilityHidden(true)

                    CanvasTextField(
                        text: $placed.content,
                        fontSize: placed.fontSize,
                        canvasScale: scale,
                        textColor: placed.color,
                        isEditing: true,
                        onCommit: onCommitEdit
                    )
                }
                .frame(minWidth: Self.editingMinWorldWidth, alignment: .topLeading)
            }
        } else {
            Text(placed.content.isEmpty ? "Text" : placed.content)
                .opacity(placed.content.isEmpty ? 0.4 : 1.0)
                .multilineTextAlignment(.leading)
        }
    }
}
