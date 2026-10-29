import SwiftUI

struct AssetOutlineNode: Identifiable, Equatable {
    enum Kind: Equatable {
        case frame
        case image
        case text
    }

    let id: UUID
    var title: String
    var subtitle: String?
    var kind: Kind
    var children: [AssetOutlineNode]
}

/// The asset tree: frames, images, and text, nested the way they're grouped.
///
/// Just the list. The glass container, width, and header come from
/// `CanvasHUDView`, which shows this under the board name. Its height fits
/// its rows, up to `maxHeight`, then it scrolls.
struct AssetOutlinerView: View {
    let nodes: [AssetOutlineNode]
    let selectedIDs: Set<UUID>
    let maxHeight: CGFloat
    /// False while the HUD has the panel collapsed. The list stays built
    /// (so its height is already measured when it opens), so this is how it
    /// knows to close out an in-progress rename.
    let isVisible: Bool
    let onSelect: (UUID) -> Void
    /// Double-tap on a row: select and move the camera there.
    let onFocus: (UUID) -> Void
    let onRenameAsset: (UUID, String) -> Void

    @State private var expandedFrameIDs: Set<UUID> = []
    @State private var editingAssetID: UUID?
    @State private var draftTitle = ""
    @State private var contentHeight: CGFloat = 0
    @FocusState private var focusedAssetID: UUID?

