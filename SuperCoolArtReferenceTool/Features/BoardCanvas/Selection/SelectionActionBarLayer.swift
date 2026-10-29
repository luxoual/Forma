import SwiftUI

/// Positions `CanvasSelectionActionBar` beneath the current selection.
///
/// The bar fades in and out, but never slides. It always appears already in
/// place under the new selection, instead of gliding over from wherever the
/// last one was. When the selection changes from one item to another, the
/// old bar fades out where it was while the new one fades in under the new
/// selection.
///
/// That cross-fade needs two bars on screen at once, so the layer holds two
/// (`slots`) and they take turns. Each new selection goes to the slot that
/// isn't in use. The slot it replaces keeps the old selection's spot and
/// controls frozen while it fades out.
///
/// Kept permanently mounted (stable view identity) and shown via
/// opacity rather than inserted with `if`: a Liquid Glass backdrop filter on a
/// freshly inserted view samples its backdrop before the canvas beneath it has
/// settled, caching the wrong light/dark variant. A persistent view never
/// takes that bad first sample, so the glass tracks the canvas immediately.
struct SelectionActionBarLayer: View {
    /// Selection bounding box in world space, or nil when nothing is selected.
    let boundingBox: CGRect?
    let scale: CGFloat
    let offset: CGSize
    /// True while a drag/resize/marquee is in progress — the bar hides then.
    let isInteracting: Bool
    /// Which items are selected. A change here is what counts as "a new
    /// selection" and moves the bar to the other slot. Moves, pans, and
    /// zooms change `boundingBox` but not this, so the bar just follows.
    let selectionKey: Set<UUID>
    /// Current text color of the selection as `#RRGGBB`, or nil when the
    /// selection holds no text (the color controls hide then).
    let textColorHex: String?
    let onPickTextColor: (String) -> Void
    /// Fill of the selected frame(s), or nil when no frame is selected.
    var frameFillHex: String? = nil
    var onPickFrameFill: (String) -> Void = { _ in }
    let onCreateFrame: (() -> Void)?
    var onRemoveFrame: (() -> Void)? = nil
    let onDelete: () -> Void

    /// Which controls the bar shows. Kept as plain values so a slot can
    /// remember them after the selection is gone (closures aren't
    /// `Equatable`).
    private struct Controls: Equatable {
        var textColorHex: String?
        var frameFillHex: String?
        var showsCreateFrame: Bool
        var showsRemoveFrame: Bool

        static let empty = Controls(
            textColorHex: nil, frameFillHex: nil,
            showsCreateFrame: false, showsRemoveFrame: false
        )
    }

    /// One of the two bars. `key` is the selection it belongs to; `center`
    /// and `controls` are what it showed the last time it was visible.
    ///
    /// Remembering them matters on the way out. A deselect, a delete, or a
    /// switch to another item changes the live values in the same update
    /// that starts the fade-out. Without the saved copy, the fading bar
    /// would jump to the new spot, or shrink as its buttons winked out one
    /// by one.
    private struct Slot {
        var key: Set<UUID>? = nil
        var center: CGPoint = .zero
        var controls: Controls = .empty
    }

    @State private var slots = [Slot(), Slot()]
    /// Index of the slot that holds the newest selection.
    @State private var current = 0

    private var isVisible: Bool { boundingBox != nil && !isInteracting }

    /// Live center for the *current* selection — `nil` when there's nothing
    /// selected.
    private var liveCenter: CGPoint? {
        guard let box = boundingBox else { return nil }
        return CGPoint(x: box.midX * scale + offset.width,
                       y: box.maxY * scale + offset.height + 32)
    }

    private var liveControls: Controls {
        Controls(
            textColorHex: textColorHex,
            frameFillHex: frameFillHex,
            showsCreateFrame: onCreateFrame != nil,
            showsRemoveFrame: onRemoveFrame != nil
        )
    }

