import Foundation

/// Available tools selectable from the canvas toolbar.
///
/// There is no separate pointer tool: `group` is the single general-purpose
/// selection tool and covers what pointer used to do — a tap selects one item,
/// a drag on empty canvas marquees. See `GroupToolBehavior`.
enum CanvasTool: Equatable {
    case group
    case text
}
