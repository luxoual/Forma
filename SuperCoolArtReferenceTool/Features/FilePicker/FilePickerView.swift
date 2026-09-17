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
    @State private var showingNewBoardExporter = false
    @State private var newBoardDocument = BoardExportDocument(elements: [])
    @State private var showImportError = false
    @State private var importErrorMessage = ""
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 80
    @Environment(RecentBoardsManager.self) private var recentsManager

    var onNewBoard: (URL) -> Void
    /// Called when an existing board is opened, with the decoded manifest and
    /// the board's URL. The whole `ImportResult` is passed rather than its
    /// fields so board-level state (canvas color, last text color — both
    /// `nil` on legacy boards) can grow without every caller in the chain
    /// gaining another positional `String?`.
    var onBoardSelected: (BoardArchiver.ImportResult, URL) -> Void
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
        VStack(spacing: 32)     {
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
                // Primary action: prominent glass with brand tint.
                Button("New Board") {
                    newBoardDocument = BoardExportDocument(elements: [])
                    showingNewBoardExporter = true
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .foregroundStyle(DesignSystem.Colors.primary)
                .tint(DesignSystem.Colors.tertiary)

                // Secondary action: translucent glass.
                Button("Open Board") {
                    showingBoardPicker = true
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .tint(DesignSystem.Colors.tertiary)
            }

            RecentBoardsList(
                recents: recentsManager.validEntries(limit: 5),
                onOpen: openRecentBoard
            )
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
        .fileExporter(
            isPresented: $showingNewBoardExporter,
            document: newBoardDocument,
            contentType: .refboard,
            defaultFilename: "Untitled Board"
        ) { result in
            switch result {
            case .success(let url):
                recentsManager.record(url: url)
                onNewBoard(url)
            case .failure(let error):
                importErrorMessage = error.localizedDescription
                showImportError = true
            }
        }
    }

    private func openBoard(at url: URL) {
        Task {
            do {
                // `BoardArchiver.importElements` already wraps its own
                // `startAccessingSecurityScopedResource` / stop pair, so we
                // don't need to nest one here — let the archiver own the
                // scope.
                let imported = try await Task.detached(priority: .userInitiated) {
                    try BoardArchiver.importElements(from: url, copyAssetsToAppSupport: true)
                }.value
                recentsManager.record(url: url)
                onBoardSelected(imported, url)
            } catch {
                importErrorMessage = error.localizedDescription
                showImportError = true
            }
        }
    }

    private func openRecentBoard(_ entry: RecentBoardEntry) {
        guard let resolved = entry.resolveURL() else {
            importErrorMessage = "This board can no longer be found."
            showImportError = true
            return
        }
        // `record(url:)` refreshes the bookmark as a side-effect, so stale entries heal on open.
        openBoard(at: resolved.url)
    }
}

#Preview {
    FilePickerView(onNewBoard: { _ in }, onBoardSelected: { _, _ in }, onFilesDropped: { _ in })
        .environment(RecentBoardsManager())
}
