//
//  RootView.swift
//  SuperCoolArtReferenceTool
//
//  Created by andy lin on 3/31/26.
//

import SwiftUI

struct RootView: View {
    @EnvironmentObject private var openHandler: AppOpenHandler

    @State private var selectedURLs: [URL]? = nil
    @State private var showCanvas = false

    var body: some View {
        if showCanvas {
            ContentView(initialURLs: $selectedURLs)
        } else {
            FilePickerView(selectedURLs: $selectedURLs)
                .onChange(of: selectedURLs) { _, newValue in
                    if let urls = newValue, !urls.isEmpty {
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
