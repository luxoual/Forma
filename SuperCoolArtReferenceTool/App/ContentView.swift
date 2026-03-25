//
//  ContentView.swift
//  SuperCoolArtReferenceTool
//
//  Created by andy lin on 2/16/26.
//

import SwiftUI

struct ContentView: View {
    @State private var activeTool: CanvasTool = .pointer

    var body: some View {
        ZStack(alignment: .leading) {
            BoardCanvasView { urls in
                // TODO: route to insertion logic via a view model/service
                print("Imported URLs:", urls)
            }
            CanvasToolbar(
                activeTool: $activeTool,
                onUndo: { /* TODO: hook up undo */ },
                onRedo: { /* TODO: hook up redo */ },
                onAddItem: { /* TODO: present import or create item */ }
            )
            .padding(.leading, 16)
        }
    }
}

#Preview {
    ContentView()
}
