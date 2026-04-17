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
    @State private var showImportError = false
    @State private var importErrorMessage = ""
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 80
    @Environment(RecentBoardsManager.self) private var recentsManager

    var onNewBoard: () -> Void
    var onBoardSelected: ([CMCanvasElement]) -> Void
    var onFilesDropped: ([URL]) -> Void

    var body: some View {
        ZStack {
            DesignSystem.Colors.primary
                .ignoresSafeArea()
            landingView
        }
        .alert("Import Failed", isPresented: $showImportError) {
        } message: {
            Text(importErrorMessage)
        }
    }

    private var landingView: some View {
        VStack(spacing: 32) {
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

            recentBoardsSection
        }
        .fileImporter(
            isPresented: $showingBoardPicker,
            allowedContentTypes: [.refboard],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                openBoard(at: url)
            case .failure(let error):
                importErrorMessage = error.localizedDescription
                showImportError = true
            }
        }
    }

    @ViewBuilder
    private var recentBoardsSection: some View {
        let recents = recentsManager.validEntries(limit: 5)
        if !recents.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recent Boards")
                    .font(.headline)
                    .foregroundStyle(DesignSystem.Colors.text)

                VStack(spacing: 0) {
                    ForEach(recents.enumerated().map { $0 }, id: \.element.id) { index, entry in
                        Button {
                            openRecentBoard(entry)
                        } label: {
                            HStack {
                                Image(systemName: "doc.fill")
                                    .foregroundStyle(DesignSystem.Colors.tertiary)
                                    .frame(width: 24)

                                Text(entry.name)
                                    .foregroundStyle(DesignSystem.Colors.text)

                                Spacer()

                                Text(entry.lastOpened.formatted(.relative(presentation: .named)))
                                    .font(.caption)
                                    .foregroundStyle(DesignSystem.Colors.secondary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)

                        if index < recents.count - 1 {
                            Divider()
                                .background(DesignSystem.Colors.secondary.opacity(0.3))
                                .padding(.leading, 56)
                        }
                    }
                }
                .background(DesignSystem.Colors.secondary.opacity(0.15), in: .rect(cornerRadius: 10))
            }
            .frame(maxWidth: 500)
            .padding(.top, 8)
        }
    }

    private func openBoard(at url: URL) {
        do {
            let elements = try BoardArchiver.importElements(from: url, copyAssetsToAppSupport: true)
            recentsManager.record(url: url)
            onBoardSelected(elements)
        } catch {
            importErrorMessage = error.localizedDescription
            showImportError = true
        }
    }

    private func openRecentBoard(_ entry: RecentBoardEntry) {
        guard let url = entry.resolveURL() else {
            importErrorMessage = "This board can no longer be found."
            showImportError = true
            return
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        openBoard(at: url)
    }
}

#Preview {
    FilePickerView(onNewBoard: {}, onBoardSelected: { _ in }, onFilesDropped: { _ in })
        .environment(RecentBoardsManager())
}
