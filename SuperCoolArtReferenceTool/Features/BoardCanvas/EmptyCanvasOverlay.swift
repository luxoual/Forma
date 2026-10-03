import SwiftUI

/// Hint shown when the board has no images yet. Uses `.difference` blend so
/// it stays readable against both light and dark canvas backgrounds.
struct EmptyCanvasOverlay: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 80))
                .foregroundStyle(DesignSystem.Colors.secondary)
                .compositingGroup()
                .blendMode(.difference)
                .accessibilityHidden(true)

            Text("Drag and drop an image here")
                .font(.title3)
                .foregroundStyle(DesignSystem.Colors.secondary)
                .compositingGroup()
                .blendMode(.difference)
        }
    }
}
