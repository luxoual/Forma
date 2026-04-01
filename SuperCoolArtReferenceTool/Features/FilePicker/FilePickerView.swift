//
//  FilePickerView.swift
//  SuperCoolArtReferenceTool
//
//  Created by andy lin on 2/16/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct FilePickerView: View {
    @State private var viewModel = FilePickerViewModel()
    @State private var showingImagePicker = false

    @Binding var selectedURLs: [URL]?

    var body: some View {
        ZStack {
            // Background
            DesignSystem.Colors.primary
                .ignoresSafeArea()
            emptyStateView
        }
    }
    
    // MARK: - Empty State
    
    private var emptyStateView: some View {
        VStack(spacing: 24) {
            // Drop zone
            VStack(spacing: 16) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 80))
                    .foregroundStyle(DesignSystem.Colors.secondary)
                
                VStack(spacing: 8) {
                    Text("Drag and drop images here")
                        .font(.title3)
                        .foregroundStyle(DesignSystem.Colors.secondary)
                    
                    Text("or")
                        .font(.subheadline)
                        .foregroundStyle(DesignSystem.Colors.secondary.opacity(0.7))
                }
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
                    .foregroundStyle(viewModel.isTargeted ? DesignSystem.Colors.tertiary : DesignSystem.Colors.secondary.opacity(0.5))
            )
            .animation(.easeInOut(duration: 0.2), value: viewModel.isTargeted)
            
            // Browse button
            Button {
                showingImagePicker = true
            } label: {
                Text("Browse")
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.primary)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(DesignSystem.Colors.tertiary)
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
        .onDrop(of: [.image], isTargeted: $viewModel.isTargeted) { providers in
            Task {
                await viewModel.handleDrop(providers: providers)
            }
            return true
        }
        .fileImporter(
            isPresented: $showingImagePicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                print("[FilePicker] Selected \(urls.count) file(s)")
                selectedURLs = urls
            case .failure(let error):
                print("Error selecting images: \(error.localizedDescription)")
            }
        }
    }
}

#Preview {
    FilePickerView(selectedURLs: .constant(nil))
}
