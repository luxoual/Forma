import SwiftUI
import UIKit

/// Installs a two-finger UIPanGestureRecognizer on the nearest ancestor UIView
/// in the SwiftUI host hierarchy. The recognizer observes touches in the canvas
/// area without consuming them, so SwiftUI's single-finger DragGesture,
/// the UIKit-bridged `PinchGestureView` used for zoom, and per-view
/// `.onTapGesture` handlers continue to receive their touches.
///
/// See `GestureInstallerView` for the responder-chain host-finding logic.
struct TwoFingerPanView: UIViewRepresentable {
    enum Phase { case began, changed, ended }

    /// Phase + per-tick translation delta in screen points (additive; .zero = no change).
    /// Deltas compose cleanly with a simultaneous pinch gesture that also writes `offset`,
    /// since each tick reads and updates current state instead of a frozen baseline.
    let onPan: (Phase, CGSize) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPan: onPan) }

    func makeUIView(context: Context) -> GestureInstallerView {
        let view = GestureInstallerView()
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: GestureInstallerView, context: Context) {
        context.coordinator.onPan = onPan
    }

    static func dismantleUIView(_ uiView: GestureInstallerView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate, GestureInstallerCoordinator {
        var onPan: (Phase, CGSize) -> Void
        let recognizer: UIPanGestureRecognizer
        /// Cumulative translation reported at the previous tick; used to derive per-tick deltas.
        private var lastCumulativeTranslation: CGPoint = .zero

        var installedRecognizer: UIGestureRecognizer { recognizer }

        init(onPan: @escaping (Phase, CGSize) -> Void) {
            self.onPan = onPan
            self.recognizer = UIPanGestureRecognizer()
            super.init()
            recognizer.minimumNumberOfTouches = 2
            recognizer.maximumNumberOfTouches = 2
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            recognizer.addTarget(self, action: #selector(handle(_:)))
        }

        @objc func handle(_ recognizer: UIPanGestureRecognizer) {
            let t = recognizer.translation(in: recognizer.view)
            switch recognizer.state {
            case .began:
                lastCumulativeTranslation = t
                onPan(.began, .zero)
            case .changed:
                let dx = t.x - lastCumulativeTranslation.x
                let dy = t.y - lastCumulativeTranslation.y
                lastCumulativeTranslation = t
                onPan(.changed, CGSize(width: dx, height: dy))
            case .ended, .cancelled, .failed:
                lastCumulativeTranslation = .zero
                onPan(.ended, .zero)
            default: break
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        /// Remove the recognizer from its host and break retention so the coordinator
        /// and onPan closure can be released when the representable is dismantled.
        func detach() {
            recognizer.view?.removeGestureRecognizer(recognizer)
            recognizer.removeTarget(self, action: #selector(handle(_:)))
            recognizer.delegate = nil
            onPan = { _, _ in }
        }
    }
}
