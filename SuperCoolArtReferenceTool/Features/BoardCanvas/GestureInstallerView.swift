import SwiftUI
import UIKit

/// Shared, non-interactive marker view for `UIViewRepresentable` gesture bridges
/// that need to install a `UIGestureRecognizer` on the SwiftUI hosting ancestor
/// rather than on a SwiftUI-managed leaf view.
///
/// Why this layer exists: SwiftUI does not expose the hosting UIView, and a
/// recognizer attached to a `UIViewRepresentable`'s own UIView only sees touches
/// in that view's (often zero-area) frame. Walking up the responder chain to the
/// owning `UIViewController.view` gives us the root of the SwiftUI hierarchy, so
/// the recognizer observes every canvas touch.
///
/// Ownership is bi-directional but weak on the installer side:
/// - The representable retains the `Coordinator`.
/// - The installer view holds a `weak` ref to the coordinator (to ask which
///   recognizer to install) and a `weak` ref to its installed host (to avoid
///   re-installing on relocation).
///
/// Consumers implement `GestureInstallerCoordinator` to expose the recognizer.
protocol GestureInstallerCoordinator: AnyObject {
    var installedRecognizer: UIGestureRecognizer { get }
}

/// Non-interactive marker view. Once mounted in a window, it walks the responder
/// chain to the first `UIViewController`'s root view and installs the
/// coordinator's recognizer there.
final class GestureInstallerView: UIView {
    weak var coordinator: (any GestureInstallerCoordinator)?
    private weak var installedHost: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.isUserInteractionEnabled = false
    }

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
        // Move recognizer to the new host (in case of view recycling).
        let recognizer = coordinator.installedRecognizer
        recognizer.view?.removeGestureRecognizer(recognizer)
        host.addGestureRecognizer(recognizer)
        installedHost = host
    }

    /// Walk up the responder chain to the first `UIViewController`'s root view —
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
