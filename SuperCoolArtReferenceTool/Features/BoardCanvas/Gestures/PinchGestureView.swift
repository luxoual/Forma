import SwiftUI
import UIKit

/// Installs a UIPinchGestureRecognizer on the nearest ancestor UIView in the
/// SwiftUI host hierarchy. Unlike SwiftUI's MagnificationGesture, this exposes
/// the pinch centroid so the canvas can zoom around the user's fingers rather
/// than the view center. Touches are observed without being consumed, so the
/// existing two-finger pan and single-finger drag gestures keep working.
///
/// See `GestureInstallerView` for the responder-chain host-finding logic.
struct PinchGestureView: UIViewRepresentable {
    enum Phase { case began, changed, ended }

    /// Phase + per-tick scale delta (multiplicative; 1.0 = no change) + pinch centroid
    /// in installer-local coordinates. Deltas compose cleanly with other gestures that
    /// also write `offset`/`scale`, since each tick reads and updates current state
    /// instead of a frozen baseline. Each `.changed` tick reports the *live* centroid,
    /// so the caller should re-anchor zoom at the current centroid every tick — this
    /// matches Apple Freeform's behavior. `.began` and `.ended` emit delta = 1.0.
    let onPinch: (Phase, CGFloat, CGPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPinch: onPinch) }

    func makeUIView(context: Context) -> GestureInstallerView {
        let view = GestureInstallerView()
        view.coordinator = context.coordinator
        context.coordinator.installerView = view
        return view
    }

    func updateUIView(_ uiView: GestureInstallerView, context: Context) {
        context.coordinator.onPinch = onPinch
    }

    static func dismantleUIView(_ uiView: GestureInstallerView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate, GestureInstallerCoordinator {
        var onPinch: (Phase, CGFloat, CGPoint) -> Void
        let recognizer: UIPinchGestureRecognizer
        weak var installerView: UIView?
        /// Cumulative scale reported at the previous tick; used to derive per-tick deltas.
        private var lastCumulativeScale: CGFloat = 1.0

        var installedRecognizer: UIGestureRecognizer { recognizer }

        init(onPinch: @escaping (Phase, CGFloat, CGPoint) -> Void) {
            self.onPinch = onPinch
            self.recognizer = UIPinchGestureRecognizer()
            super.init()
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            recognizer.addTarget(self, action: #selector(handle(_:)))
        }

        @objc func handle(_ recognizer: UIPinchGestureRecognizer) {
            // Report the centroid in the installer's coordinate space. The installer
            // is mounted as a `.background` of the canvas's ZStack, so its bounds
            // match the coordinate space that SwiftUI uses for `.position(...)` and
            // the `offset`/`scale` math in `handlePinch`. Falling back to
            // `recognizer.view` (the hosting ancestor) would give coordinates in
            // window space, which would misplace the zoom pivot if the canvas is
            // inset by a toolbar or safe area.
            let anchorView: UIView? = installerView ?? recognizer.view
            let location = recognizer.location(in: anchorView)
            switch recognizer.state {
            case .began:
                lastCumulativeScale = recognizer.scale
                onPinch(.began, 1.0, location)
            case .changed:
                let prev = lastCumulativeScale
                let current = recognizer.scale
                let delta = prev > 0 ? current / prev : 1.0
                lastCumulativeScale = current
                onPinch(.changed, delta, location)
            case .ended, .cancelled, .failed:
                lastCumulativeScale = 1.0
                onPinch(.ended, 1.0, location)
            default: break
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        /// Remove the recognizer from its host and break retention so the coordinator
        /// and onPinch closure can be released when the representable is dismantled.
        func detach() {
            recognizer.view?.removeGestureRecognizer(recognizer)
            recognizer.removeTarget(self, action: #selector(handle(_:)))
            recognizer.delegate = nil
            onPinch = { _, _, _ in }
        }
    }
}
