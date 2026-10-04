import SwiftUI

/// The top-left HUD: back button, board name, and the asset outliner toggle.
/// Opening the outliner grows the same glass shape downward into a list, so
/// the bar reads as the outliner's header.
///
/// This isn't a native toolbar item. The navigation bar sits above the app's
/// content and catches touches in its area, and a toolbar item can't draw or
/// take touches outside the bar. So `ContentView` floats this view above the
/// whole `NavigationStack`, lined up with an empty placeholder item that
/// `CanvasNavigationToolbar` reserves in the leading slot. The placeholder
/// keeps the trailing tool groups where they'd normally be.
/// Shared column positions for the HUD bar and the outliner rows below it,
/// so the two read as one aligned list.
///
/// Every chevron (back, expand/collapse) has its left edge `chevronInset`
/// from the panel's edge and sits in a `chevronColumn`-wide slot. What comes
/// after it starts at `chevronInset + chevronColumn`: the board name in the
/// bar, the item icon in a top-level row. Each nesting level indents by one
/// icon plus its gap, so a child's icon lines up under its parent's name.
enum HUDLayout {
    static let chevronInset: CGFloat = 16
    static let chevronColumn: CGFloat = 28
    static let iconWidth: CGFloat = 14
    static let iconGap: CGFloat = 8
    static var indentPerLevel: CGFloat { iconWidth + iconGap }
}

struct CanvasHUDView: View {
    let boardName: String
    @Binding var isOutlinerOpen: Bool
    let outliner: AssetOutlinerModel
    /// Tallest the list may get before it scrolls.
    let maxPanelHeight: CGFloat
    /// Longest the board name may get before it truncates. `ContentView`
    /// shrinks this with the window (see `hudNameMaxWidth` there).
    let nameMaxWidth: CGFloat
    let onBack: () -> Void
    /// Reports the closed bar's natural width, so the toolbar can reserve
    /// exactly that much room for it.
    let onBarWidthChange: (CGFloat) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Width the bar takes when it just hugs its contents.
    @State private var naturalWidth: CGFloat = 0

    static let barHeight: CGFloat = 44
    /// Open, the bar widens to at least this, so the list has room even
    /// next to a short board name.
    private let panelMinWidth: CGFloat = 280

    /// Half the bar height, so the closed shape is a capsule like the native
    /// toolbar pills. Kept the same when open, which rounds the panel's
    /// bottom corners to match.
    private var cornerRadius: CGFloat { Self.barHeight / 2 }

    var body: some View {
        VStack(spacing: 0) {
            bar
            // Always built, collapsed to zero height when closed. If the list
            // were inserted on open, it would measure its height a frame
            // late, outside the open animation, and jump to full size.
            VStack(spacing: 0) {
                Divider()
                    .padding(.horizontal, 12)
                AssetOutlinerView(
                    nodes: outliner.nodes,
                    selectedIDs: outliner.selectedIDs,
                    maxHeight: maxPanelHeight,
                    isVisible: isOutlinerOpen,
                    onSelect: outliner.onSelect,
                    onFocus: outliner.onFocus,
                    onRenameAsset: outliner.onRename
                )
            }
            .frame(height: isOutlinerOpen ? nil : 0, alignment: .top)
            .clipped()
            .opacity(isOutlinerOpen ? 1 : 0)
            .allowsHitTesting(isOutlinerOpen)
            .accessibilityHidden(!isOutlinerOpen)
        }
        // Closed: hug the bar's contents. Open: widen for the list.
        .frame(width: isOutlinerOpen ? max(naturalWidth, panelMinWidth) : naturalWidth)
        // Measure the bar's natural width from a hidden copy laid out at its
        // ideal size, so the measurement doesn't change when the panel
        // widens the real bar.
        .background(alignment: .topLeading) {
            bar
                .fixedSize()
                .hidden()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    naturalWidth = width
                    onBarWidthChange(width)
                }
        }
        // One glass shape for bar and panel. Animating its size is what
        // makes the list look like it grows out of the bar.
        .clipShape(.rect(cornerRadius: cornerRadius))
        .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }

    private var bar: some View {
        HStack(spacing: 0) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: HUDLayout.chevronColumn, height: Self.barHeight, alignment: .leading)
                    // The inset is inside the label so the tap target runs
                    // to the bar's edge.
                    .padding(.leading, HUDLayout.chevronInset)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Back to home")

            Text(boardName)
                .font(.headline)
                .foregroundStyle(DesignSystem.Colors.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: nameMaxWidth, alignment: .leading)

            // Zero when closed; pushes the button to the right edge when the
            // open panel makes the bar wider than its contents.
            Spacer(minLength: 0)

            Button(action: toggleOutliner) {
                Image(systemName: "list.bullet.indent")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isOutlinerOpen ? DesignSystem.Colors.tertiary : .primary)
                    .frame(width: 44, height: Self.barHeight)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(isOutlinerOpen ? "Hide assets" : "Show assets")
            .accessibilityAddTraits(isOutlinerOpen ? [.isSelected] : [])
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.trailing, 4)
        .frame(height: Self.barHeight)
    }

    private func toggleOutliner() {
        withAnimation(reduceMotion ? nil : .bouncy(duration: 0.35)) {
            isOutlinerOpen.toggle()
        }
    }
}
