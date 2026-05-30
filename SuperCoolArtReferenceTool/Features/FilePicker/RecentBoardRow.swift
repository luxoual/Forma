//
//  RecentBoardRow.swift
//  SuperCoolArtReferenceTool
//

import SwiftUI

/// A single tappable row in the recent boards list. Rendered as its own
/// card so the press feedback (`LiftPressStyle`) scales the whole entry
/// rather than just the inner content. Rows stack flush — only the first
/// and last get rounded corners so the group reads as one continuous shape.
struct RecentBoardRow: View {
    let entry: RecentBoardEntry
    let isFirst: Bool
    let isLast: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                Image(systemName: "doc.fill")
                    .foregroundStyle(DesignSystem.Colors.tertiary)
                    .frame(width: 24)

                Text(entry.name)
                    .foregroundStyle(DesignSystem.Colors.text)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Text(entry.lastOpened.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(DesignSystem.Colors.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(
                DesignSystem.Colors.secondary.opacity(0.15),
                in: .rect(
                    topLeadingRadius: isFirst ? 10 : 0,
                    bottomLeadingRadius: isLast ? 10 : 0,
                    bottomTrailingRadius: isLast ? 10 : 0,
                    topTrailingRadius: isFirst ? 10 : 0
                )
            )
            .contentShape(.rect)
        }
        .buttonStyle(LiftPressStyle())
    }
}
