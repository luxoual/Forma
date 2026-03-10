//
//  ContentView.swift
//  SuperCoolArtReferenceTool
//
//  Created by andy lin on 2/16/26.
//

import SwiftUI

struct ContentView: View {
    // View transform (world -> screen)
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero

    // Gesture state
    @State private var dragStartOffset: CGSize? = nil
    @State private var zoomStartScale: CGFloat? = nil

    // Grid options
    @State private var showGrid: Bool = true
    @State private var gridSpacingWorld: CGFloat = 128.0

    // Zoom bounds
    private let minScale: CGFloat = 0.05
    private let maxScale: CGFloat = 8.0

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                Toggle("Grid", isOn: $showGrid)
                    .toggleStyle(.switch)
                Spacer()
                Button("- ") { zoom(by: 0.8, anchor: nil) }
                Text("Scale: \(String(format: "%.2f", scale))")
                Button("+ ") { zoom(by: 1.25, anchor: nil) }
            }
            .padding(.horizontal)

            GeometryReader { geo in
                ZStack {
                    // Grid background
                    Canvas { ctx, size in
                        guard showGrid else { return }

                        let s = scale
                        let off = offset

                        // Visible world rect
                        let worldMinX = (-off.width) / s
                        let worldMinY = (-off.height) / s
                        let worldMaxX = (size.width - off.width) / s
                        let worldMaxY = (size.height - off.height) / s

                        // Draw minor grid lines
                        var path = Path()
                        let spacing = max(8.0, gridSpacingWorld)

                        // Start lines aligned to world grid
                        let startX = floor(worldMinX / spacing) * spacing
                        let startY = floor(worldMinY / spacing) * spacing

                        // Vertical lines
                        var x = startX
                        while x <= worldMaxX {
                            let screenX = x * s + off.width
                            path.move(to: CGPoint(x: screenX, y: 0))
                            path.addLine(to: CGPoint(x: screenX, y: size.height))
                            x += spacing
                        }
                        // Horizontal lines
                        var y = startY
                        while y <= worldMaxY {
                            let screenY = y * s + off.height
                            path.move(to: CGPoint(x: 0, y: screenY))
                            path.addLine(to: CGPoint(x: size.width, y: screenY))
                            y += spacing
                        }

                        ctx.stroke(path, with: .color(.gray.opacity(0.25)), lineWidth: 0.5)

                        // Draw origin crosshair for reference
                        let originX = 0 * s + off.width
                        let originY = 0 * s + off.height
                        var cross = Path()
                        cross.move(to: CGPoint(x: originX - 8, y: originY))
                        cross.addLine(to: CGPoint(x: originX + 8, y: originY))
                        cross.move(to: CGPoint(x: originX, y: originY - 8))
                        cross.addLine(to: CGPoint(x: originX, y: originY + 8))
                        ctx.stroke(cross, with: .color(.red.opacity(0.8)), lineWidth: 1)
                    }
                    .ignoresSafeArea()
                }
                .contentShape(Rectangle())
                // Drag to pan
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if dragStartOffset == nil { dragStartOffset = offset }
                            guard let start = dragStartOffset else { return }
                            offset = CGSize(width: start.width + value.translation.width,
                                            height: start.height + value.translation.height)
                        }
                        .onEnded { _ in
                            dragStartOffset = nil
                        }
                )
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in
                            if zoomStartScale == nil { zoomStartScale = scale }
                            let startScale = zoomStartScale ?? scale
                            let newScale = clamp(startScale * value, minScale, maxScale)

                            // Zoom around the view center
                            let anchor = CGPoint(x: geo.size.width / 2.0, y: geo.size.height / 2.0)
                            let worldXBefore = (anchor.x - offset.width) / scale
                            let worldYBefore = (anchor.y - offset.height) / scale

                            scale = newScale
                            let newOffsetX = anchor.x - worldXBefore * newScale
                            let newOffsetY = anchor.y - worldYBefore * newScale
                            offset = CGSize(width: newOffsetX, height: newOffsetY)
                        }
                        .onEnded { _ in
                            zoomStartScale = nil
                        }
                )
                .border(Color.gray.opacity(0.4), width: 1)
            }
        }
        .padding()
    }

    // MARK: - Helpers

    private func clamp(_ value: CGFloat, _ minVal: CGFloat, _ maxVal: CGFloat) -> CGFloat {
        min(max(value, minVal), maxVal)
    }

    private func zoom(by factor: CGFloat, anchor: CGPoint?) {
        // Zoom around provided anchor or view center if nil
        // We need a proxy for the view size; perform a center-anchored zoom if no anchor.
        // Here, we approximate by using the visible midpoint in screen space (0.5, 0.5) of last known geometry.
        // For simplicity, if no anchor is provided, use the current screen center derived from offset/scale.
        // This is a rough approximation suitable for dev buttons.
        let newScale = clamp(scale * factor, minScale, maxScale)
        let screenAnchor = anchor ?? CGPoint(x: 0.5 * UIScreen.main.bounds.width,
                                             y: 0.5 * UIScreen.main.bounds.height)
        let worldXBefore = (screenAnchor.x - offset.width) / scale
        let worldYBefore = (screenAnchor.y - offset.height) / scale
        scale = newScale
        let newOffsetX = screenAnchor.x - worldXBefore * newScale
        let newOffsetY = screenAnchor.y - worldYBefore * newScale
        offset = CGSize(width: newOffsetX, height: newOffsetY)
    }
}

#Preview {
    ContentView()
}

