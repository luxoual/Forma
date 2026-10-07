import SwiftUI

/// A frame's box: solid fill and border. Its name pill is drawn separately
/// (`FrameTitlePill`) because the box is clipped to its ancestors' bounds,
/// and the pill sits just *outside* the box, where that clip would hide it.
struct CanvasPlacedFrameView: View {
    let screenRect: CGRect
    let fill: Color
    let isSelected: Bool
    let zIndex: Int

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(fill)
            .strokeBorder(
                isSelected ? DesignSystem.Colors.tertiary : DesignSystem.Colors.secondary.opacity(0.55),
                lineWidth: isSelected ? 2 : 1
            )
            .frame(width: screenRect.width, height: screenRect.height)
            // The body never selects the frame (Figma convention): taps fall
            // through to the canvas, and only the name pill picks the frame.
            .allowsHitTesting(false)
            .position(x: screenRect.midX, y: screenRect.midY)
            .zIndex(Double(zIndex))
    }
}

/// The frame's name as plain text, sitting just above its top-left corner.
///
/// - Tap: select the frame.
/// - Double-tap: rename it in place. Enter or tapping away saves, Escape
///   cancels.
struct FrameTitlePill: View {
    let title: String
    let isSelected: Bool
    let onSelect: () -> Void
    let onRename: (String) -> Void

    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    /// The pill is as wide as its frame on screen, but never narrower than
    /// this, so a tiny or far-zoomed-out frame's name stays readable. The
    /// host proposes that width; a single-line `Text` hugs short names and
    /// truncates long ones within it.
    static let minWidth: CGFloat = 64

    var body: some View {
        Group {
            if isEditing {
                TextField("Frame name", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onAppear { isFocused = true }
                    .onSubmit(commit)
                    .onKeyPress(.escape) {
                        isEditing = false
                        return .handled
                    }
            } else {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .font(.caption.weight(.semibold))
        // Same trick as `EmptyCanvasOverlay`: `.difference` inverts against
        // whatever is behind, so the name stays readable on any canvas or
        // frame color. Selected names drop the blend and show the accent,
        // which would otherwise invert to a different hue.
        .foregroundStyle(isSelected ? DesignSystem.Colors.tertiary : DesignSystem.Colors.secondary)
        .compositingGroup()
        .blendMode(isSelected ? .normal : .difference)
        // No leading padding, so the text starts flush with the frame's
        // left edge. The rest only pads the tap target.
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .gesture(
            TapGesture(count: 2).exclusively(before: TapGesture())
                .onEnded { gesture in
                    switch gesture {
                    case .first:
                        onSelect()
                        draft = title
                        isEditing = true
                    case .second:
                        onSelect()
                    }
                },
            including: isEditing ? .subviews : .all
        )
        .onChange(of: isFocused) { _, focused in
            if !focused && isEditing { commit() }
        }
        // Tapping the canvas or another item doesn't take keyboard focus,
        // so focus alone won't end the edit. It does change the selection,
        // and starting a rename selects the frame, so losing selection is
        // the reliable "user moved on" signal.
        .onChange(of: isSelected) { _, selected in
            if !selected && isEditing { commit() }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Frame \(title)")
        // VoiceOver activation selects; renaming needs its own action since
        // the double-tap gesture isn't reachable.
        .accessibilityAction { onSelect() }
        .accessibilityAction(named: "Rename") {
            onSelect()
            draft = title
            isEditing = true
        }
    }

    private func commit() {
        guard isEditing else { return }
        isEditing = false
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != title { onRename(name) }
    }
}
