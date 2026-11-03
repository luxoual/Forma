import Foundation

/// What the asset outliner shows, shared between the canvas and the HUD.
///
/// The outliner panel now lives in `CanvasHUDView`, which floats above the
/// navigation bar at the `ContentView` level. The tree data and the
/// select/rename actions still belong to `BoardCanvasView`. This object is
/// the hand-off: the canvas writes `nodes` and `selectedIDs` and installs the
/// actions; the HUD only reads and calls them.
@Observable
@MainActor
final class AssetOutlinerModel {
    var nodes: [AssetOutlineNode] = []
    /// Selected items plus their descendants, so a selected frame highlights
    /// its whole subtree in the list.
    var selectedIDs: Set<UUID> = []
    /// What the user actually selected, as opposed to `selectedIDs`, which
    /// also highlights a frame's descendants. VoiceOver says "Selected" only
    /// for these.
    var directSelectedIDs: Set<UUID> = []

    @ObservationIgnored var onSelect: (UUID) -> Void = { _ in }
    /// Select and move the camera to the item (double-tap on a row).
    @ObservationIgnored var onFocus: (UUID) -> Void = { _ in }
    @ObservationIgnored var onRename: (UUID, String) -> Void = { _, _ in }
}