    var body: some View {
        ScrollView {
            // Not lazy: a lazy stack only builds the rows on screen and
            // guesses the rest, and that guess made the first open overshoot.
            VStack(alignment: .leading, spacing: 2) {
                if nodes.isEmpty {
                    Text("No assets yet")
                        .font(.subheadline)
                        .foregroundStyle(DesignSystem.Colors.secondary)
                        .padding(16)
                } else {
                    ForEach(nodes) { node in
                        nodeRow(node, depth: 0)
                    }
                    // Applied once here, not per row: a per-row inset nests
                    // with each level and narrows deeper rows' highlights.
                    .padding(.horizontal, rowHorizontalInset)
                }
            }
            .padding(.vertical, 8)
        }
        // A ScrollView takes all the height it's offered. Measuring its
        // content and asking for exactly that (capped) is what lets the
        // panel shrink to a short list instead of always running full height.
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentSize.height }) { _, height in
            contentHeight = height
        }
        .frame(height: min(contentHeight, maxHeight))
        .scrollBounceBehavior(.basedOnSize)
        .onAppear {
            expandedFrameIDs.formUnion(allFrameIDs(in: nodes))
        }
        .onChange(of: nodes) { oldValue, newValue in
            let currentIDs = allFrameIDs(in: newValue)
            expandedFrameIDs.formIntersection(currentIDs)
            expandedFrameIDs.formUnion(currentIDs.subtracting(allFrameIDs(in: oldValue)))
            if let editingAssetID, !allAssetIDs(in: newValue).contains(editingAssetID) {
                cancelRename()
            }
        }
        .onChange(of: focusedAssetID) { oldValue, newValue in
            if let oldValue, oldValue == editingAssetID, newValue == nil { commitRename() }
        }
        .onChange(of: selectedIDs) { _, newValue in
            if let editingAssetID, !newValue.contains(editingAssetID) { commitRename() }
        }
        .onChange(of: isVisible) { _, visible in
            if !visible { commitRename() }
        }
        .onDisappear { commitRename() }
    }

    private func nodeRow(_ node: AssetOutlineNode, depth: Int) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                // The row's tap gesture goes on each region as a sibling of
                // the chevron, never on a view that contains it. A gesture on
                // an ancestor beats a child Button (even a high-priority child
                // gesture), so wrapping the chevron would stop it toggling.
                //
                // The indent and chevron column line the chevron up with the
                // bar's back button at the top level and under the parent's
                // name when nested (see `HUDLayout`). Only the chevron's own
                // 28pt slot toggles; a tap on the indent selects the row.
                if node.kind == .frame {
                    Color.clear
                        .frame(width: rowInset(depth: depth), height: 44)
                        .contentShape(Rectangle())
                        .gesture(rowTapGesture(for: node))
                    Button {
                        toggleExpanded(node.id)
                    } label: {
                        Image(systemName: expandedFrameIDs.contains(node.id) ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.bold))
                            .frame(width: HUDLayout.chevronColumn, height: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expandedFrameIDs.contains(node.id) ? "Collapse \(node.title)" : "Expand \(node.title)")
                } else {
                    Color.clear
                        .frame(width: rowInset(depth: depth) + HUDLayout.chevronColumn, height: 44)
                        .contentShape(Rectangle())
                        .gesture(rowTapGesture(for: node))
                }

                HStack(spacing: HUDLayout.iconGap) {
                    Image(systemName: iconName(for: node.kind))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(iconColor(for: node.kind))
                        .frame(width: HUDLayout.iconWidth)

                    VStack(alignment: .leading, spacing: 1) {
                        if editingAssetID == node.id {
                            TextField("Asset name", text: $draftTitle)
                                .font(.subheadline.weight(.medium))
                                .textFieldStyle(.plain)
                                .focused($focusedAssetID, equals: node.id)
                                .onAppear { focusedAssetID = node.id }
                                .onSubmit { commitRename() }
                                .onKeyPress(.escape) {
                                    cancelRename()
                                    return .handled
                                }
                        } else {
                            Text(node.title)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                        }

                        if let subtitle = node.subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(DesignSystem.Colors.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(.vertical, 8)
                .frame(minHeight: 44)
                // Inside the tap area, so the trailing edge selects too.
                .padding(.trailing, 10)
                .contentShape(Rectangle())
                // While renaming, only the text field takes touches here.
                .gesture(
                    rowTapGesture(for: node),
                    including: editingAssetID == node.id ? .subviews : .all
                )
                // The row responds only to custom tap gestures, which
                // VoiceOver can't reach. Expose it as one button whose
                // activation selects, with named actions for the double-tap
                // and the menu. While renaming, the text field stays its own
                // element. This stays on the inner stack so the chevron
                // remains a separate button for VoiceOver.
                .accessibilityElement(children: editingAssetID == node.id ? .contain : .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    commitRename()
                    onSelect(node.id)
                }
                .accessibilityAction(named: "Show on Canvas") {
                    commitRename()
                    onFocus(node.id)
                }
                .accessibilityAction(named: "Rename") {
                    startRename(node)
                }
            }
            .background(rowBackground(for: node.id))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            // Rename lives here instead of on a double-tap of the name, so
            // a double-tap anywhere on the row always jumps the camera.
            .contextMenu {
                Button("Rename", systemImage: "pencil") {
                    startRename(node)
                }
                Button("Show on Canvas", systemImage: "scope") {
                    commitRename()
                    onFocus(node.id)
                }
            }

            if node.kind == .frame, expandedFrameIDs.contains(node.id) {
                ForEach(node.children) { child in
                    nodeRow(child, depth: depth + 1)
                }
            }
        })
    }

    /// Double-tap jumps the camera to the asset; single tap selects it.
    private func rowTapGesture(for node: AssetOutlineNode) -> some Gesture {
        TapGesture(count: 2).exclusively(before: TapGesture())
            .onEnded { gesture in
                commitRename()
                switch gesture {
                case .first: onFocus(node.id)
                case .second: onSelect(node.id)
                }
            }
    }

    /// Space before a row's chevron column. The rows sit 8pt in from the
    /// panel edge (the highlight inset), so this tops that up to
    /// `HUDLayout.chevronInset`, then adds one indent per nesting level.
    private func rowInset(depth: Int) -> CGFloat {
        HUDLayout.chevronInset - rowHorizontalInset + CGFloat(depth) * HUDLayout.indentPerLevel
    }

    private let rowHorizontalInset: CGFloat = 8

    private func commitRename() {
        guard let id = editingAssetID else { return }
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        editingAssetID = nil
        focusedAssetID = nil
        if !title.isEmpty { onRenameAsset(id, title) }
    }

    /// Selects the row and swaps its name for a text field. The field
    /// focuses itself when it appears.
    private func startRename(_ node: AssetOutlineNode) {
        commitRename()
        onSelect(node.id)
        draftTitle = node.title
        editingAssetID = node.id
    }

    private func cancelRename() {
        editingAssetID = nil
        focusedAssetID = nil
    }

    private func rowBackground(for id: UUID) -> some ShapeStyle {
        if selectedIDs.contains(id) {
            return AnyShapeStyle(DesignSystem.Colors.tertiary.opacity(0.14))
        }
        return AnyShapeStyle(.clear)
    }

    private func toggleExpanded(_ id: UUID) {
        if expandedFrameIDs.contains(id) {
            expandedFrameIDs.remove(id)
        } else {
            expandedFrameIDs.insert(id)
        }
    }

    private func allAssetIDs(in nodes: [AssetOutlineNode]) -> Set<UUID> {
        nodes.reduce(into: Set<UUID>()) { ids, node in
            ids.insert(node.id)
            ids.formUnion(allAssetIDs(in: node.children))
        }
    }

    private func allFrameIDs(in nodes: [AssetOutlineNode]) -> Set<UUID> {
        var ids: Set<UUID> = []
        for node in nodes {
            if node.kind == .frame {
                ids.insert(node.id)
            }
            ids.formUnion(allFrameIDs(in: node.children))
        }
        return ids
    }

    private func iconName(for kind: AssetOutlineNode.Kind) -> String {
        switch kind {
        case .frame:
            return "square.3.layers.3d"
        case .image:
            return "photo"
        case .text:
            return "textformat"
        }
    }

    private func iconColor(for kind: AssetOutlineNode.Kind) -> Color {
        switch kind {
        case .frame:
            return DesignSystem.Colors.tertiary
        case .image:
            return DesignSystem.Colors.secondary
        case .text:
            return DesignSystem.Colors.secondary
        }
    }
}
