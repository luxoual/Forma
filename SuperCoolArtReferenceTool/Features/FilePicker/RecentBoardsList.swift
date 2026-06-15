//
//  RecentBoardsList.swift
//  SuperCoolArtReferenceTool
//

import SwiftUI

/// "Recent Boards" section: header + the flush-stacked list of
/// `RecentBoardRow`s. Only renders when there are recents.
struct RecentBoardsList: View {
    let recents: [RecentBoardEntry]
    let onOpen: (RecentBoardEntry) -> Void

    var body: some View {
        if !recents.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recent Boards")
                    .font(.headline)
                    .foregroundStyle(DesignSystem.Colors.text)

                VStack(spacing: 0) {
                    ForEach(Array(recents.enumerated()), id: \.element.id) { index, entry in
                        RecentBoardRow(
                            entry: entry,
                            isFirst: index == 0,
                            isLast: index == recents.count - 1,
                            onTap: { onOpen(entry) }
                        )
                    }
                }
                .padding(4)
            }
            .frame(maxWidth: 500)
            .padding(.top, 8)
        }
    }
}
