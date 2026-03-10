import SwiftUI
import UIKit

/// A transparent overlay that installs a UIPinchGestureRecognizer on its superview
/// to capture pinch scale and center without blocking SwiftUI gestures beneath.
struct PinchGestureOverlay: UIViewRepresentable {
    typealias ChangedHandler = (_ relativeScale: CGFloat, _ anchorInView: CGPoint) -> Void
    var onChanged: ChangedHandler
    var onBegan: () -> Void
    var onEnded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChanged: onChanged, onBegan: onBegan, onEnded: onEnded)
    }

    func makeUIView(context: Context) -> PassthroughView {
        let view = PassthroughView()
        view.isUserInteractionEnabled = false // do not block touches
        // Attach to superview on the next run loop when the view is in hierarchy
        DispatchQueue.main.async {
            if let superview = view.superview {
                context.coordinator.attach(to: superview)
            }
        }
        return view
    }

    func updateUIView(_ uiView: PassthroughView, context: Context) {
        // Ensure recognizer is attached to the current superview if hierarchy changes
        DispatchQueue.main.async {
            if let superview = uiView.superview {
                context.coordinator.attach(to: superview)
            }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private var pinchRecognizer: UIPinchGestureRecognizer?
        private weak var attachedView: UIView?
        private let onChanged: ChangedHandler
        private let onBegan: () -> Void
        private let onEnded: () -> Void

        init(onChanged: @escaping ChangedHandler, onBegan: @escaping () -> Void, onEnded: @escaping () -> Void) {
            self.onChanged = onChanged
            self.onBegan = onBegan
            self.onEnded = onEnded
        }

        func attach(to view: UIView) {
            guard attachedView !== view else { return }
            if let recognizer = pinchRecognizer, let existingView = recognizer.view {
                existingView.removeGestureRecognizer(recognizer)
            }
            attachedView = view
            let recognizer = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            recognizer.delegate = self
            recognizer.cancelsTouchesInView = false
            view.addGestureRecognizer(recognizer)
            pinchRecognizer = recognizer
        }

        @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began:
                onBegan()
                fallthrough
            case .changed:
                let scale = recognizer.scale
                let location = recognizer.location(in: recognizer.view)
                onChanged(scale, location)
            case .ended, .cancelled, .failed:
                onEnded()
            default:
                break
            }
        }

        // Allow simultaneous recognition with other gestures (e.g., SwiftUI pan)
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }

    /// A view that never intercepts touches itself, allowing hit-testing to pass through.
    final class PassthroughView: UIView {
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }
    }
}
