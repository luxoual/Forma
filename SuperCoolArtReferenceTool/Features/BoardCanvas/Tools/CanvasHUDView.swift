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
struct CanvasHUDView: View {
    let boardName: String
    @Binding var isOutlinerOpen: Bool
    let outliner: AssetOutlinerModel
    /// Size of the reserved toolbar slot. The bar matches it exactly, and the
    /// open panel keeps its width.
    let barSize: CGSize
    /// Tallest the list may get before it scrolls.
    let maxPanelHeight: CGFloat
    let onBack: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Half the bar height, so the closed shape is a capsule like the native
    /// toolbar pills. Kept the same when open, which rounds the panel's
    /// bottom corners to match.
    private var cornerRadius: CGFloat { barSize.height / 2 }

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
        .frame(width: barSize.width)
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
                    .frame(width: 44, height: barSize.height)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Back to home")

            Text(boardName)
                .font(.headline)
                .foregroundStyle(DesignSystem.Colors.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: toggleOutliner) {
                Image(systemName: "list.bullet.indent")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isOutlinerOpen ? DesignSystem.Colors.tertiary : .primary)
                    .frame(width: 44, height: barSize.height)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(isOutlinerOpen ? "Hide assets" : "Show assets")
            .accessibilityAddTraits(isOutlinerOpen ? [.isSelected] : [])
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.horizontal, 4)
        .frame(height: barSize.height)
    }

    private func toggleOutliner() {
        withAnimation(reduceMotion ? nil : .bouncy(duration: 0.35)) {
            isOutlinerOpen.toggle()
        }
    }
}
