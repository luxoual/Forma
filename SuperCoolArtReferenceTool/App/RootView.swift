//
//  RootView.swift
//  SuperCoolArtReferenceTool
//
//  Created by andy lin on 3/31/26.
//

import SwiftUI

struct RootView: View {
    @EnvironmentObject private var openHandler: AppOpenHandler

    @State private var showCanvas = false
    @State private var initialURLs: [URL] = []

    var body: some View {
        if showCanvas {
            ContentView(initialURLs: initialURLs)
        } else {
            FilePickerView(onFilesSelected: { urls in
                initialURLs = urls
                showCanvas = true
            })
            .onReceive(openHandler.$importedElements) { value in
                if value != nil {
                    showCanvas = true
                }
            }
        }
    }
}

#Preview {
    RootView()
        .environmentObject(AppOpenHandler())
}
