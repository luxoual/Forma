import SwiftUI
import UIKit

/// Tracks whether a hardware-keyboard modifier is held while the user touches
/// the canvas, so tap handling can offer the desktop convention of
/// shift-to-extend a selection without giving up the touch-only path.
///
/// Why a UIKit bridge: SwiftUI's `.onTapGesture` reports no modifier state on
/// iOS (`Gesture.modifiers(_:)` is macOS-only), but `UIGestureRecognizer`
/// exposes `modifierFlags` from iPadOS 13.4 onward. So a passive recognizer
/// rides along on the canvas, reads the flags as each touch lands, and parks
/// them here for the SwiftUI tap handlers to read a moment later.
///
/// Ordering is what makes this safe: UIKit delivers `touchesBegan` to the
/// recognizers on the hit-test chain before SwiftUI's tap resolves on
/// touch-up, so the flag is always current by the time a tap handler asks.
@Observable
@MainActor
final class KeyModifierMonitor {
    /// True while a hardware Shift key is held. Always false on a device with
    /// no keyboard attached, which is the touch-only path.
    private(set) var isShiftDown = false

    fileprivate func update(with flags: UIKeyModifierFlags) {
        let shift = flags.contains(.shift)
        if shift != isShiftDown { isShiftDown = shift }
    }
}

/// Installs the passive recognizer that feeds a `KeyModifierMonitor`.
/// Mount as a `.background(...)` of the canvas, like the pinch and pan bridges.
struct KeyModifierObserverView: UIViewRepresentable {
    let monitor: KeyModifierMonitor

    func makeCoordinator() -> Coordinator { Coordinator(monitor: monitor) }

    func makeUIView(context: Context) -> GestureInstallerView {
        let view = GestureInstallerView()
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: GestureInstallerView, context: Context) {
        context.coordinator.monitor = monitor
    }

    static func dismantleUIView(_ uiView: GestureInstallerView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate, GestureInstallerCoordinator {
        var monitor: KeyModifierMonitor
        let recognizer: ModifierObservingGestureRecognizer

        var installedRecognizer: UIGestureRecognizer { recognizer }

        init(monitor: KeyModifierMonitor) {
            self.monitor = monitor
            self.recognizer = ModifierObservingGestureRecognizer()
            super.init()
            // Pure observer: never claims a touch, never blocks delivery, and
            // never competes with the pinch/pan bridges or SwiftUI's own taps.
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            recognizer.onTouchesBegan = { [weak self] flags in
                guard let self else { return }
                self.monitor.update(with: flags)
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        func detach() {
            recognizer.view?.removeGestureRecognizer(recognizer)
            recognizer.onTouchesBegan = nil
            recognizer.delegate = nil
        }
    }
}

/// A recognizer that exists only to observe. It reports the event's modifier
/// flags on touch-down and then immediately fails, so it can never enter
/// `.began`/`.changed` and therefore can never steal a touch from the
/// recognizers that do real work.
final class ModifierObservingGestureRecognizer: UIGestureRecognizer {
    var onTouchesBegan: (@MainActor (UIKeyModifierFlags) -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        onTouchesBegan?(modifierFlags)
        state = .failed
    }
}
