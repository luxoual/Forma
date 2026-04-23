import SwiftUI
import UIKit

/// Installs a UIPinchGestureRecognizer on the nearest ancestor UIView in the
/// SwiftUI host hierarchy. Unlike SwiftUI's MagnificationGesture, this exposes
/// the pinch centroid so the canvas can zoom around the user's fingers rather
/// than the view center. Touches are observed without being consumed, so the
/// existing two-finger pan and single-finger drag gestures keep working.
struct PinchGestureView: UIViewRepresentable {
    enum Phase { case began, changed, ended }

    /// Phase + per-tick scale delta (multiplicative; 1.0 = no change) + pinch centroid
    /// in installer-local coordinates. Deltas compose cleanly with other gestures that
    /// also write `offset`/`scale`, since each tick reads and updates current state
    /// instead of a frozen baseline. Caller should snapshot the anchor on `.began` and
    /// reuse it during `.changed` for Option A (stable-anchor) zoom.
    let onPinch: (Phase, CGFloat, CGPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPinch: onPinch) }

    func makeUIView(context: Context) -> UIView {
        let view = InstallerView()
        view.coordinator = context.coordinator
        view.isUserInteractionEnabled = false
        context.coordinator.installerView = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onPinch = onPinch
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onPinch: (Phase, CGFloat, CGPoint) -> Void
        let recognizer: UIPinchGestureRecognizer
        weak var installerView: UIView?
        /// Cumulative scale reported at the previous tick; used to derive per-tick deltas.
        private var lastCumulativeScale: CGFloat = 1.0

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
            // Report the centroid in the installer's coordinate space so it
            // matches the SwiftUI canvas geometry even if the host view has a
            // non-zero origin relative to the window.
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

    /// Non-interactive marker view; once mounted, walks up to find a hosting
    /// ancestor and installs the recognizer there so it sees all canvas touches.
    private final class InstallerView: UIView {
        weak var coordinator: Coordinator?
        private weak var installedHost: UIView?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            installIfNeeded()
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            installIfNeeded()
        }

        private func installIfNeeded() {
            guard let coordinator else { return }
            guard window != nil else { return }
            let host = hostingAncestor() ?? superview
            guard let host, host !== installedHost else { return }
            coordinator.recognizer.view?.removeGestureRecognizer(coordinator.recognizer)
            host.addGestureRecognizer(coordinator.recognizer)
            installedHost = host
        }

        /// Walk up the responder chain to the first UIViewController's root view —
        /// that's the SwiftUI hosting view, ancestor of all canvas content.
        private func hostingAncestor() -> UIView? {
            var responder: UIResponder? = self.next
            while let r = responder {
                if let vc = r as? UIViewController { return vc.view }
                responder = r.next
            }
            return nil
        }
    }
}