    /// True when slot `i` belongs to the current selection and the bar
    /// should be showing. Only that slot tracks live values and takes taps;
    /// the other shows its saved copy.
    ///
    /// On the update where the selection changes, usually *neither* slot
    /// matches yet: the old one starts fading, and the new one is assigned by
    /// the `onChange` right after, so its fade-in starts one update later.
    /// (Going back to the selection the other slot still holds — A→B→A, or
    /// an undo — makes that slot live at once. It shows live values, so
    /// that's fine.)
    private func isLive(_ i: Int) -> Bool {
        isVisible && slots[i].key == selectionKey
    }

    /// Fade on selection appear/disappear, and when a gesture ends, but
    /// **snap** hidden the moment a gesture starts. Without this gate, the
    /// gesture-start moment kicks off a 0.2s opacity animation on the
    /// (invisible) bar, which eats frame budget for the drag's first ~0.2s
    /// and shows up as visible jitter in the element being dragged.
    ///
    /// Ease-out rather than a spring: a spring's overshoot is clipped at
    /// opacity 1, so the fade-in ended abruptly. The fade-out is a little
    /// shorter, because things leaving should get out of the way.
    private func fadeAnimation(live: Bool) -> Animation? {
        if isInteracting { return nil }
        return .easeOut(duration: live ? 0.2 : 0.15)
    }

    var body: some View {
        ZStack {
            slotBar(0)
            slotBar(1)
        }
        // A new selection takes the slot that isn't in use, starting at its
        // live spot and controls.
        .onChange(of: selectionKey, initial: true) { _, new in
            guard !new.isEmpty, slots[current].key != new else { return }
            current = 1 - current
            slots[current] = Slot(
                key: new,
                center: liveCenter ?? slots[current].center,
                controls: liveControls
            )
        }
        // Save the live spot and controls only while the current slot is
        // showing, so a hidden or fading bar keeps where it was last seen.
        // Watching while visible also catches the moment the bar *becomes*
        // visible: a pan moves the selection while the bar is hidden, then
        // ends without moving it again, and without this the next fade-out
        // would jump back to the pre-pan spot.
        .onChange(of: isLive(current) ? liveCenter : nil, initial: true) { _, new in
            if let new { slots[current].center = new }
        }
        .onChange(of: isLive(current) ? liveControls : nil, initial: true) { _, new in
            if let new { slots[current].controls = new }
        }
    }

    /// One bar. Live, it shows the current selection's spot and controls
    /// with their real actions. Otherwise it shows its saved copy, and every
    /// action does nothing. Blocking taps isn't enough on its own: a finger
    /// already pressing Delete, or a color picker opened from this bar, would
    /// otherwise act on the *new* selection.
    private func slotBar(_ i: Int) -> some View {
        let live = isLive(i)
        let controls = live ? liveControls : slots[i].controls
        let center = live ? (liveCenter ?? slots[i].center) : slots[i].center
        return CanvasSelectionActionBar(
            textColorHex: controls.textColorHex,
            onPickTextColor: live ? onPickTextColor : { _ in },
            frameFillHex: controls.frameFillHex,
            onPickFrameFill: live ? onPickFrameFill : { _ in },
            onCreateFrame: controls.showsCreateFrame ? ((live ? onCreateFrame : nil) ?? {}) : nil,
            onRemoveFrame: controls.showsRemoveFrame ? ((live ? onRemoveFrame : nil) ?? {}) : nil,
            onDelete: live ? onDelete : {}
        )
            .position(center)
            // Moves always land instantly, even when they happen in the same
            // update as the fade-in, or inside someone else's `withAnimation`.
            // A plain `.animation(_:value:)` on visibility would also animate
            // this position, which is the slide we don't want.
            .animation(nil, value: center)
            // Scoped so the fade animates opacity and nothing else.
            .animation(fadeAnimation(live: live)) { content in
                content.opacity(live ? 1 : 0)
            }
            .allowsHitTesting(live)
            // An invisible bar still holds a Delete button. Keep VoiceOver
            // and keyboard focus from landing on it.
            .accessibilityHidden(!live)
    }
}
