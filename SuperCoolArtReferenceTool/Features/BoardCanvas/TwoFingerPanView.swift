import SwiftUI
import UIKit

/// Installs a two-finger UIPanGestureRecognizer on the nearest ancestor UIView
/// in the SwiftUI host hierarchy. The recognizer observes touches in the canvas
/// area without consuming them, so SwiftUI's single-finger DragGesture,
/// SpatialTapGesture, and MagnificationGesture continue to receive their touches.
struct TwoFingerPanView: UIViewRepresentable {
    enum Phase { case began, changed, ended }

    /// Phase + cumulative translation in screen points since `began`.
    let onPan: (Phase, CGSize) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPan: onPan) }

    func makeUIView(context: Context) -> UIView {
        let view = InstallerView()
        view.coordinator = context.coordinator
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onPan = onPan
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onPan: (Phase, CGSize) -> Void
        let recognizer: UIPanGestureRecognizer

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
            let delta = CGSize(width: t.x, height: t.y)
            switch recognizer.state {
            case .began: onPan(.began, delta)
            case .changed: onPan(.changed, delta)
            case .ended, .cancelled, .failed: onPan(.ended, delta)
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
            // Move recognizer to the new host (in case of view recycling)
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
