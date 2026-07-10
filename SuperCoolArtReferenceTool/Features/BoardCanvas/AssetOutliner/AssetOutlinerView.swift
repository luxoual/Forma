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

struct AssetOutlinerView: View {
    let nodes: [AssetOutlineNode]
    let selectedIDs: Set<UUID>
    let canCreateFrame: Bool
    let onSelect: (UUID) -> Void
    let onCreateFrame: () -> Void
    let onRenameFrame: (UUID, String) -> Void

    @State private var expandedFrameIDs: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
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
        }
        .frame(width: 280)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.35), lineWidth: 1)
        )
        .onAppear {
            expandedFrameIDs.formUnion(allFrameIDs(in: nodes))
        }
        .onChange(of: nodes) { _, newValue in
            expandedFrameIDs.formUnion(allFrameIDs(in: newValue))
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Assets")
                    .font(.headline)
                Text("Frames and layers")
                    .font(.caption)
                    .foregroundStyle(DesignSystem.Colors.secondary)
            }

            Spacer()

            Button("Create Frame", systemImage: "square.on.square", action: onCreateFrame)
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .disabled(!canCreateFrame)
                .accessibilityLabel("Create frame from selection")
        }
        .padding(14)
    }

    private func nodeRow(_ node: AssetOutlineNode, depth: Int) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                if node.kind == .frame {
                    Button {
                        toggleExpanded(node.id)
                    } label: {
                        Image(systemName: expandedFrameIDs.contains(node.id) ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.bold))
                            .frame(width: 12, height: 12)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear
                        .frame(width: 12, height: 12)
                }

                Image(systemName: iconName(for: node.kind))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(iconColor(for: node.kind))
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: 1) {
                    if node.kind == .frame {
                        TextField("Frame name", text: Binding(
                            get: { node.title },
                            set: { onRenameFrame(node.id, $0) }
                        ))
                        .font(.subheadline.weight(.medium))
                        .textFieldStyle(.plain)
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
            .padding(.leading, CGFloat(depth) * 18 + 10)
            .padding(.trailing, 10)
            .padding(.vertical, 8)
            .background(rowBackground(for: node.id))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture {
                onSelect(node.id)
            }

            if node.kind == .frame, expandedFrameIDs.contains(node.id) {
                ForEach(node.children) { child in
                    nodeRow(child, depth: depth + 1)
                }
            }
        }
        .padding(.horizontal, 8))
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
