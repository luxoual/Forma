//
//  FilePickerView.swift
//  SuperCoolArtReferenceTool
//
//  Created by andy lin on 2/16/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct FilePickerView: View {
    @State private var isTargeted = false
    @State private var showingBoardPicker = false
    @State private var importError: String?
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 80

    var onNewBoard: () -> Void
    var onBoardSelected: ([CMCanvasElement]) -> Void
    var onFilesDropped: ([URL]) -> Void

    var body: some View {
        ZStack {
            DesignSystem.Colors.primary
                .ignoresSafeArea()
            landingView
        }
        .alert("Import Failed", isPresented: .constant(importError != nil)) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private var landingView: some View {
        VStack(spacing: 24) {
            VStack(spacing: 16) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: iconSize))
                    .foregroundStyle(DesignSystem.Colors.secondary)
                    .accessibilityHidden(true)

                Text("Drag and drop an image here")
                    .font(.title3)
                    .foregroundStyle(DesignSystem.Colors.secondary)

                Text("OR")
                    .font(.title3)
                    .foregroundStyle(DesignSystem.Colors.secondary)
            }
            .frame(maxWidth: 400)
            .padding(60)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        style: StrokeStyle(
                            lineWidth: 2,
                            dash: [10, 5]
                        )
                    )
                    .foregroundStyle(isTargeted ? DesignSystem.Colors.tertiary : DesignSystem.Colors.secondary.opacity(0.5))
            )
            .animation(.easeInOut(duration: 0.2), value: isTargeted)
            .contentShape(.rect)
            .onDrop(of: [.image, .gif], isTargeted: $isTargeted) { providers in
                Task {
                    let urls = await loadURLsFromProviders(providers, preferredTypes: [.image, .gif])
                    if !urls.isEmpty {
                        onFilesDropped(urls)
                    }
                }
                return true
            }

            HStack(spacing: 16) {
                Button {
                    onNewBoard()
                } label: {
                    Text("New Board")
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignSystem.Colors.primary)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 12)
                        .background(DesignSystem.Colors.tertiary, in: .rect(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                Button {
                    showingBoardPicker = true
                } label: {
                    Text("Open Board")
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignSystem.Colors.tertiary)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(DesignSystem.Colors.tertiary, lineWidth: 1.5)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .fileImporter(
            isPresented: $showingBoardPicker,
            allowedContentTypes: [.refboard],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    let elements = try BoardArchiver.importElements(from: url, copyAssetsToAppSupport: true)
                    onBoardSelected(elements)
                } catch {
                    importError = error.localizedDescription
                }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
    }

}

#Preview {
    FilePickerView(onNewBoard: {}, onBoardSelected: { _ in }, onFilesDropped: { _ in })
}
