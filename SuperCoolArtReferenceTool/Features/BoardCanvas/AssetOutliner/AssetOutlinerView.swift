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
            HStack(spacing: 4) {
                // Disclosure and selection are siblings. The disclosure button
                // must not sit inside the selection/rename gesture's hit area.
                if node.kind == .frame {
                    Button {
                        toggleExpanded(node.id)
                    } label: {
                        Image(systemName: expandedFrameIDs.contains(node.id) ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.bold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expandedFrameIDs.contains(node.id) ? "Collapse \(node.title)" : "Expand \(node.title)")
                } else {
                    Color.clear
                        .frame(width: 44, height: 44)
                }

                HStack(spacing: 8) {
                    Image(systemName: iconName(for: node.kind))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(iconColor(for: node.kind))
                        .frame(width: 14)

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
                .contentShape(Rectangle())
                .gesture(
                    TapGesture(count: 2).exclusively(before: TapGesture())
                        .onEnded { gesture in
                            switch gesture {
                            case .first:
                                commitRename()
                                onSelect(node.id)
                                draftTitle = node.title
                                editingAssetID = node.id
                            case .second:
                                commitRename()
                                onSelect(node.id)
                            }
                        },
                    including: editingAssetID == node.id ? .subviews : .all
                )
            }
            .padding(.leading, CGFloat(depth) * 18 + 2)
            .padding(.trailing, 10)
            .background(rowBackground(for: node.id))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            if node.kind == .frame, expandedFrameIDs.contains(node.id) {
                ForEach(node.children) { child in
                    nodeRow(child, depth: depth + 1)
                }
            }
        }
        .padding(.horizontal, 8))
    }

    private func commitRename() {
        guard let id = editingAssetID else { return }
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        editingAssetID = nil
        focusedAssetID = nil
        if !title.isEmpty { onRenameAsset(id, title) }
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
            return DesignSystem.Colors.primary
        }
    }
}
